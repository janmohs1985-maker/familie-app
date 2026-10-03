import SwiftUI

// MARK: - Trainingsplan „flexibel“ (Entwürfe P2 + P1)
//
// Oben die Heute-Karte (Los geht's · Später · Auf morgen · Fällt aus), darunter die Woche als Marken
// (Kontingent: 2× Gym, 1× Basketball fest Di, 1× Padel, 1× Schwimmen, 2× Rad, Laufen frei).
// Alles Geplante steht weiterhin nur im HA-Kalender „Gym“.

/// Wie oft pro Woche – und ob fest an einem Wochentag (1 = Montag)
struct SportQuota: Codable, Hashable, Identifiable {
    var sport: String
    var count: Int
    var fixedWeekday: Int?
    var hour: Int
    var minute: Int
    var minutes: Int
    var id: String { sport }
    var kind: Sport { Sport(rawValue: sport) ?? .andere }
}

@MainActor
extension GymPlanModel {
    static let defaultQuotas: [SportQuota] = [
        .init(sport: "gym", count: 2, fixedWeekday: nil, hour: 18, minute: 30, minutes: 60),
        .init(sport: "basketball", count: 1, fixedWeekday: 2, hour: 19, minute: 0, minutes: 90),
        .init(sport: "padel", count: 1, fixedWeekday: nil, hour: 18, minute: 30, minutes: 90),
        .init(sport: "schwimmen", count: 1, fixedWeekday: nil, hour: 18, minute: 30, minutes: 45),
        .init(sport: "rad", count: 2, fixedWeekday: nil, hour: 18, minute: 0, minutes: 75),
        .init(sport: "laufen", count: 0, fixedWeekday: nil, hour: 18, minute: 0, minutes: 40)
    ]

    var quotas: [SportQuota] {
        get {
            guard let s = UserDefaults.standard.string(forKey: "gymQuotas"), let d = s.data(using: .utf8),
                  let q = try? JSONDecoder().decode([SportQuota].self, from: d), !q.isEmpty else { return Self.defaultQuotas }
            return q
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(String(decoding: d, as: UTF8.self), forKey: "gymQuotas") }
        }
    }

    func quota(_ s: Sport) -> SportQuota? { quotas.first { $0.sport == s.rawValue } }

    static func title(for s: Sport) -> String { s == .gym ? GymModel.shared.nextProgram.title : s.title }

    /// Feste Termine (Basketball) für diese Woche eintragen, falls sie fehlen
    func ensureFixed(_ store: AppStore) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var added = false
        for q in quotas where q.fixedWeekday != nil && q.count > 0 {
            guard let day = cal.date(byAdding: .day, value: q.fixedWeekday! - 1, to: weekStart), day >= today,
                  !events.contains(where: { $0.sport == q.kind && cal.isDate($0.start, inSameDayAs: day) }),
                  !FitnessModel.shared.workouts.contains(where: { $0.sport == q.kind && cal.isDate($0.start, inSameDayAs: day) }),
                  let start = cal.date(bySettingHour: q.hour, minute: q.minute, second: 0, of: day) else { continue }
            try? await store.client.call("calendar", "create_event", [
                "entity_id": GymPlanConfig.calendar, "summary": q.kind.title,
                "start_date_time": HADate.serviceDateTime.string(from: start),
                "end_date_time": HADate.serviceDateTime.string(from: start.addingTimeInterval(Double(q.minutes) * 60)),
                "description": "sport=\(q.sport);fest=1"])
            added = true
        }
        if added { await load(store) }
    }

    /// Heute etwas einplanen (übliche Uhrzeit, oder gleich, wenn die schon vorbei ist)
    func planToday(_ store: AppStore, _ s: Sport) async {
        let cal = Calendar.current
        let q = quota(s)
        let weekend = cal.isDateInWeekend(.now)
        var start = cal.date(bySettingHour: weekend ? 10 : (q?.hour ?? 18), minute: weekend ? 0 : (q?.minute ?? 30), second: 0, of: .now) ?? .now
        if start < .now {
            // nächste halbe Stunde
            let m = cal.component(.minute, from: .now)
            start = cal.date(byAdding: .minute, value: m < 30 ? 30 - m : 60 - m, to: cal.date(bySetting: .second, value: 0, of: .now) ?? .now) ?? .now
        }
        await add(store, sport: s, title: Self.title(for: s), start: start, minutes: q?.minutes ?? 60)
    }

    /// Später heute: +90 Minuten (nach 21:30 → morgen)
    func later(_ store: AppStore, _ e: PlanEvent) async {
        let cal = Calendar.current
        let new = max(e.start, .now).addingTimeInterval(90 * 60)
        if cal.component(.hour, from: new) >= 22 || !cal.isDateInToday(new) {
            await toTomorrow(store, e)
        } else {
            let hm = cal.dateComponents([.hour, .minute], from: new)
            await move(store, e, to: new, hour: hm.hour, minute: (hm.minute ?? 0) / 15 * 15)
        }
    }

    /// Auf morgen – liegt dort schon etwas (nicht Festes), rückt das einen Tag weiter
    func toTomorrow(_ store: AppStore, _ e: PlanEvent) async {
        let cal = Calendar.current
        var chain: [PlanEvent] = [e]
        var day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e.start))!
        while chain.count < 7, let x = events.first(where: { $0.uid != chain.last?.uid && !chain.contains($0)
            && cal.isDate($0.start, inSameDayAs: day) && !isFixed($0) }) {
            chain.append(x)
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        for x in chain.reversed() {
            await move(store, x, to: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: x.start))!)
        }
    }

    func isFixed(_ e: PlanEvent) -> Bool {
        guard let q = quota(e.sport), let wd = q.fixedWeekday else { return false }
        return (Calendar.current.component(.weekday, from: e.start) + 5) % 7 + 1 == wd
    }
}

