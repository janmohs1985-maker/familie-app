import SwiftUI

// MARK: - Trainingsplan (Entwurf 2) im Home-Assistant-Kalender „Gym“
//
// Geplante Einheiten stehen nur in calendar.gym (lokaler HA-Kalender). Verschieben = Termin im Kalender ändern.
// In der Beschreibung steht „sport=gym“ usw., damit die App die Sportart kennt.

enum GymPlanConfig {
    static let calendar = "calendar.gym"
}

struct PlanEvent: Identifiable, Hashable {
    let uid: String
    let title: String
    let sport: Sport
    let start: Date
    let end: Date
    var id: String { uid }
    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

/// Eine Einheit der Wochenvorlage (Wochentag 1 = Montag)
struct PlanTemplateItem: Codable, Hashable {
    var weekday: Int
    var sport: String
    var title: String
    var hour: Int
    var minute: Int
    var minutes: Int
}

@MainActor @Observable
final class GymPlanModel {
    static let shared = GymPlanModel()

    var events: [PlanEvent] = []
    var weekStart: Date = FitnessModel.startOfWeek
    var loading = false
    var error: String?

    static let defaultTemplate: [PlanTemplateItem] = [
        .init(weekday: 1, sport: "gym", title: "Gym A · Ganzkörper", hour: 18, minute: 30, minutes: 60),
        .init(weekday: 2, sport: "basketball", title: "Basketball", hour: 19, minute: 0, minutes: 90),
        .init(weekday: 3, sport: "schwimmen", title: "Schwimmen", hour: 18, minute: 30, minutes: 45),
        .init(weekday: 4, sport: "gym", title: "Gym B · Ganzkörper", hour: 18, minute: 30, minutes: 60),
        .init(weekday: 6, sport: "padel", title: "Padel", hour: 10, minute: 0, minutes: 90),
        .init(weekday: 7, sport: "rad", title: "Rad", hour: 10, minute: 0, minutes: 90)
    ]

    var template: [PlanTemplateItem] {
        get {
            guard let s = UserDefaults.standard.string(forKey: "gymTemplate"), let d = s.data(using: .utf8),
                  let t = try? JSONDecoder().decode([PlanTemplateItem].self, from: d), !t.isEmpty else { return Self.defaultTemplate }
            return t
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(String(decoding: d, as: UTF8.self), forKey: "gymTemplate") }
        }
    }

    func load(_ store: AppStore, week: Date? = nil) async {
        if let week { weekStart = week }
        loading = true
        defer { loading = false }
        do {
            let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
            let raw = try await store.client.events(calendar: GymPlanConfig.calendar, from: weekStart, to: end)
            events = raw.compactMap { e in
                guard let uid = e.uid else { return nil }
                return PlanEvent(uid: uid, title: e.summary, sport: Self.sport(of: e), start: e.start, end: e.end)
            }
            .sorted { $0.start < $1.start }
            error = nil
            if Calendar.current.isDate(weekStart, inSameDayAs: FitnessModel.startOfWeek) { GymModel.shared.updateWatchPayload() }
        } catch {
            self.error = "Gym-Kalender nicht erreichbar."
        }
    }

    static func sport(of e: HAEvent) -> Sport {
        if let d = e.description, let r = d.range(of: "sport=") {
            let v = d[r.upperBound...].prefix { $0.isLetter }
            if let s = Sport(rawValue: String(v)) { return s }
        }
        let t = e.summary.lowercased()
        for s in Sport.allCases where t.contains(s.title.lowercased()) { return s }
        if t.contains("lauf") { return .laufen }
        return .gym
    }

    // MARK: Ändern

    func add(_ store: AppStore, sport: Sport, title: String, start: Date, minutes: Int) async {
        let end = start.addingTimeInterval(Double(minutes) * 60)
        do {
            try await store.client.call("calendar", "create_event", [
                "entity_id": GymPlanConfig.calendar, "summary": title,
                "start_date_time": HADate.serviceDateTime.string(from: start),
                "end_date_time": HADate.serviceDateTime.string(from: end),
                "description": "sport=\(sport.rawValue)"])
        } catch { self.error = error.localizedDescription }
        await load(store)
    }

    func move(_ store: AppStore, _ e: PlanEvent, to day: Date, hour: Int? = nil, minute: Int? = nil) async {
        let cal = Calendar.current
        let tm = cal.dateComponents([.hour, .minute], from: e.start)
        guard let newStart = cal.date(bySettingHour: hour ?? tm.hour ?? 18, minute: minute ?? tm.minute ?? 0, second: 0, of: day) else { return }
        let newEnd = newStart.addingTimeInterval(e.end.timeIntervalSince(e.start))
        // sofort anzeigen, dann im Kalender speichern
        if let i = events.firstIndex(where: { $0.uid == e.uid }) {
            events[i] = PlanEvent(uid: e.uid, title: e.title, sport: e.sport, start: newStart, end: newEnd)
            events.sort { $0.start < $1.start }
        }
        do {
            _ = try await store.client.websocket(["type": "calendar/event/update", "entity_id": GymPlanConfig.calendar, "uid": e.uid,
                                                  "event": ["summary": e.title, "dtstart": HADate.iso.string(from: newStart),
                                                            "dtend": HADate.iso.string(from: newEnd),
                                                            "description": "sport=\(e.sport.rawValue)"]])
        } catch { self.error = "Verschieben hat nicht geklappt: \(error.localizedDescription)" }
        await load(store)
    }

