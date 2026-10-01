import AppIntents
import Foundation

// MARK: - Siri & Kurzbefehle
//
// „Hey Siri, Familie Einkaufsliste“ → „Was soll drauf?“ → „Milch und Brot“
// „Hey Siri, Familie Garage auf“ / „… Garage zu“ (nur Eltern, iPhone muss entsperrt sein, Siri fragt nach)
// „Hey Siri, Familie was steht heute an?“
// Läuft ohne die App zu öffnen (auch über CarPlay). Siri-Sätze brauchen immer den App-Namen „Familie“.

enum SiriHA {
    static func client() -> HAClient {
        HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
    }
    static let parentKey = "siriEltern"
    static let meKey = "siriIch"
    static var isParent: Bool { UserDefaults.standard.bool(forKey: parentKey) }
    static var me: String { UserDefaults.standard.string(forKey: meKey) ?? "" }

    /// Merkt sich beim Öffnen der App, wer das iPhone benutzt (Siri hat keinen Zugriff auf den App-Zustand)
    @MainActor static func remember(_ store: AppStore) {
        guard store.roleKnown else { return }
        UserDefaults.standard.set(store.isParent && store.activeKid == nil, forKey: parentKey)
        UserDefaults.standard.set(store.myKey ?? "", forKey: meKey)
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " und " + items.last!
    }
}

// MARK: Einkaufsliste

struct AddShoppingIntent: AppIntent {
    static var title: LocalizedStringResource = "Auf die Einkaufsliste"
    static var description = IntentDescription("Setzt etwas auf die Einkaufsliste der Familie.")
    static var openAppWhenRun = false

