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

// MARK: - Seite „Trainingsplan“

struct GymPlanView: View {
    @Environment(AppStore.self) private var store
    @State private var plan = GymPlanModel.shared
    @State private var fit = FitnessModel.shared
    @State private var adding: Date?
    @State private var editing: PlanEvent?
    @State private var dropTarget: Date?
    @State private var info: String?

    private var days: [Date] { (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: plan.weekStart)! } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                weekHeader
                if let run = GymModel.shared.run {
                    GymStartCard(program: run.program)
                } else if let g = plan.events.first(where: { $0.sport == .gym && Calendar.current.isDateInToday($0.start) }) {
                    GymStartCard(program: GymProgram.from(title: g.title))
                }
                goalsCard
                if let hint = recoveryHint { hintCard(hint) }
                if let e = plan.error {
                    Label(e, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Text("Verschieben mit ⇄ an der Einheit – oder gedrückt halten und auf einen anderen Tag ziehen. Antippen ändert Uhrzeit und Dauer.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                ForEach(days, id: \.self) { d in dayCard(d) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Meine Standard-Woche").font(.headline)
                    Text(templateText).font(.footnote).foregroundStyle(.secondary)
                    Button { Task { await plan.fillFromTemplate(store) } } label: {
                        Label("Diese Woche damit füllen", systemImage: "wand.and.stars").font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Sport.gym.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Text("Trägt die Standard-Woche an allen freien Tagen ab heute ein. Danach kannst du alles mit ⇄ verschieben.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        plan.saveAsTemplate()
                        info = "Gespeichert – so sieht deine Standard-Woche jetzt aus."
                    } label: {
                        Label("Diese Woche als Standard merken", systemImage: "square.and.arrow.down").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Sport.gym.color)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Sport.gym.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(plan.events.isEmpty)
                    if let info { Text(info).font(.caption).foregroundStyle(.green) }
                }
                .padding(16)
                .cardSurface()
                Text("Steht nur im Kalender „Gym“ in Home Assistant – sonst nirgends.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Trainingsplan")
        .refreshable { await plan.load(store) }
        .task { await plan.load(store, week: plan.weekStart) }
        .sheet(item: Binding(get: { adding.map { DayBox(date: $0) } }, set: { adding = $0?.date })) { box in
            PlanEditSheet(day: box.date, event: nil)
        }
        .sheet(item: $editing) { e in PlanEditSheet(day: e.start, event: e) }
    }

    private struct DayBox: Identifiable { let date: Date; var id: Date { date } }

    /// „Mo Gym A 18:30 · Di Basketball 19:00 …“
    private var templateText: String {
        let names = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        return plan.template.sorted { ($0.weekday, $0.hour, $0.minute) < ($1.weekday, $1.hour, $1.minute) }.map { t in
            let short = t.title.components(separatedBy: " · ").first ?? t.title
            return "\(names[max(0, min(6, t.weekday - 1))]) \(short) \(t.hour):" + String(format: "%02d", t.minute)
        }
        .joined(separator: " · ")
    }

    private var weekHeader: some View {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: plan.weekStart)!
        let kw = Calendar(identifier: .iso8601).component(.weekOfYear, from: plan.weekStart)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.weekStart.formatted(.dateTime.day().month(.abbreviated)) + " – " + end.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.headline)
                Text("Woche \(kw)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            weekButton("chevron.left", -7, "Vorige Woche")
            if plan.weekStart != FitnessModel.startOfWeek {
                Button("Heute") { Task { await plan.load(store, week: FitnessModel.startOfWeek) } }.font(.subheadline.weight(.semibold))
            }
            weekButton("chevron.right", 7, "Nächste Woche")
        }
    }

    private func weekButton(_ symbol: String, _ days: Int, _ label: String) -> some View {
        Button {
            let w = Calendar.current.date(byAdding: .day, value: days, to: plan.weekStart)!
            Task { await plan.load(store, week: w) }
        } label: {
            Image(systemName: symbol).font(.headline).frame(width: 40, height: 40).background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var weekWorkouts: [FitWorkout] {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: plan.weekStart)!
        return fit.workouts.filter { $0.start >= plan.weekStart && $0.start < end }
    }

    private var goalsCard: some View {
        let done = Dictionary(grouping: weekWorkouts, by: \.sport).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 10) {
            Text("WOCHENZIEL").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(plan.weeklyTargets, id: \.0) { item in
                let s = item.0, target = item.1
                let n = done[s] ?? 0
                HStack(spacing: 10) {
                    Image(systemName: s.symbol).font(.caption.weight(.bold)).foregroundStyle(s.color).frame(width: 18)
                    Text(s.title).font(.subheadline.weight(.semibold)).frame(width: 84, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(0..<max(target, n), id: \.self) { i in
                            Capsule().fill(i < n ? s.color : s.color.opacity(0.18)).frame(height: 10)
                        }
                    }
                    Text("\(n)/\(target)").font(.caption.weight(.bold)).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    private var recoveryHint: (String, Bool)? {
        guard Calendar.current.isDate(plan.weekStart, inSameDayAs: FitnessModel.startOfWeek),
              let today = plan.events.first(where: { Calendar.current.isDateInToday($0.start) }) else { return nil }
        guard let r = fit.recovery else { return nil }
        let why = r.reasons.prefix(2).joined(separator: ", ")
        switch r.label {
        case "müde":
            return ("Eher müde (\(why)). Heute lieber locker – \(today.title) etwas leichter oder mit ⇄ verschieben.", false)
        case "gut":
            return ("Gut erholt (\(why)). \(today.title) passt wie geplant.", true)
        default:
            return ("Erholung okay (\(why)). \(today.title) normal, aber nicht ans Limit.", true)
        }
    }

    private func hintCard(_ h: (String, Bool)) -> some View {
        Label(h.0, systemImage: h.1 ? "heart.fill" : "moon.zzz.fill")
            .font(.subheadline)
            .foregroundStyle(h.1 ? Color.green : Color.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((h.1 ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Tag

    private func dayCard(_ d: Date) -> some View {
        let cal = Calendar.current
        let planned = plan.events.filter { cal.isDate($0.start, inSameDayAs: d) }
        let done = weekWorkouts.filter { cal.isDate($0.start, inSameDayAs: d) }
        let today = cal.isDateInToday(d)
        let past = d < cal.startOfDay(for: .now)
        let target = dropTarget.map { cal.isDate($0, inSameDayAs: d) } ?? false
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption.weight(.bold)).foregroundStyle(today ? Sport.gym.color : .secondary)
                Text(d.formatted(.dateTime.day())).font(.title3.weight(.heavy))
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                if planned.isEmpty && done.isEmpty {
                    Text(past ? "Pause" : "frei").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(planned) { e in
                    let ok = done.contains { $0.sport == e.sport }
                        || (e.sport == .gym && GymModel.shared.history.contains { cal.isDate($0.start, inSameDayAs: d) })
                    eventChip(e, done: ok, missed: past && !ok)
                }
                // Trainings ohne Plan (z. B. spontan Laufen)
                ForEach(done.filter { w in !planned.contains { $0.sport == w.sport } }) { w in
                    HStack(spacing: 8) {
                        Image(systemName: w.sport.symbol).foregroundStyle(w.sport.color)
                        Text(w.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("✓ " + FitFmt.dur(w.duration)).font(.caption.weight(.bold)).foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !past {
                Button { adding = d } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.bold)).frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Einheit am \(d.formatted(.dateTime.weekday(.wide))) planen")
            }
        }
        .padding(12)
        .cardSurface(radius: 18)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(target ? Sport.gym.color : (today ? Sport.gym.color.opacity(0.6) : .clear), lineWidth: target ? 3 : 2))
        .dropDestination(for: String.self) { uids, _ in
            guard let uid = uids.first, let e = plan.events.first(where: { $0.uid == uid }) else { return false }
            if !cal.isDate(e.start, inSameDayAs: d) { Task { await plan.move(store, e, to: d) } }
            return true
        } isTargeted: { on in
            if on { dropTarget = d } else if dropTarget.map({ cal.isDate($0, inSameDayAs: d) }) == true { dropTarget = nil }
        }
    }

    private func eventChip(_ e: PlanEvent, done: Bool, missed: Bool) -> some View {
        HStack(spacing: 10) {
            // Antippen = bearbeiten; gedrückt halten und ziehen = auf anderen Tag
            HStack(spacing: 10) {
                Image(systemName: e.sport.symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(e.sport.color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.subheadline.weight(.bold)).strikethrough(missed, color: .secondary)
                    Text(e.start.formatted(date: .omitted, time: .shortened) + " · \(e.minutes) Min").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if done {
                    Text("✓ erledigt").font(.caption.weight(.bold)).foregroundStyle(.green)
                } else if missed {
                    Text("verpasst").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = e }
            .draggable(e.uid) {
                Label(e.title, systemImage: e.sport.symbol).font(.subheadline.weight(.bold))
                    .padding(10).background(.regularMaterial, in: Capsule())
            }
            if !done { moveMenu(e) }
        }
        .opacity(missed ? 0.6 : 1)
    }

    /// Eigener Knopf zum Verschieben – geht immer, auch ohne Ziehen
    private func moveMenu(_ e: PlanEvent) -> some View {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
        let nextWeek = cal.date(byAdding: .day, value: 7, to: e.start)!
        return Menu {
            Section("Verschieben auf") {
                if !cal.isDate(e.start, inSameDayAs: tomorrow) && e.start < tomorrow.addingTimeInterval(86400) {
                    Button { Task { await plan.move(store, e, to: tomorrow) } } label: { Label("Morgen", systemImage: "arrow.right") }
                }
                ForEach(days.filter { !cal.isDate($0, inSameDayAs: e.start) && $0 >= cal.startOfDay(for: .now) }, id: \.self) { d in
                    Button(d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) { Task { await plan.move(store, e, to: d) } }
                }
                Button { Task { await plan.move(store, e, to: nextWeek) } } label: {
                    Label("Nächste Woche (" + nextWeek.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ")", systemImage: "calendar.badge.plus")
                }
            }
            Button { editing = e } label: { Label("Uhrzeit oder Dauer ändern", systemImage: "clock") }
            Button(role: .destructive) { Task { await plan.delete(store, e) } } label: { Label("Fällt aus – löschen", systemImage: "trash") }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(e.sport.color)
                .frame(width: 38, height: 38)
                .background(e.sport.color.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("\(e.title) verschieben")
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
