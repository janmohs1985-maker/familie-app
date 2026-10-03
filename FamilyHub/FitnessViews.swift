import SwiftUI
import Charts
import HealthKit
import HealthKitUI
import MapKit

// MARK: - Fitness-Übersicht (Entwurf 1)

struct FitnessView: View {
    @Environment(AppStore.self) private var store
    @State private var fit = FitnessModel.shared
    @State private var plan = GymPlanModel.shared
    @AppStorage("fitStartKg") private var startKg = FitnessConfig.defaultStartKg
    @AppStorage("fitGoalKg") private var goalKg = FitnessConfig.defaultGoalKg
    @State private var showGoal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !fit.available {
                    note("Apple Health ist auf diesem Gerät nicht verfügbar.", "heart.slash")
                } else if fit.loaded == nil && !fit.loading {
                    connectCard
                }
                if let e = fit.error { note(e, "exclamationmark.triangle") }
                gymEntry
                if fit.loaded != nil {
                    goalCard
                    HStack(spacing: 12) {
                        NavigationLink { NutritionView() } label: {
                            let d = fit.nutritionToday
                            let left = fit.kcalTarget - (d?.kcal ?? 0)
                            entryTile("Ernährung", "fork.knife", .green,
                                      (d?.logged ?? false) ? FitFmt.int(abs(left)) + (left >= 0 ? " übrig" : " drüber") : "–",
                                      d?.protein.map { "Eiweiß \(FitFmt.int($0))/\(FitFmt.int(fit.proteinTarget)) g" } ?? "aus Yazio")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { BodyCompView() } label: {
                            entryTile("Körperwerte", "scalemass.fill", .blue,
                                      fit.bodyFat.last.map { FitFmt.num($0.value, 1) + " % Fett" } ?? "–",
                                      fit.lean.last.map { "Magermasse \(FitFmt.num($0.value, 1)) kg" } ?? "von der Waage")
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ringsCard
                        VStack(spacing: 12) {
                            smallCard("Schritte", fit.stepsToday.map { FitFmt.int($0) } ?? "–",
                                      fit.kmToday.map { String(format: "%.1f km", $0).replacingOccurrences(of: ".", with: ",") } ?? "", .primary)
                            recoveryCard
                        }
                    }
                    weekCard
                    musclesCard
                    recentCard
                    NavigationLink { FitnessProgressView() } label: {
                        Label("Entwicklung ansehen", systemImage: "chart.xyaxis.line")
                            .font(.headline).frame(maxWidth: .infinity).padding(14).cardSurface(radius: 18)
                    }
                    .buttonStyle(.plain)
                }
                if fit.loading && fit.loaded == nil {
                    ProgressView("Lese Apple Health …").frame(maxWidth: .infinity).padding(30)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Fitness")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGoal = true } label: { Image(systemName: "target") }.accessibilityLabel("Ziel ändern")
            }
        }
        .refreshable { await fit.refresh(maxAge: 0) }
        .task {
            await fit.refreshIfAllowed()
            await GymPlanModel.shared.load(store, week: FitnessModel.startOfWeek)
            // Gym-Plan auf die Apple Watch bringen
            UserDefaults.standard.set(true, forKey: "gymOnWatch")
            GymModel.shared.updateWatchPayload()
        }
        .sheet(isPresented: $showGoal) { FitnessGoalSheet(startKg: $startKg, goalKg: $goalKg) }
    }

    // MARK: Karten