    @Parameter(title: "Was", requestValueDialog: "Was soll auf die Einkaufsliste?")
    var item: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$item) auf die Einkaufsliste")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parts = item
            .replacingOccurrences(of: " und ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        guard !parts.isEmpty else { return .result(dialog: "Ich habe nichts verstanden.") }

        let client = SiriHA.client()
        let list = FamilyConfig.shoppingList
        func openItems() async throws -> [JSONValue] {
            let r = try await client.callWithResponse("todo", "get_items", ["entity_id": list, "status": ["needs_action"]])
            return r[list]?["items"]?.array ?? []
        }
        let before = try await openItems()
        let have = Set(before.compactMap { $0["summary"]?.string.map(ShopText.key) })
        var added: [String] = []
        var already: [String] = []
        for p in parts {
            if have.contains(ShopText.key(p)) { already.append(p); continue }
            try await client.call("todo", "add_item", ["entity_id": list, "item": p])
            added.append(p)
        }
        // wer hat's eingetragen (wie in der App)
        if !added.isEmpty, !SiriHA.me.isEmpty {
            let old = Set(before.compactMap { $0["uid"]?.string })
            let zeit = HADate.iso.string(from: Date())
            for i in (try? await openItems()) ?? [] {
                guard let uid = i["uid"]?.string, !old.contains(uid) else { continue }
                _ = try? await client.call("todo", "add_item", ["entity_id": FamilyConfig.shoppingMeta, "item": uid,
                                                                "description": ChoreText.jsonString(["von": SiriHA.me, "zeit": zeit])])
            }
        }
        var text = ""
        if !added.isEmpty { text = "\(SiriHA.list(added)) \(added.count == 1 ? "steht" : "stehen") jetzt auf der Einkaufsliste." }
        if !already.isEmpty { text += (text.isEmpty ? "" : " ") + "\(SiriHA.list(already)) \(already.count == 1 ? "stand" : "standen") schon drauf." }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: Garagentor

enum GarageSiri {
    /// true = offen, false = zu, nil = unklar/fährt
    static func isOpen(_ client: HAClient) async -> Bool? {
        if (try? await client.state(QuickConfig.gateMoving))?.state == "on" { return nil }
        if (try? await client.state(QuickConfig.gateOpen))?.state == "on" { return true }
        if (try? await client.state(QuickConfig.gateClosed))?.state == "on" { return false }
        let s = ((try? await client.state(QuickConfig.gateStatus))?.state ?? "").lowercased()
        if s.contains("offen") || s.contains("open") { return true }
        if s.contains("geschlossen") || s.contains("closed") { return false }
        return nil
    }

    static func run(open: Bool, intent: some AppIntent) async throws -> String {
        guard SiriHA.isParent else { return "Das Garagentor können nur Mama und Papa bedienen." }
        let client = SiriHA.client()
        let now = await isOpen(client)
        if now == open { return open ? "Das Garagentor ist schon offen." : "Das Garagentor ist schon zu." }
        if now == nil, (try? await client.state(QuickConfig.gateMoving))?.state == "on" {
            return "Das Garagentor fährt gerade."
        }
        try await intent.requestConfirmation(
            result: .result(dialog: IntentDialog(stringLiteral: open ? "Garagentor wirklich öffnen?" : "Garagentor wirklich schließen?")))
        try await client.call("script", "turn_on", ["entity_id": QuickConfig.gateScript])
        return open ? "Das Garagentor geht auf." : "Das Garagentor geht zu."
    }
}

struct OpenGarageIntent: AppIntent {
    static var title: LocalizedStringResource = "Garagentor öffnen"
    static var description = IntentDescription("Öffnet das Garagentor – nur für Eltern, mit Nachfrage.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await GarageSiri.run(open: true, intent: self)))
    }
}

struct CloseGarageIntent: AppIntent {
    static var title: LocalizedStringResource = "Garagentor schließen"
    static var description = IntentDescription("Schließt das Garagentor – nur für Eltern, mit Nachfrage.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await GarageSiri.run(open: false, intent: self)))
    }
}

// MARK: Was steht heute an?

struct TodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Was steht heute an?"
    static var description = IntentDescription("Termine, Müll und Einkaufsliste für heute.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = SiriHA.client()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let me = SiriHA.me
        let parent = SiriHA.isParent

        // Termine: Eltern alle Kalender, Kinder ihren eigenen + Familie
        var calendars = Array(CalendarOwner.family)
        for (c, person) in CalendarOwner.persons {
            if parent || FamilyConfig.kid(me)?.person == person { calendars.append(c) }
        }
        var events: [HAEvent] = []
        for c in calendars { events += (try? await client.events(calendar: c, from: start, to: end)) ?? [] }
        let now = Date()
        let upcoming = events.filter { $0.end > now }.sorted { $0.start < $1.start }
        var seen = Set<String>()
        var parts: [String] = []
        let lines = upcoming.compactMap { e -> String? in
            guard seen.insert(e.summary + "\(e.start)").inserted else { return nil }
            if e.allDay { return e.summary }
            return "um \(e.start.formatted(date: .omitted, time: .shortened)) \(e.summary)"
        }
        if lines.isEmpty {
            parts.append("Heute stehen keine Termine mehr an.")
        } else {
            parts.append("Heute: " + SiriHA.list(Array(lines.prefix(5))) + (lines.count > 5 ? " und noch \(lines.count - 5) weitere." : "."))
        }

        // Müll (heute / morgen)
        if parent {
            for w in FamilyConfig.waste {
                guard let s = try? await client.state(w.id), let days = s.attr("tage_bis")?.int else { continue }
                if days == 0 { parts.append("\(w.name) wird heute abgeholt.") }
                if days == 1 { parts.append("\(w.name) heute Abend rausstellen.") }
            }
        }

        // Einkaufsliste
        if let r = try? await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.shoppingList, "status": ["needs_action"]]),
           let n = r[FamilyConfig.shoppingList]?["items"]?.array?.count, n > 0 {
            parts.append("Auf der Einkaufsliste \(n == 1 ? "steht eine Sache" : "stehen \(n) Sachen").")
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
    }
}

// MARK: Sätze für Siri

struct FamilieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddShoppingIntent(),
                    phrases: ["\(.applicationName) Einkaufsliste",
                              "Einkaufsliste in \(.applicationName)",
                              "Etwas auf die \(.applicationName) Einkaufsliste",
                              "\(.applicationName) Einkauf"],
                    shortTitle: "Auf die Einkaufsliste",
                    systemImageName: "cart.badge.plus")
        AppShortcut(intent: OpenGarageIntent(),
                    phrases: ["\(.applicationName) Garage auf",
                              "\(.applicationName) Garage öffnen",
                              "Garage auf mit \(.applicationName)",
                              "Öffne die Garage mit \(.applicationName)"],
                    shortTitle: "Garage auf",
                    systemImageName: "door.garage.open")
        AppShortcut(intent: CloseGarageIntent(),
                    phrases: ["\(.applicationName) Garage zu",
                              "\(.applicationName) Garage schließen",
                              "Garage zu mit \(.applicationName)",
                              "Schließe die Garage mit \(.applicationName)"],
                    shortTitle: "Garage zu",
                    systemImageName: "door.garage.closed")
        AppShortcut(intent: TodayIntent(),
                    phrases: ["\(.applicationName) was steht heute an",
                              "Was steht heute an in \(.applicationName)",
                              "\(.applicationName) heute"],
                    shortTitle: "Was steht heute an?",
                    systemImageName: "sun.max")
    }
}