    func delete(_ store: AppStore, _ e: PlanEvent) async {
        events.removeAll { $0.uid == e.uid }
        do {
            _ = try await store.client.websocket(["type": "calendar/event/delete", "entity_id": GymPlanConfig.calendar, "uid": e.uid])
        } catch { self.error = error.localizedDescription }
        await load(store)
    }

    /// Wochenvorlage für die angezeigte Woche eintragen (nur Tage ab heute, nur wenn dort noch nichts geplant ist)
    func fillFromTemplate(_ store: AppStore) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        for t in template {
            guard let day = cal.date(byAdding: .day, value: t.weekday - 1, to: weekStart), day >= today,
                  let start = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day),
                  !events.contains(where: { cal.isDate($0.start, inSameDayAs: day) }) else { continue }
            do {
                try await store.client.call("calendar", "create_event", [
                    "entity_id": GymPlanConfig.calendar, "summary": t.title,
                    "start_date_time": HADate.serviceDateTime.string(from: start),
                    "end_date_time": HADate.serviceDateTime.string(from: start.addingTimeInterval(Double(t.minutes) * 60)),
                    "description": "sport=\(t.sport)"])
            } catch { self.error = error.localizedDescription }
        }
        await load(store)
    }

    /// Die angezeigte Woche als Vorlage merken
    func saveAsTemplate() {
        let cal = Calendar.current
        template = events.map { e in
            let wd = (cal.component(.weekday, from: e.start) + 5) % 7 + 1     // So=1 … → Mo=1 … So=7
            let hm = cal.dateComponents([.hour, .minute], from: e.start)
            return PlanTemplateItem(weekday: wd, sport: e.sport.rawValue, title: e.title, hour: hm.hour ?? 18, minute: hm.minute ?? 0, minutes: e.minutes)
        }
    }

    /// Ziel pro Woche = so oft steht die Sportart in der Vorlage
    var weeklyTargets: [(Sport, Int)] {
        let counts = Dictionary(grouping: template, by: \.sport).mapValues(\.count)
        return Sport.allCases.compactMap { s in counts[s.rawValue].map { (s, $0) } }
    }
}

// MARK: - Einheit anlegen / ändern

struct PlanEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let day: Date
    let event: PlanEvent?
    @State private var sport: Sport = .gym
    @State private var title = "Gym A · Ganzkörper"
    @State private var time = Date()
    @State private var date = Date()
    @State private var minutes = 60
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sport", selection: $sport) {
                        ForEach(Sport.allCases.filter { $0 != .andere }) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                    }
                    TextField("Titel", text: $title)
                }
                Section {
                    DatePicker("Tag", selection: $date, displayedComponents: .date)
                    DatePicker("Uhrzeit", selection: $time, displayedComponents: .hourAndMinute)
                    Stepper("Dauer: \(minutes) Min", value: $minutes, in: 15...240, step: 15)
                }
                if let event {
                    Section {
                        Button("Einheit löschen", role: .destructive) {
                            Task { await GymPlanModel.shared.delete(store, event); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(event == nil ? "Einheit planen" : "Einheit ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }.disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: sport) { _, s in
                if event == nil { title = s == .gym ? "Gym A · Ganzkörper" : s.title; minutes = s == .gym ? 60 : (s == .schwimmen ? 45 : 90) }
            }
            .onAppear {
                if let e = event {
                    sport = e.sport; title = e.title; time = e.start; date = e.start; minutes = e.minutes
                } else {
                    date = day
                    time = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: day) ?? day
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        busy = true
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: time)
        Task {
            let plan = GymPlanModel.shared
            if let e = event {
                if e.title != title || e.sport != sport || e.minutes != minutes {
                    // Titel/Sport/Dauer geändert → neu anlegen, alten löschen
                    await plan.delete(store, e)
                    let start = cal.date(bySettingHour: hm.hour ?? 18, minute: hm.minute ?? 0, second: 0, of: date) ?? date
                    await plan.add(store, sport: sport, title: title, start: start, minutes: minutes)
                } else {
                    await plan.move(store, e, to: date, hour: hm.hour, minute: hm.minute)
                }
            } else {
                let start = cal.date(bySettingHour: hm.hour ?? 18, minute: hm.minute ?? 0, second: 0, of: date) ?? date
                await plan.add(store, sport: sport, title: title, start: start, minutes: minutes)
            }
            dismiss()
        }
    }
}