// MARK: - Seite

struct GymPlanView: View {
    @Environment(AppStore.self) private var store
    @State private var plan = GymPlanModel.shared
    @State private var fit = FitnessModel.shared
    @State private var gym = GymModel.shared
    @State private var editing: PlanEvent?
    @State private var showQuotas = false
    @State private var pickDayFor: Sport?
    @State private var startGym: GymProgram?

    private let cal = Calendar.current
    private var days: [Date] { (0..<7).map { cal.date(byAdding: .day, value: $0, to: plan.weekStart)! } }
    private var weekWorkouts: [FitWorkout] {
        let end = cal.date(byAdding: .day, value: 7, to: plan.weekStart)!
        return fit.workouts.filter { $0.start >= plan.weekStart && $0.start < end }
    }

    /// erledigt an einem Tag für eine Sportart (Apple Health oder Gym-Verlauf)
    private func isDone(_ s: Sport, on d: Date) -> Bool {
        weekWorkouts.contains { $0.sport == s && cal.isDate($0.start, inSameDayAs: d) }
            || (s == .gym && gym.history.contains { cal.isDate($0.start, inSameDayAs: d) })
    }

    private func doneCount(_ s: Sport) -> Int {
        let fromHealth = weekWorkouts.filter { $0.sport == s }.count
        guard s == .gym else { return fromHealth }
        // App-Trainings ohne Health-Eintrag zusätzlich zählen
        let extra = gym.history.filter { log in log.start >= plan.weekStart && !weekWorkouts.contains { $0.sport == .gym && gym.log(for: $0)?.id == log.id } }.count
        return fromHealth + extra
    }

