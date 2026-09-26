import Foundation

/// Aufgaben, Punkte und Belohnungen – alles über Home Assistant.
@MainActor
extension AppStore {

    // MARK: Rolle

    /// Kind, das zum angemeldeten HA-Benutzer gehört (nil = Elternteil).
    var detectedKid: String? {
        guard let uid = currentUserID, !uid.isEmpty else { return nil }
        return FamilyConfig.kids.first { states[$0.person]?.attr("user_id")?.string == uid }?.id
    }
    /// Echte Rolle: Eltern sind alle, die kein Kind sind.
    var isParent: Bool { currentUserID != nil && detectedKid == nil }
    /// Welche Ansicht gerade gezeigt wird (Eltern können zum Testen als Kind schauen).
    var activeKid: String? {
        guard isParent else { return detectedKid }
        switch viewAs {
        case "auto", "eltern": return nil
        default: return viewAs
        }
    }
    var roleKnown: Bool { currentUserID != nil }

    func loadCurrentUser() async {
        guard isLoggedIn, currentUserID == nil else { return }
        do {
            currentUserID = try await client.currentUserID()
            userLookupFailed = false
        } catch {
            userLookupFailed = true
            report(error)
        }
    }

    // MARK: Laden

    func points(_ kid: String) -> Int {
        Int(Double(states[FamilyConfig.pointsCounter(kid)]?.state ?? "") ?? 0)
    }
    /// Punkte minus bereits angefragte (noch nicht bestätigte) Belohnungen.
    func availablePoints(_ kid: String) -> Int {
        points(kid) - rewardRequests.filter { $0.kid == kid }.reduce(0) { $0 + $1.points }
    }
    var pendingChores: [Chore] {
        FamilyConfig.kids.flatMap { chores[$0.id] ?? [] }.filter(\.done)
    }
    /// Zahl für das Badge am Tab.
    var choreBadge: Int {
        if let kid = activeKid { return (chores[kid] ?? []).filter { !$0.done }.count }
        return isParent ? pendingChores.count + rewardRequests.count : 0
    }

    private func items(_ list: String) async throws -> [JSONValue] {
        let resp = try await client.callWithResponse("todo", "get_items",
                                                     ["entity_id": list, "status": ["needs_action", "completed"]])
        return resp[list]?["items"]?.array ?? []
    }

    func refreshChores() async {
        guard isLoggedIn else { return }
        do {
            var all: [String: [Chore]] = [:]
            for kid in FamilyConfig.kids {
                all[kid.id] = try await items(FamilyConfig.choreList(kid.id)).compactMap { i in
                    guard let uid = i["uid"]?.string, let title = i["summary"]?.string else { return nil }
                    let desc = i["description"]?.string
                    return Chore(uid: uid, kid: kid.id, title: title, points: ChoreText.points(desc),
                                 due: HADate.parse(i["due"]?.string),
                                 recurring: desc?.contains("Wiederkehrend") == true,
                                 done: i["status"]?.string == "completed")
                }.sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
            }
            chores = all

            choreTemplates = try await items(FamilyConfig.choreTemplates).compactMap { i in
                guard let uid = i["uid"]?.string, let title = i["summary"]?.string,
                      let cfg = ChoreText.json(i["description"]?.string),
                      let kid = cfg["kind"]?.string else { return nil }
                let days = cfg["tage"]?.array?.compactMap(\.int) ?? Array(0...6)
                return ChoreTemplate(uid: uid, title: title, kid: kid, points: cfg["punkte"]?.int ?? 0,
                                     days: days, active: i["status"]?.string != "completed")
            }.sorted { ($0.kid, $0.title) < ($1.kid, $1.title) }

            rewards = try await items(FamilyConfig.rewards).compactMap { i in
                guard let uid = i["uid"]?.string, let title = i["summary"]?.string else { return nil }
                return Reward(uid: uid, title: title, points: ChoreText.points(i["description"]?.string))
            }.sorted { $0.points < $1.points }

            rewardRequests = try await items(FamilyConfig.rewardRequests).compactMap { i in
                guard let uid = i["uid"]?.string, let title = i["summary"]?.string,
                      let cfg = ChoreText.json(i["description"]?.string),
                      let kid = cfg["kind"]?.string else { return nil }
                return RewardRequest(uid: uid, kid: kid, title: title, points: cfg["punkte"]?.int ?? 0)
            }
        } catch { report(error) }
    }

