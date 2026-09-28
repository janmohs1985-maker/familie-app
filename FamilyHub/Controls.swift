import Foundation
import SwiftUI      // für Array.move(fromOffsets:toOffset:)

// MARK: - Schalter mit Freigaben
//
// Gespeichert in Home Assistant, Liste „App Schalter“ (todo.app_schalter).
// Name = Anzeigename, Beschreibung = JSON:
//   {"entity":"cover.emma_sud","kinder":["emma"],"fragen":false,"von":"07:00","bis":"20:00","sort":3}
// Optional "skript": Beim Tippen wird dieses Skript gestartet, der Zustand kommt von "entity" (z. B. Garagentor).

struct AppControl: Identifiable, Hashable {
    let uid: String
    var name: String
    var entity: String
    var script: String?
    var kids: [String]
    var confirm: Bool
    var from: String?          // "07:00"
    var to: String?            // "20:00"
    var sort: Int

    var id: String { uid }
    var domain: String { String(entity.split(separator: ".").first ?? "") }
    var hasTimeWindow: Bool { from != nil && to != nil }

    var json: String {
        var d: [String: Any] = ["entity": entity, "kinder": kids, "sort": sort]
        if let script { d["skript"] = script }
        if confirm { d["fragen"] = true }
        if let from, let to { d["von"] = from; d["bis"] = to }
        return ChoreText.jsonString(d)
    }
}

@MainActor
extension AppStore {

    func refreshControls() async {
        guard isLoggedIn else { return }
        do {
            let resp = try await client.callWithResponse("todo", "get_items",
                ["entity_id": FamilyConfig.appControls, "status": ["needs_action", "completed"]])
            let raw = resp[FamilyConfig.appControls]?["items"]?.array ?? []
            appControls = raw.compactMap { i in
                guard let uid = i["uid"]?.string, let name = i["summary"]?.string,
                      let cfg = ChoreText.json(i["description"]?.string), let entity = cfg["entity"]?.string else { return nil }
                return AppControl(uid: uid, name: name, entity: entity, script: cfg["skript"]?.string,
                                  kids: cfg["kinder"]?.array?.compactMap(\.string) ?? [],
                                  confirm: cfg["fragen"]?.string == "true",
                                  from: cfg["von"]?.string, to: cfg["bis"]?.string,
                                  sort: cfg["sort"]?.int ?? 999)
            }.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
        } catch { report(error) }
    }

    /// Schalter, die der aktuelle Benutzer sieht (Eltern: alle, Kinder: nur freigegebene)
    var visibleControls: [AppControl] {
        guard let kid = activeKid else { return isParent ? appControls : [] }
        return appControls.filter { $0.kids.contains(kid) }
    }

    /// Darf gerade geschaltet werden? (Zeitfenster gilt nur für Kinder)
    func allowedNow(_ c: AppControl) -> Bool {
        guard activeKid != nil, let from = c.from, let to = c.to else { return true }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let f = Timetables.minutes(from), t = Timetables.minutes(to)
        return f <= t ? (now >= f && now < t) : (now >= f || now < t)      // auch über Mitternacht
    }

    // MARK: Zustand

    func isOn(_ c: AppControl) -> Bool {
        guard let s = states[c.entity] else { return false }
        if c.domain == "cover" { return (s.attr("current_position")?.int ?? 0) > 0 || s.state == "open" || s.state == "opening" }
        return ["on", "open", "Offen", "unlocked", "unlocking", "opening", "playing"].contains(s.state)
    }

    func isDimmable(_ c: AppControl) -> Bool {
        guard c.domain == "light", let modes = states[c.entity]?.attr("supported_color_modes")?.array else { return false }
        return modes.contains { $0.string != "onoff" }
    }

    func brightnessPercent(_ c: AppControl) -> Int? {
        guard let b = states[c.entity]?.attr("brightness")?.double else { return nil }
        return Int((b / 255 * 100).rounded())
    }

    func coverPosition(_ c: AppControl) -> Int? { states[c.entity]?.attr("current_position")?.int }

    // MARK: Schalten

    private func control(_ c: AppControl, _ work: () async throws -> Void) async {
        guard allowedNow(c) else { lastError = "„\(c.name)“ darf gerade nicht geschaltet werden."; return }
        busy.insert(c.uid)
        defer { busy.remove(c.uid) }
        do {
            try await work()
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStates()
        } catch { report(error) }
    }

    /// Hauptaktion beim Antippen
    func toggle(_ c: AppControl) async {
        await control(c) {
            let target = ["entity_id": c.entity]
            if let script = c.script {
                try await client.call("script", "turn_on", ["entity_id": script])
                return
            }
            switch c.domain {
            case "lock":
                try await client.call("lock", states[c.entity]?.state == "locked" ? "unlock" : "lock", target)
            case "cover":
                try await client.call("cover", "toggle", target)
            case "scene", "script":
                try await client.call(c.domain, "turn_on", target)
            case "button", "input_button":
                try await client.call(c.domain, "press", target)
            default:
                try await client.call("homeassistant", "toggle", target)
            }
        }
    }

    func cover(_ c: AppControl, _ action: String, position: Int? = nil) async {
        await control(c) {
            if let position {
                try await client.call("cover", "set_cover_position", ["entity_id": c.entity, "position": position])
            } else {
                try await client.call("cover", action, ["entity_id": c.entity])
            }
        }
    }

    /// Lampe mit beliebigen Werten einschalten (Farbe, Weißton …)
    func setLight(_ c: AppControl, _ data: [String: Any]) async {
        await control(c) {
            var d = data
            d["entity_id"] = c.entity
            try await client.call("light", "turn_on", d)
        }
    }

    func setBrightness(_ c: AppControl, percent: Int) async {
        await control(c) {
            if percent <= 0 {
                try await client.call("light", "turn_off", ["entity_id": c.entity])
            } else {
                try await client.call("light", "turn_on", ["entity_id": c.entity, "brightness_pct": percent])
            }
        }
    }

    func clearMailbox() async {
        do { try await client.call("input_boolean", "turn_off", ["entity_id": FamilyConfig.mailbox]) } catch { report(error) }
        await refreshStates()
    }

    // MARK: Bearbeiten (Eltern)

    func addControl(entity: String, name: String) async {
        let c = AppControl(uid: "", name: name, entity: entity, script: nil, kids: [], confirm: false,
                           from: nil, to: nil, sort: (appControls.map(\.sort).max() ?? -1) + 1)
        do {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.appControls, "item": name, "description": c.json])
        } catch { report(error) }
        await refreshControls()
    }

    func updateControl(_ c: AppControl) async {
        if let i = appControls.firstIndex(where: { $0.uid == c.uid }) { appControls[i] = c }
        do {
            try await client.call("todo", "update_item", ["entity_id": FamilyConfig.appControls, "item": c.uid,
                                                          "rename": c.name, "description": c.json])
        } catch { report(error) }
    }

    func deleteControl(_ c: AppControl) async {
        appControls.removeAll { $0.uid == c.uid }
        do { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.appControls, "item": c.uid]) }
        catch { report(error) }
    }

    func moveControls(from: IndexSet, to: Int) async {
        var list = appControls
        list.move(fromOffsets: from, toOffset: to)
        var changed: [AppControl] = []
        for i in list.indices where list[i].sort != i {
            list[i].sort = i
            changed.append(list[i])
        }
        appControls = list
        for c in changed { await updateControl(c) }
    }
}