    private var todayEvent: PlanEvent? {
        plan.events.first { cal.isDateInToday($0.start) && !isDone($0.sport, on: $0.start) }
    }
    private var doneToday: [FitWorkout] { weekWorkouts.filter { cal.isDateInToday($0.start) } }
    private var upcoming: [PlanEvent] {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
        return plan.events.filter { $0.start >= tomorrow }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if gym.run != nil, let r = gym.run { GymStartCard(program: r.program) }
                todayCard
                if let e = plan.error { Label(e, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                tokensCard
                weekStrip
                if !upcoming.isEmpty { upcomingCard }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Training")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showQuotas = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Wochenziel einstellen")
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(item: $editing) { e in PlanEditSheet(day: e.start, event: e) }
        .sheet(isPresented: $showQuotas) { QuotaSheet() }
        .navigationDestination(item: $startGym) { p in GymSessionView(program: p) }
        .confirmationDialog("An welchem Tag?", isPresented: Binding(get: { pickDayFor != nil }, set: { if !$0 { pickDayFor = nil } }),
                            titleVisibility: .visible) {
            if let s = pickDayFor {
                ForEach(days.filter { $0 >= cal.startOfDay(for: .now) }, id: \.self) { d in
                    Button(cal.isDateInToday(d) ? "Heute" : d.formatted(.dateTime.weekday(.wide))) {
                        Task { await planOn(s, d) }
                    }
                }
            }
        }
    }

    private func reload() async {
        await plan.load(store, week: FitnessModel.startOfWeek)
        await plan.ensureFixed(store)
    }

    private func planOn(_ s: Sport, _ d: Date) async {
        if cal.isDateInToday(d) { await plan.planToday(store, s); return }
        let q = plan.quota(s)
        let weekend = cal.isDateInWeekend(d)
        let start = cal.date(bySettingHour: weekend ? 10 : (q?.hour ?? 18), minute: weekend ? 0 : (q?.minute ?? 30), second: 0, of: d) ?? d
        await plan.add(store, sport: s, title: GymPlanModel.title(for: s), start: start, minutes: q?.minutes ?? 60)
    }

    // MARK: Heute (P2)

    @ViewBuilder private var todayCard: some View {
        if let e = todayEvent {
            VStack(alignment: .leading, spacing: 10) {
                Text("HEUTE · " + e.start.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.heavy)).tracking(1).opacity(0.85)
                Text(e.title).font(.system(size: 32, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                Text(todaySubtitle(e)).font(.subheadline).opacity(0.9)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    bigButton("Los geht's", filled: true, color: e.sport.color) {
                        if e.sport == .gym { startGym = GymProgram.from(title: e.title) }
                    }
                    bigButton("Später heute") { Task { await plan.later(store, e) } }
                    bigButton("Auf morgen") { Task { await plan.toTomorrow(store, e) } }
                    bigButton("Fällt aus", dim: true) { Task { await plan.delete(store, e) } }
                }
                .padding(.top, 4)
                if e.sport != .gym {
                    Text("„Los geht's“ bei \(e.sport.title): Training auf der Uhr starten – es wird automatisch abgehakt.")
                        .font(.caption2).opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [e.sport.color.opacity(0.95), e.sport.color.opacity(0.72)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: e.sport.color.opacity(0.3), radius: 16, y: 10)
        } else if let w = doneToday.first {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heute erledigt").font(.headline)
                    Text("\(w.name) · \(FitFmt.dur(w.duration))").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .cardSurface()
        } else {
            suggestionCard
        }
    }

    private func todaySubtitle(_ e: PlanEvent) -> String {
        if e.sport == .gym {
            return GymProgram.from(title: e.title).exercises.prefix(3).map(\.name).joined(separator: ", ") + " … ca. 55 Min"
        }
        return "\(e.minutes) Min" + (plan.isFixed(e) ? " · fester Termin" : "")
    }

    private func bigButton(_ title: String, filled: Bool = false, color: Color = .white, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline.weight(filled ? .heavy : .bold))
                .foregroundStyle(filled ? color : .white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(dim ? 0.12 : 0.22)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Kein Plan für heute → Vorschlag aus dem, was diese Woche noch offen ist (P1)
    private var suggestionCard: some View {
        let open = openSports
        let rec = fit.recovery
        let tired = rec?.label == "müde"
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))!
        let gymYesterday = isDone(.gym, on: yesterday)
        var picks = open.filter { s in !(s == .gym && (gymYesterday || tired)) }
        if tired { picks = picks.filter { [.rad, .schwimmen, .laufen].contains($0) } }
        let top = Array(picks.prefix(2))
        var why: [String] = []
        if let r = rec { why.append(r.label == "gut" ? "gut erholt" : (tired ? "eher müde – lieber locker" : "Erholung okay")) }
        if gymYesterday { why.append("Gym war gestern") }
        if let f = top.first { why.append("\(f.title) ist diese Woche noch offen") }
        return VStack(alignment: .leading, spacing: 8) {
            Text("VORSCHLAG FÜR HEUTE · " + Date.now.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.caption.weight(.heavy)).tracking(1).foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.48))
            Text(top.isEmpty ? "Ruhetag" : top.map(\.title).joined(separator: " oder "))
                .font(.title.weight(.heavy))
            Text(top.isEmpty ? "Alles für diese Woche ist geplant oder erledigt." : why.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 8) {
                ForEach(top) { s in
                    Button { Task { await plan.planToday(store, s) } } label: {
                        Text(s.title).font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(s.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    ForEach(Sport.allCases.filter { $0 != .andere }) { s in
                        Button { Task { await plan.planToday(store, s) } } label: { Label(s.title, systemImage: s.symbol) }
                    }
                } label: {
                    Text(top.isEmpty ? "Doch etwas" : "Anderes").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: top.isEmpty ? .infinity : nil, minHeight: 46).padding(.horizontal, 12)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.3)))
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Sportarten mit offenem Kontingent (noch nicht erledigt und nicht verplant), wichtigste zuerst
    private var openSports: [Sport] {
        plan.quotas.filter { $0.count > 0 && $0.fixedWeekday == nil }.compactMap { q -> (Sport, Int)? in
            let planned = plan.events.filter { $0.sport == q.kind && !isDone(q.kind, on: $0.start) }.count
            let left = q.count - doneCount(q.kind) - planned
            return left > 0 ? (q.kind, left) : nil
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    // MARK: Marken (P1)

    private struct Token: Identifiable {
        let id: String
        let sport: Sport
        let state: Int          // 0 offen, 1 geplant, 2 erledigt
        let event: PlanEvent?
        let label: String
    }

    private var tokens: [Token] {
        var out: [Token] = []
        for q in plan.quotas {
            let s = q.kind
            let done = doneCount(s)
            let planned = plan.events.filter { $0.sport == s && !isDone(s, on: $0.start) }
            let n = max(q.count, done)
            var pi = 0
            for i in 0..<n {
                if i < done {
                    out.append(Token(id: "\(s.rawValue)\(i)", sport: s, state: 2, event: nil, label: "✓ " + s.title))
                } else if pi < planned.count {
                    let e = planned[pi]; pi += 1
                    let day = cal.isDateInToday(e.start) ? "heute" : e.start.formatted(.dateTime.weekday(.abbreviated))
                    out.append(Token(id: e.uid, sport: s, state: 1, event: e, label: "\(s.title) · \(day)"))
                } else {
                    out.append(Token(id: "\(s.rawValue)\(i)", sport: s, state: 0, event: nil, label: s.title))
                }
            }
            // mehr geplant als Ziel (z. B. Laufen frei)
            for e in planned.dropFirst(pi) {
                let day = cal.isDateInToday(e.start) ? "heute" : e.start.formatted(.dateTime.weekday(.abbreviated))
                out.append(Token(id: e.uid, sport: s, state: 1, event: e, label: "\(s.title) · \(day)"))
            }
        }
        return out
    }

    private var tokensCard: some View {
        let list = tokens
        let target = plan.quotas.map(\.count).reduce(0, +)
        let done = list.filter { $0.state == 2 }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DIESE WOCHE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(target)").font(.subheadline.weight(.heavy)).monospacedDigit()
            }
            FlowLayout(spacing: 8) {
                ForEach(list) { t in tokenView(t) }
            }
            Text("Offene Marke antippen = einplanen. Geplante antippen = verschieben. Was du aufzeichnest, wird automatisch abgehakt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .cardSurface()
    }

    @ViewBuilder private func tokenView(_ t: Token) -> some View {
        let label = Text(t.label).font(.subheadline.weight(.bold))
            .padding(.horizontal, 12).frame(minHeight: 38)
        switch t.state {
        case 2:
            label.foregroundStyle(.white).background(t.sport.color, in: Capsule())
        case 1:
            if let e = t.event {
                Menu { moveItems(e) } label: {
                    label.foregroundStyle(t.sport.color)
                        .background(t.sport.color.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(t.sport.color, lineWidth: 2))
                }
            }
        default:
            Menu {
                Button { Task { await plan.planToday(store, t.sport) } } label: { Label("Heute", systemImage: "sun.max") }
                Button { pickDayFor = t.sport } label: { Label("Anderer Tag …", systemImage: "calendar") }
            } label: {
                label.foregroundStyle(t.sport.color)
                    .overlay(Capsule().strokeBorder(t.sport.color.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
        }
    }

    @ViewBuilder private func moveItems(_ e: PlanEvent) -> some View {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
        Section("\(e.title) · " + e.start.formatted(.dateTime.weekday(.wide).hour().minute())) {
            if !cal.isDateInToday(e.start) {
                Button { Task { await plan.move(store, e, to: .now) } } label: { Label("Heute", systemImage: "sun.max") }
            }
            if !cal.isDate(e.start, inSameDayAs: tomorrow) {
                Button { Task { await plan.move(store, e, to: tomorrow) } } label: { Label("Morgen", systemImage: "arrow.right") }
            }
            ForEach(days.filter { $0 > tomorrow && !cal.isDate($0, inSameDayAs: e.start) }, id: \.self) { d in
                Button(d.formatted(.dateTime.weekday(.wide))) { Task { await plan.move(store, e, to: d) } }
            }
        }
        Button { editing = e } label: { Label("Uhrzeit oder Dauer", systemImage: "clock") }
        Button(role: .destructive) { Task { await plan.delete(store, e) } } label: { Label("Fällt aus", systemImage: "xmark") }
    }

    // MARK: Woche + Demnächst

    private var weekStrip: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { d in
                let done = weekWorkouts.first { cal.isDate($0.start, inSameDayAs: d) }
                let planned = plan.events.first { cal.isDate($0.start, inSameDayAs: d) }
                let today = cal.isDateInToday(d)
                VStack(spacing: 5) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.bold))
                        .foregroundStyle(today ? Sport.gym.color : .secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(done.map { AnyShapeStyle($0.sport.color) } ?? AnyShapeStyle(Color(.tertiarySystemFill)))
                        if let s = done?.sport {
                            Image(systemName: s.symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        } else if let p = planned {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.sport.color, lineWidth: 2)
                            Image(systemName: p.sport.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(p.sport.color)
                        }
                    }
                    .frame(height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(today ? Sport.gym.color : .clear, lineWidth: 2))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .cardSurface()
    }

    private var upcomingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DEMNÄCHST").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding([.horizontal, .top], 16).padding(.bottom, 6)
            ForEach(upcoming) { e in
                HStack(spacing: 12) {
                    Text(e.start.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    Image(systemName: e.sport.symbol).foregroundStyle(e.sport.color).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.subheadline.weight(.semibold))
                        Text(e.start.formatted(date: .omitted, time: .shortened) + (plan.isFixed(e) ? " · fest" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu { moveItems(e) } label: {
                        Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.bold)).foregroundStyle(e.sport.color)
                            .frame(width: 38, height: 38).background(e.sport.color.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("\(e.title) verschieben")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .padding(.bottom, 8)
        .cardSurface()
    }
}

// MARK: - Wochenziel einstellen

struct QuotaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var quotas = GymPlanModel.shared.quotas

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($quotas) { $q in
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper(value: $q.count, in: 0...7) {
                                Label("\(q.kind.title): \(q.count == 0 ? "frei" : "\(q.count)×")", systemImage: q.kind.symbol)
                                    .foregroundStyle(q.kind.color)
                            }
                            if q.count > 0 {
                                Picker("Fester Tag", selection: Binding(get: { q.fixedWeekday ?? 0 }, set: { q.fixedWeekday = $0 == 0 ? nil : $0 })) {
                                    Text("flexibel").tag(0)
                                    ForEach(1...7, id: \.self) { i in Text(["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][i - 1]).tag(i) }
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                } header: {
                    Text("Pro Woche")
                } footer: {
                    Text("„Fester Tag“ trägt die Einheit jede Woche automatisch ein (z. B. Basketball am Dienstag). Alles andere planst du flexibel über die Marken.")
                }
            }
            .navigationTitle("Wochenziel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { GymPlanModel.shared.quotas = quotas; dismiss() }
                }
            }
        }
    }
}

/// Einfaches Umbruch-Layout für die Marken
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