    /// Gym-Training: läuft gerade, steht heute im Plan – oder A/B frei wählen
    @ViewBuilder private var gymEntry: some View {
        let todayGym = plan.events.first { $0.sport == .gym && Calendar.current.isDateInToday($0.start) }
        if let run = GymModel.shared.run {
            GymStartCard(program: run.program)
        } else if let e = todayGym {
            GymStartCard(program: GymProgram.from(title: e.title))
        } else {
            HStack(spacing: 10) {
                ForEach(GymProgram.allCases) { p in
                    NavigationLink { GymSessionView(program: p) } label: {
                        Label(p.short, systemImage: "dumbbell.fill").font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .foregroundStyle(Sport.gym.color)
                            .cardSurface(radius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func entryTile(_ title: String, _ symbol: String, _ color: Color, _ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            Text(big).font(.headline.weight(.heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.subheadline.weight(.semibold))
            Text(small).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Mit Apple Health verbinden", systemImage: "heart.text.square.fill")
                .font(.headline).foregroundStyle(.pink)
            Text("Die App liest deine Trainings, dein Gewicht, Schlaf und Puls aus Apple Health. Die Daten bleiben auf deinem iPhone und gehen nicht an Home Assistant.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { Task { await fit.requestAndLoad() } } label: {
                Text("Verbinden").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.pink)
        }
        .padding(16)
        .cardSurface()
    }

    private func note(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(.orange)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface(radius: 18)
    }

    private var goalCard: some View {
        let cur = fit.currentWeight?.value
        let lost = cur.map { startKg - $0 } ?? 0
        let total = max(0.1, startKg - goalKg)
        let progress = min(1, max(0, lost / total))
        let trend = fit.weeklyTrend
        let since = Calendar.current.date(byAdding: .month, value: -6, to: .now)!
        let pts = fit.weights.filter { $0.date >= since }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MEIN ZIEL").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(FitFmt.kg(startKg)) → \(FitFmt.kg(goalKg))").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(cur.map { FitFmt.num($0, 1) } ?? "–").font(.system(size: 40, weight: .heavy)).monospacedDigit()
                Text("kg").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if cur != nil {
                    Text(lost >= 0 ? "−\(FitFmt.num(lost, 1)) kg" : "+\(FitFmt.num(-lost, 1)) kg")
                        .font(.headline).foregroundStyle(lost >= 0 ? .green : .orange)
                }
            }
            if pts.count > 1 {
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Datum", p.date), y: .value("kg", p.value))
                            .foregroundStyle(Sport.gym.color).interpolationMethod(.catmullRom)
                    }
                    RuleMark(y: .value("Ziel", goalKg))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Ziel \(FitFmt.kg(goalKg))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .frame(height: 100)
            } else if cur == nil {
                Text("Noch kein Gewicht in Apple Health. Mit einer verbundenen Waage oder in der Health-App eintragen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ProgressView(value: progress).tint(Sport.gym.color)
            Text(goalText(progress: progress, cur: cur, trend: trend)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .cardSurface()
    }

    private func goalText(progress: Double, cur: Double?, trend: Double?) -> String {
        guard let cur else { return "Start \(FitFmt.kg(startKg)) · Ziel \(FitFmt.kg(goalKg))" }
        let rest = cur - goalKg
        var parts = ["\(Int((progress * 100).rounded())) % geschafft"]
        if rest > 0 { parts.append("noch \(FitFmt.num(rest, 1)) kg") } else { parts.append("Ziel erreicht!") }
        if let t = trend, t < -0.05, rest > 0 {
            let weeks = rest / -t
            if let d = Calendar.current.date(byAdding: .day, value: Int(weeks * 7), to: .now) {
                parts.append("bei diesem Tempo ca. " + d.formatted(.dateTime.month(.wide).year()))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var ringsCard: some View {
        VStack(spacing: 8) {
            ActivityRings(summary: fit.activity).frame(width: 110, height: 110)
            if let a = fit.activity {
                let move = a.activeEnergyBurned.doubleValue(for: .kilocalorie())
                let moveGoal = a.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
                let ex = a.appleExerciseTime.doubleValue(for: .minute())
                Text("\(Int(move))/\(Int(moveGoal)) kcal · \(Int(ex)) Min")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private func smallCard(_ title: String, _ big: String, _ small: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(big).font(.title3.weight(.heavy)).monospacedDigit().foregroundStyle(color)
            Text(small).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var recoveryCard: some View {
        let r = fit.recovery
        return VStack(alignment: .leading, spacing: 4) {
            Text("Erholung").font(.caption).foregroundStyle(.secondary)
            Text(r?.label ?? "–").font(.title3.weight(.heavy)).foregroundStyle(r?.color ?? .primary)
            Text(r?.reasons.first ?? "Wie fühlst du dich?").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                feelingButton(.fit, "bolt.fill", .green, "fit")
                feelingButton(.okay, "hand.thumbsup.fill", .blue, "okay")
                feelingButton(.muede, "moon.zzz.fill", .orange, "müde")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func feelingButton(_ f: FitnessModel.Feeling, _ symbol: String, _ color: Color, _ label: String) -> some View {
        let on = fit.feeling == f
        return Button { withAnimation { fit.feeling = on ? nil : f } } label: {
            Image(systemName: symbol).font(.caption.weight(.bold))
                .foregroundStyle(on ? .white : color)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(on ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ich fühle mich \(label)")
    }

    private var weekCard: some View {
        let start = FitnessModel.startOfWeek
        let days = (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! }
        let week = fit.workouts(since: start)
        return VStack(alignment: .leading, spacing: 12) {
            NavigationLink { GymPlanView() } label: {
                HStack {
                    Text("Diese Woche").font(.headline)
                    Spacer()
                    Text("\(week.count) Trainings · \(FitFmt.hm(week.map(\.duration).reduce(0, +) / 3600))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Plan").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { d in
                    let list = week.filter { Calendar.current.isDate($0.start, inSameDayAs: d) }
                    let planned = GymPlanModel.shared.events.first { Calendar.current.isDate($0.start, inSameDayAs: d) }
                    let today = Calendar.current.isDateInToday(d)
                    VStack(spacing: 6) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2.weight(.semibold)).foregroundStyle(today ? Sport.gym.color : .secondary)
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(list.first.map { AnyShapeStyle($0.sport.color) } ?? AnyShapeStyle(Color(.tertiarySystemFill)))
                            if let s = list.first?.sport {
                                Image(systemName: s.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            } else if let p = planned {
                                // geplant, noch nicht gemacht
                                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.sport.color, lineWidth: 2)
                                Image(systemName: p.sport.symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(p.sport.color)
                            }
                            if list.count > 1 {
                                Text("\(list.count)").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                    .padding(3).background(.black.opacity(0.35), in: Circle())
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(2)
                            }
                        }
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(today ? Sport.gym.color : .clear, lineWidth: 2))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 12) {
                ForEach(Sport.allCases.filter { s in s != .andere && (week.contains { $0.sport == s } || GymPlanModel.shared.events.contains { $0.sport == s }) }, id: \.self) { s in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 9, height: 9)
                        Text("\(s.title) \(week.filter { $0.sport == s }.count)×")
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .cardSurface()
    }

    private var musclesCard: some View {
        let load = fit.muscleLoad(since: FitnessModel.startOfWeek)
        let weak = Muscle.allCases.filter { (load[$0] ?? 0) < 0.15 }.map(\.group)
        let weakGroups = Array(Set(weak)).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Muskeln diese Woche").font(.headline)
            BodyMapView(load: load).frame(maxWidth: 320).frame(maxWidth: .infinity)
            if load.isEmpty {
                Text("Noch kein Training diese Woche.").font(.footnote).foregroundStyle(.secondary)
            } else if !weakGroups.isEmpty {
                Text("Kaum dran diese Woche: \(weakGroups.joined(separator: ", ")).").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Geschätzt aus Art und Dauer deiner Trainings.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .cardSurface()
    }

    private var recentCard: some View {
        VStack(spacing: 0) {
            NavigationLink { WorkoutListView() } label: {
                HStack {
                    Text("Letzte Trainings").font(.headline)
                    Spacer()
                    Text("Alle").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if fit.workouts.isEmpty {
                Text("Noch keine Trainings in Apple Health.").font(.footnote).foregroundStyle(.secondary).padding([.horizontal, .bottom], 16)
            }
            ForEach(fit.workouts.prefix(3)) { w in
                NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutRow(w: w).padding(.horizontal, 16).padding(.vertical, 8) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .cardSurface()
    }
}

// MARK: - Bausteine

struct ActivityRings: UIViewRepresentable {
    let summary: HKActivitySummary?
    func makeUIView(context: Context) -> HKActivityRingView { HKActivityRingView() }
    func updateUIView(_ v: HKActivityRingView, context: Context) { v.setActivitySummary(summary, animated: true) }
}

struct WorkoutRow: View {
    let w: FitWorkout
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: w.sport.symbol).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(w.sport.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name).font(.subheadline.weight(.semibold))
                Text(([w.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))]
                      + [w.km.map { FitFmt.num($0, 1) + " km" }, w.avgHR.map { "Ø \(Int($0)) Puls" }].compactMap { $0 })
                        .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FitFmt.dur(w.duration)).font(.subheadline.weight(.bold)).monospacedDigit()
                if let k = w.kcal { Text("\(FitFmt.int(k)) kcal").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .contentShape(Rectangle())
    }
}

enum FitFmt {
    static func num(_ v: Double, _ digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE")))
    }
    static func int(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "de_DE"))) }
    static func kg(_ v: Double) -> String { (v == v.rounded() ? int(v) : num(v, 1)) + " kg" }
    /// Stunden als „1:32 Std“
    static func hm(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        return "\(m / 60):" + String(format: "%02d", m % 60) + " Std"
    }
    static func dur(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return m < 60 ? "\(m) Min" : "\(m / 60):" + String(format: "%02d", m % 60) + " Std"
    }
}

struct FitnessGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var startKg: Double
    @Binding var goalKg: Double

    var body: some View {
        NavigationStack {
            Form {
                Section("Gewicht") {
                    Stepper(value: $startKg, in: 50...250, step: 0.5) { LabeledContent("Start", value: FitFmt.kg(startKg)) }
                    Stepper(value: $goalKg, in: 50...250, step: 0.5) { LabeledContent("Ziel", value: FitFmt.kg(goalKg)) }
                }
                Section {
                    Text("Das aktuelle Gewicht kommt aus Apple Health (Waage oder Health-App).").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mein Ziel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Meine Trainings (Entwurf 3)

struct WorkoutListView: View {
    @State private var fit = FitnessModel.shared
    @State private var filter: Sport?

    private var list: [FitWorkout] { fit.workouts.filter { filter == nil || $0.sport == filter } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(nil, "Alle")
                        ForEach(Sport.allCases) { s in
                            if fit.workouts.contains(where: { $0.sport == s }) { chip(s, s.title) }
                        }
                    }
                }
                monthCard
                ForEach(weeks, id: \.0) { entry in
                    let items = entry.1
                    Text(entry.0).font(.footnote.weight(.bold)).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, w in
                            NavigationLink { WorkoutDetailView(workout: w) } label: { WorkoutRow(w: w).padding(.horizontal, 14).padding(.vertical, 10) }
                                .buttonStyle(.plain)
                            if i < items.count - 1 { Divider().padding(.leading, 68) }
                        }
                    }
                    .cardSurface()
                }
                if list.isEmpty {
                    Text("Keine Trainings gefunden.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Meine Trainings")
        .refreshable { await fit.refresh(maxAge: 0) }
    }

    private func chip(_ s: Sport?, _ title: String) -> some View {
        let on = filter == s
        return Button { withAnimation { filter = s } } label: {
            Text(title).font(.subheadline.weight(.bold))
                .padding(.horizontal, 14).frame(height: 38)
                .foregroundStyle(on ? .white : .primary)
                .background(on ? AnyShapeStyle(s?.color ?? Color.primary) : AnyShapeStyle(.regularMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var monthCard: some View {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let month = list.filter { $0.start >= start }
        let hours = month.map(\.duration).reduce(0, +) / 3600
        let kcal = month.compactMap(\.kcal).reduce(0, +)
        let bySport = Dictionary(grouping: month, by: \.sport)
        let total = max(1, month.map(\.duration).reduce(0, +))
        return VStack(alignment: .leading, spacing: 12) {
            Text(Date.now.formatted(.dateTime.month(.wide))).font(.headline)
            HStack {
                stat("\(month.count)", "Trainings")
                stat(FitFmt.num(hours, 1), "Stunden")
                stat(FitFmt.int(kcal), "kcal")
            }
            if !month.isEmpty {
                GeometryReader { g in
                    HStack(spacing: 0) {
                        ForEach(Sport.allCases) { s in
                            let d = bySport[s]?.map(\.duration).reduce(0, +) ?? 0
                            if d > 0 { Rectangle().fill(s.color).frame(width: g.size.width * d / total) }
                        }
                    }
                }
                .frame(height: 12).clipShape(Capsule())
                Text(Sport.allCases.compactMap { s -> String? in
                    guard let l = bySport[s], !l.isEmpty else { return nil }
                    let km = l.compactMap(\.km).reduce(0, +)
                    return "\(s.title) \(l.count)×" + (km > 0 ? " · \(FitFmt.int(km)) km" : "")
                }.joined(separator: "   "))
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func stat(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(big).font(.title2.weight(.heavy)).monospacedDigit()
            Text(small).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weeks: [(String, [FitWorkout])] {
        let thisWeek = FitnessModel.startOfWeek
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let groups = Dictionary(grouping: list.prefix(120)) { cal.dateInterval(of: .weekOfYear, for: $0.start)?.start ?? $0.start }
        return groups.keys.sorted(by: >).map { k in
            let title: String
            if k == thisWeek { title = "DIESE WOCHE" }
            else if k == cal.date(byAdding: .day, value: -7, to: thisWeek) { title = "LETZTE WOCHE" }
            else { title = "WOCHE AB " + k.formatted(.dateTime.day().month(.abbreviated)).uppercased() }
            return (title, Array(groups[k] ?? []))
        }
    }
}

// MARK: - Training im Detail (Entwurf 4)

struct WorkoutDetailView: View {
    let workout: FitWorkout
    @State private var fit = FitnessModel.shared
    @State private var hr: [FitPoint] = []
    @State private var route: [CLLocationCoordinate2D] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if route.count > 1 {
                    Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                        MapPolyline(coordinates: route).stroke(workout.sport.color, lineWidth: 5)
                        if let f = route.first {
                            Annotation("Start", coordinate: f) { Circle().fill(.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3)) }
                                .annotationTitles(.hidden)
                        }
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
                }
                HStack(spacing: 12) {
                    Image(systemName: workout.sport.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(workout.sport.color.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.name).font(.title2.weight(.bold))
                        Text(workout.start.formatted(.dateTime.weekday(.wide).day().month(.wide)) + " · "
                             + workout.start.formatted(date: .omitted, time: .shortened) + "–" + workout.end.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    tile("Dauer", FitFmt.dur(workout.duration))
                    tile("kcal", workout.kcal.map { FitFmt.int($0) } ?? "–")
                    tile("Ø Puls", workout.avgHR.map { "\(Int($0))" } ?? "–")
                    if let km = workout.km {
                        tile("Strecke", FitFmt.num(km, 1) + " km")
                        let h = workout.duration / 3600
                        tile(workout.sport == .schwimmen ? "pro 100 m" : "Ø Tempo",
                             workout.sport == .schwimmen ? FitFmt.dur(workout.duration / (km * 10)) : FitFmt.num(km / max(h, 0.01), 1) + " km/h")
                    }
                    tile("Max. Puls", workout.maxHR.map { "\(Int($0))" } ?? "–")
                }
                if hr.count > 2 { heartCard }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Muskeln").font(.headline)
                    BodyMapView(load: workout.sport.muscles).frame(maxWidth: 300).frame(maxWidth: .infinity)
                }
                .padding(16).cardSurface()
                Text("Aufgezeichnet mit \(workout.source)").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle(workout.sport.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let h = fit.heartRates(for: workout)
            async let r = fit.route(for: workout)
            hr = await h
            route = await r
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.weight(.heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 16)
    }

    private var heartCard: some View {
        let maxHR = Double(220 - (fit.age ?? 40))
        let zones: [(String, ClosedRange<Double>, Color)] = [
            ("Locker", 0...0.6, Color(red: 0.61, green: 0.79, blue: 1)), ("Fettverbrennung", 0.6...0.7, .blue),
            ("Ausdauer", 0.7...0.8, .orange), ("Schwelle", 0.8...0.9, Color(red: 1, green: 0.42, blue: 0.17)), ("Maximum", 0.9...2, .red)
        ]
        var secs = Array(repeating: 0.0, count: zones.count)
        for (a, b) in zip(hr, hr.dropFirst()) {
            let dt = min(30, b.date.timeIntervalSince(a.date))
            let rel = a.value / maxHR
            if let i = zones.firstIndex(where: { $0.1.contains(rel) }) { secs[i] += dt }
        }
        let total = max(1, secs.reduce(0, +))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Herzfrequenz").font(.headline)
            Chart(hr) { p in
                LineMark(x: .value("Zeit", p.date), y: .value("Puls", p.value)).foregroundStyle(.red).interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 110)
            Text("Pulszonen").font(.subheadline.weight(.semibold)).padding(.top, 4)
            ForEach(zones.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text(zones[i].0).font(.caption).frame(width: 104, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(zones[i].2).frame(width: g.size.width * secs[i] / total)
                        }
                    }
                    .frame(height: 10)
                    Text(FitFmt.dur(secs[i])).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
            Text("Zonen bezogen auf max. Puls ca. \(Int(maxHR)) (220 − Alter).").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .cardSurface()
    }
}

// MARK: - Entwicklung (Entwurf 5)

struct FitnessProgressView: View {
    @State private var fit = FitnessModel.shared
    @State private var range = 90
    @AppStorage("fitGoalKg") private var goalKg = FitnessConfig.defaultGoalKg

    private var from: Date { Calendar.current.date(byAdding: .day, value: -range, to: .now)! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Zeitraum", selection: $range) {
                    Text("4 Wo.").tag(28)
                    Text("3 Mon.").tag(90)
                    Text("6 Mon.").tag(182)
                    Text("1 Jahr").tag(365)
                }
                .pickerStyle(.segmented)
                weightCard
                minutesCard
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    trendTile("Ruhepuls", fit.restingHR, unit: "", digits: 0, lowerIsBetter: true)
                    trendTile("VO₂max", fit.vo2, unit: "", digits: 1, lowerIsBetter: false)
                    trendTile("Körperfett", fit.bodyFat, unit: " %", digits: 1, lowerIsBetter: true)
                    trendTile("Ø Schlaf", fit.sleep, unit: " Std", digits: 1, lowerIsBetter: false)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Entwicklung")
    }

    private var weightCard: some View {
        let pts = fit.weights.filter { $0.date >= from }
        let delta = (pts.last?.value ?? 0) - (pts.first?.value ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gewicht").font(.headline)
                Spacer()
                if pts.count > 1 {
                    Text((delta <= 0 ? "−" : "+") + FitFmt.num(abs(delta), 1) + " kg")
                        .font(.headline).foregroundStyle(delta <= 0 ? .green : .orange)
                }
            }
            if pts.count > 1 {
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Datum", p.date), y: .value("kg", p.value)).foregroundStyle(Sport.gym.color).interpolationMethod(.catmullRom)
                        PointMark(x: .value("Datum", p.date), y: .value("kg", p.value)).foregroundStyle(Sport.gym.color).symbolSize(12)
                    }
                    RuleMark(y: .value("Ziel", goalKg)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
                if let t = fit.weeklyTrend {
                    Text("Ø \(t <= 0 ? "−" : "+")\(FitFmt.num(abs(t), 2)) kg pro Woche (letzte 8 Wochen) · gestrichelt: Ziel \(FitFmt.kg(goalKg))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Zu wenig Gewichtswerte in diesem Zeitraum.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private struct WeekBar: Identifiable { let week: Date; let sport: Sport; let hours: Double; var id: String { "\(week)\(sport.rawValue)" } }

    private var minutesCard: some View {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let list = fit.workouts.filter { $0.start >= from }
        var bars: [WeekBar] = []
        let grouped = Dictionary(grouping: list) { cal.dateInterval(of: .weekOfYear, for: $0.start)?.start ?? $0.start }
        for (wk, items) in grouped {
            for (s, l) in Dictionary(grouping: items, by: \.sport) {
                bars.append(WeekBar(week: wk, sport: s, hours: l.map(\.duration).reduce(0, +) / 3600))
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Trainingszeit pro Woche").font(.headline)
            if bars.isEmpty {
                Text("Keine Trainings in diesem Zeitraum.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart(bars) { b in
                    BarMark(x: .value("Woche", b.week, unit: .weekOfYear), y: .value("Stunden", b.hours))
                        .foregroundStyle(b.sport.color)
                }
                .chartYAxisLabel("Std")
                .frame(height: 150)
                HStack(spacing: 12) {
                    ForEach(Sport.allCases.filter { s in bars.contains { $0.sport == s } }) { s in
                        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 9, height: 9); Text(s.title) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func trendTile(_ title: String, _ all: [FitPoint], unit: String, digits: Int, lowerIsBetter: Bool) -> some View {
        let pts = all.filter { $0.date >= from }
        let first = pts.prefix(max(1, pts.count / 5)).map(\.value)
        let last = pts.suffix(max(1, pts.count / 5)).map(\.value)
        let a = first.isEmpty ? nil : first.reduce(0, +) / Double(first.count)
        let b = last.isEmpty ? nil : last.reduce(0, +) / Double(last.count)
        let delta = (a != nil && b != nil) ? b! - a! : nil
        let good = delta.map { lowerIsBetter ? $0 <= 0 : $0 >= 0 } ?? true
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(b.map { FitFmt.num($0, digits) + unit } ?? "–").font(.title3.weight(.heavy)).monospacedDigit()
            if let d = delta {
                Text((d >= 0 ? "+" : "−") + FitFmt.num(abs(d), digits) + unit).font(.caption.weight(.semibold)).foregroundStyle(good ? .green : .orange)
            }
            if pts.count > 2 {
                Chart(pts) { p in
                    LineMark(x: .value("Datum", p.date), y: .value(title, p.value)).foregroundStyle(good ? Color.green : Color.orange)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 34)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