    /// Nach einer Änderung: Aufgaben und Punktestände neu laden.
    private func reload() async {
        try? await Task.sleep(for: .milliseconds(400))
        async let a: () = refreshChores()
        async let b: () = refreshStates()
        _ = await (a, b)
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch { report(error) }
        await reload()
    }

    // MARK: Kinder

    func setChore(_ c: Chore, done: Bool) async {
        // sofort anzeigen
        if var list = chores[c.kid], let i = list.firstIndex(of: c) {
            list[i] = Chore(uid: c.uid, kid: c.kid, title: c.title, points: c.points, due: c.due, recurring: c.recurring, done: done)
            chores[c.kid] = list
        }
        await run {
            try await client.call("todo", "update_item", ["entity_id": FamilyConfig.choreList(c.kid), "item": c.uid,
                                                          "status": done ? "completed" : "needs_action"])
        }
    }

    func requestReward(_ r: Reward, kid: String) async {
        guard availablePoints(kid) >= r.points else { return }
        let name = FamilyConfig.kid(kid)?.name ?? kid
        await run {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.rewardRequests,
                                                       "item": "\(name): \(r.title)",
                                                       "description": ChoreText.jsonString(["kind": kid, "punkte": r.points])])
        }
    }

    func cancelRequest(_ r: RewardRequest) async {
        await run { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.rewardRequests, "item": r.uid]) }
    }

    // MARK: Eltern

    func addChore(kid: String, title: String, points: Int, due: Date?) async {
        var data: [String: Any] = ["entity_id": FamilyConfig.choreList(kid), "item": title, "description": "Punkte: \(points)"]
        if let due { data["due_date"] = HADate.day.string(from: due) }
        await run { try await client.call("todo", "add_item", data) }
    }

    func addTemplate(kid: String, title: String, points: Int, days: [Int]) async {
        await run {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.choreTemplates, "item": title,
                                                       "description": ChoreText.jsonString(["kind": kid, "punkte": points, "tage": days.sorted()])])
            // Gleich für heute anlegen, falls heute ein gewählter Tag ist (die Automation verhindert Duplikate)
            try await client.call("automation", "trigger", ["entity_id": FamilyConfig.recurringAutomation, "skip_condition": true])
            try await Task.sleep(for: .seconds(1))
        }
    }

    func setTemplate(_ t: ChoreTemplate, active: Bool) async {
        await run {
            try await client.call("todo", "update_item", ["entity_id": FamilyConfig.choreTemplates, "item": t.uid,
                                                          "status": active ? "needs_action" : "completed"])
        }
    }

    func deleteTemplate(_ t: ChoreTemplate) async {
        await run { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.choreTemplates, "item": t.uid]) }
    }

    func deleteChore(_ c: Chore) async {
        chores[c.kid]?.removeAll { $0.uid == c.uid }
        await run { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.choreList(c.kid), "item": c.uid]) }
    }

    /// Erledigte Aufgabe bestätigen: Punkte gutschreiben und Aufgabe entfernen.
    func confirmChore(_ c: Chore) async {
        await run {
            try await bookPoints(kid: c.kid, delta: c.points, reason: c.title)
            try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.choreList(c.kid), "item": c.uid])
        }
    }

    /// Nicht ordentlich erledigt → zurück auf offen.
    func rejectChore(_ c: Chore) async { await setChore(c, done: false) }

    func confirmRequest(_ r: RewardRequest) async {
        await run {
            try await bookPoints(kid: r.kid, delta: -r.points, reason: "Eingelöst: \(r.title)")
            try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.rewardRequests, "item": r.uid])
        }
    }

    func adjustPoints(kid: String, delta: Int, reason: String) async {
        guard delta != 0 else { return }
        await run { try await bookPoints(kid: kid, delta: delta, reason: reason.isEmpty ? "Von Hand angepasst" : reason) }
    }

    func addReward(title: String, points: Int) async {
        await run {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.rewards, "item": title, "description": "Punkte: \(points)"])
        }
    }

    func deleteReward(_ r: Reward) async {
        await run { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.rewards, "item": r.uid]) }
    }

    private func bookPoints(kid: String, delta: Int, reason: String) async throws {
        try await client.call("script", FamilyConfig.pointsScript, ["kind": kid, "punkte": delta, "grund": reason])
    }
}
