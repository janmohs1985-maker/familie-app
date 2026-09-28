import SwiftUI

// MARK: - ekey: Wann haben Emma und Leoni die Haustür geöffnet?
//
// Die HA-Automation „Ekey – Kinder kommen nach Hause“ trägt jedes Öffnen in todo.tuer_verlauf ein:
// Name = Kind, Beschreibung = Kind-ID, Fälligkeit = Uhrzeit.

struct DoorOpening: Identifiable, Hashable {
    let uid: String
    let kid: String
    let time: Date
    var id: String { uid }
}

@MainActor
extension AppStore {
    func refreshDoorOpenings() async {
        guard isLoggedIn,
              let r = try? await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.doorHistory,
                                                                                 "status": ["needs_action", "completed"]]),
              let items = r[FamilyConfig.doorHistory]?["items"]?.array else { return }
        var list: [DoorOpening] = []
        for i in items {
            guard let uid = i["uid"]?.string, let t = HADate.parse(i["due"]?.string) else { continue }
            let kid = i["description"]?.string ?? i["summary"]?.string?.lowercased() ?? ""
            list.append(DoorOpening(uid: uid, kid: kid, time: t))
        }
        doorOpenings = list.sorted { $0.time > $1.time }

        // Eltern räumen auf: älter als 60 Tage
        if isParent && activeKid == nil {
            let cutoff = Date().addingTimeInterval(-60 * 86400)
            for o in doorOpenings where o.time < cutoff {
                _ = try? await client.call("todo", "remove_item", ["entity_id": FamilyConfig.doorHistory, "item": o.uid])
            }
            doorOpenings.removeAll { $0.time < cutoff }
        }
    }

    func doorOpenings(kid: String) -> [DoorOpening] { doorOpenings.filter { $0.kid == kid } }

    /// Kind-ID zu einer Person (person.emma → emma)
    func kidID(forPerson personID: String) -> String? {
        FamilyConfig.kids.first { $0.person == personID }?.id
    }
}

/// Abschnitt in der Personen-Ansicht
struct DoorOpeningsSection: View {
    @Environment(AppStore.self) private var store
    let kid: String
    @State private var showAll = false

    var body: some View {
        let list = store.doorOpenings(kid: kid)
        let today = list.filter { Calendar.current.isDateInToday($0.time) }
        Section {
            if let end = store.states["sensor.\(kid)_schulende_heute_full"]?.state, end.contains(":"),
               store.states["automation.familie_\(kid)_nach_der_schule_nicht_zu_hause"] != nil {
                let nineAM = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
                let cameHome = today.contains { $0.time >= nineAM }
                let noSchoolID = "input_boolean.\(kid)_heute_keine_schule"
                let noSchool = store.states[noSchoolID]?.state == "on"
                let holiday = store.states["calendar.schulferien_bayern"]?.state == "on" || store.states["calendar.deutschland_by"]?.state == "on"
                let weekend = Calendar.current.isDateInWeekend(Date())
                HStack(spacing: 10) {
                    Image(systemName: cameHome ? "checkmark.circle.fill" : (noSchool || holiday || weekend ? "moon.zzz.fill" : "clock.badge.exclamationmark"))
                        .foregroundStyle(cameHome ? Color.green : (noSchool || holiday || weekend ? Color.secondary : Color.orange))
                    VStack(alignment: .leading, spacing: 1) {
                        if holiday || weekend {
                            Text(holiday ? (store.states["calendar.schulferien_bayern"]?.attr("message")?.string ?? "Feiertag") : "Wochenende")
                                .font(.subheadline.weight(.semibold))
                            Text("Heute keine Meldung").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Schule heute bis \(end) Uhr").font(.subheadline.weight(.semibold))
                            Text(cameHome ? "Nach der Schule zu Hause angekommen"
                                 : (noSchool ? "Heute keine Schule – keine Meldung"
                                             : "Ihr bekommt eine Meldung, wenn sie 1 Stunde danach noch nicht da ist"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.isParent && store.activeKid == nil && !holiday && !weekend && store.states[noSchoolID] != nil {
                    Toggle(isOn: Binding(get: { noSchool }, set: { v in
                        Task {
                            _ = try? await store.client.call("input_boolean", v ? "turn_on" : "turn_off", ["entity_id": noSchoolID])
                            try? await Task.sleep(for: .milliseconds(500))
                            await store.refreshStates()
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Heute keine Schule").font(.subheadline)
                            Text("z. B. krank – gilt bis Mitternacht").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if list.isEmpty {
                Text("Noch keine Türöffnung erfasst").foregroundStyle(.secondary)
            } else {
                if let last = list.first {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").font(.title3).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Zuletzt \(DayText.label(last.time)), \(last.time.formatted(date: .omitted, time: .shortened)) Uhr")
                                .font(.headline)
                            Text(last.time.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if today.count > 1 {
                    LabeledContent("Heute", value: today.map { $0.time.formatted(date: .omitted, time: .shortened) }.reversed().joined(separator: " · "))
                }
                // Übersicht der letzten Tage
                ForEach(groupedDays(list).prefix(showAll ? 30 : 7), id: \.day) { g in
                    HStack {
                        Text(DayText.label(g.day)).frame(width: 110, alignment: .leading)
                        Spacer()
                        Text(g.times.map { $0.formatted(date: .omitted, time: .shortened) }.joined(separator: " · "))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                if groupedDays(list).count > 7 {
                    Button(showAll ? "Weniger anzeigen" : "Mehr anzeigen") { showAll.toggle() }
                }
            }
        } header: {
            Label("Haustür (Fingerscanner)", systemImage: "key.horizontal.fill")
        }
        .task { await store.refreshDoorOpenings() }
    }

    private struct DayGroup { let day: Date; let times: [Date] }

    private func groupedDays(_ list: [DoorOpening]) -> [DayGroup] {
        let cal = Calendar.current
        let g = Dictionary(grouping: list) { cal.startOfDay(for: $0.time) }
        var out: [DayGroup] = []
        for (day, items) in g { out.append(DayGroup(day: day, times: items.map(\.time).sorted())) }
        out.sort { $0.day > $1.day }
        return out
    }
}
