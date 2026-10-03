import SwiftUI

// MARK: - Gym-Training auf dem iPhone (Entwürfe 6, 7 mit V7, 11)

private enum GymStyle {
    static let orange = Color(red: 1.0, green: 0.48, blue: 0.10)
    static let orangeLight = Color(red: 1.0, green: 0.60, blue: 0.30)
    static let bg = Color(red: 0.05, green: 0.05, blue: 0.063)
    static let card = Color.white.opacity(0.05)
    static let green = Color(red: 0.18, green: 0.75, blue: 0.36)
}

/// Dunkler Hintergrund mit orangem Leuchten
private struct GymBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            GymStyle.bg
            Circle().fill(GymStyle.orange).frame(width: 460, height: 460).blur(radius: 130).opacity(0.33).offset(x: -110, y: -200)
            Circle().fill(Color(red: 1, green: 0.18, blue: 0.33)).frame(width: 300, height: 300).blur(radius: 120).opacity(0.2).offset(x: 140, y: 40)
        }
        .ignoresSafeArea()
    }
}

/// Geräte-Piktogramm (Linien aus dem Entwurf)
struct GymMachineIcon: View {
    let path: String
    var color: Color = GymStyle.orangeLight
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            var c = ctx
            c.translateBy(x: (size.width - 24 * s) / 2, y: (size.height - 24 * s) / 2)
            c.scaleBy(x: s, y: s)
            c.stroke(BodyShapes.svg(path), with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: Einstieg (aus Plan oder Übersicht)

struct GymStartCard: View {
    let program: GymProgram
    @State private var gym = GymModel.shared

    var body: some View {
        NavigationLink {
            GymSessionView(program: program)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "dumbbell.fill").font(.title3.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(GymStyle.orange.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gym.run != nil ? "Training läuft" : "Heute: \(program.title)").font(.headline)
                    Text(gym.run != nil ? "\(gym.doneCount) von \(gym.exercisesInOrder.count) Geräten · weiter" :
                            program.exercises.prefix(3).map(\.name).joined(separator: ", ") + " …")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(gym.run != nil ? "Weiter" : "Starten").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9).background(GymStyle.orange, in: Capsule())
            }
            .padding(14)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }
}

// MARK: Training läuft (Entwurf 6)

struct GymSessionView: View {
    let program: GymProgram
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var gym = GymModel.shared
    @State private var showExercise: GymExercise?
    @State private var summary: GymLog?
    @State private var confirmEnd = false
    @State private var myTab = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if gym.run == nil {
                    startPanel
                } else {
                    header
                    ForEach(gym.exercisesInOrder) { ex in exerciseCard(ex) }
                    HStack(spacing: 10) {
                        if let cur = gym.current {
                            Button { withAnimation { gym.postpone(cur) } } label: {
                                Text("Gerät besetzt? Später").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.18)))
                        }
                        Button { confirmEnd = true } label: {
                            Text("Training beenden").font(.subheadline.weight(.heavy)).foregroundStyle(GymStyle.bg)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.plain)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .foregroundStyle(.white)
        .background(GymBackground())
        .environment(\.colorScheme, .dark)
        .navigationTitle(program.short)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $showExercise) { ex in GymExerciseView(exercise: ex) }
        .sheet(item: $summary) { log in GymSummaryView(log: log) }
        .confirmationDialog("Training beenden?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Beenden und in Apple Health speichern") { finish(true) }
            Button("Beenden ohne Apple Health") { finish(false) }
            Button("Verwerfen", role: .destructive) { gym.cancel() }
        } message: {
            Text("Hast du das Training auf der Watch aufgezeichnet, speichert die App es nicht doppelt.")
        }
        .onAppear { myTab = store.selectedTab; TabBarVisibility.shared.hide(myTab) }
        .onDisappear { TabBarVisibility.shared.show(myTab) }
    }

    private func finish(_ health: Bool) {
        Task { summary = await gym.finish(saveToHealth: health) }
    }

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(program.title).font(.largeTitle.weight(.heavy))
            Text("MC Shape Nersingen · ca. 55 Min · 10 Min Aufwärmen auf Crosstrainer oder Rad")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            VStack(spacing: 8) {
                ForEach(program.exercises) { ex in
                    HStack(spacing: 12) {
                        GymMachineIcon(path: ex.icon).frame(width: 30, height: 30)
                            .frame(width: 46, height: 46).background(GymStyle.card, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ex.name).font(.subheadline.weight(.bold))
                            Text(ex.machine).font(.caption2).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Text("\(ex.sets) × \(ex.repsText)").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                        if !ex.seconds { Text(FitFmt.kg(gym.suggestedWeight(ex))).font(.caption.weight(.heavy)).foregroundStyle(GymStyle.orangeLight) }
                    }
                }
            }
            .padding(14)
            .background(GymStyle.card, in: RoundedRectangle(cornerRadius: 20))
            Button { withAnimation { gym.start(program) } } label: {
                Text("Training starten").font(.headline.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.plain)
            .background(GymStyle.orange, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: GymStyle.orange.opacity(0.4), radius: 18, y: 10)
            Text("Tipp: Auf der Watch zusätzlich „Krafttraining“ starten – dann kommen Puls und Kalorien dazu.")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var header: some View {
        let total = gym.exercisesInOrder.count
        return TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(GymStyle.orange.opacity(0.2), lineWidth: 10)
                    Circle().trim(from: 0, to: total > 0 ? Double(gym.doneCount) / Double(total) : 0)
                        .stroke(GymStyle.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(gym.doneCount)/\(total)").font(.title3.weight(.heavy))
                        Text("Geräte").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 92, height: 92)
                .animation(.easeOut, value: gym.doneCount)
                VStack(alignment: .leading, spacing: 3) {
                    Text(program.title.uppercased()).font(.caption.weight(.heavy)).tracking(1).foregroundStyle(GymStyle.orangeLight)
                    Text(Self.clock(ctx.date.timeIntervalSince(gym.run?.start ?? .now))).font(.system(size: 32, weight: .heavy)).monospacedDigit()
                    if let until = gym.run?.restUntil, until > ctx.date {
                        Text("Pause noch \(Int(until.timeIntervalSince(ctx.date))) s").font(.subheadline.weight(.bold)).foregroundStyle(GymStyle.green)
                    } else {
                        Text("\(gym.run?.sets.values.map(\.count).reduce(0, +) ?? 0) Sätze geschafft").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func exerciseCard(_ ex: GymExercise) -> some View {
        let done = gym.isDone(ex)
        let cur = gym.current?.id == ex.id
        let n = gym.run?.sets[ex.id]?.count ?? 0
        let w = gym.run?.weights[ex.id] ?? 0
        let lastW = gym.last(ex)?.map(\.weight).max()
        return Button { showExercise = ex } label: {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(done ? AnyShapeStyle(GymStyle.green) : (cur ? AnyShapeStyle(GymStyle.orange) : AnyShapeStyle(Color.white.opacity(0.08))))
                        if done {
                            Image(systemName: "checkmark").font(.title3.weight(.heavy))
                        } else {
                            GymMachineIcon(path: ex.icon, color: cur ? .white : Color.white.opacity(0.8), lineWidth: 1.8).frame(width: 30, height: 30)
                        }
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ex.name).font(.headline)
                        Text(ex.machine).font(.caption2).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ex.seconds ? "\(gym.run?.reps[ex.id] ?? ex.repsLow) s" : FitFmt.kg(w)).font(.title3.weight(.heavy)).monospacedDigit()
                        if let lastW, !ex.seconds {
                            Text(w > lastW ? "↑ letztes Mal \(FitFmt.num(lastW, 1))" : "wie letztes Mal")
                                .font(.caption2).foregroundStyle(w > lastW ? GymStyle.green : .white.opacity(0.55))
                        } else if !ex.seconds {
                            Text("erstes Mal – leicht starten").font(.caption2).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("\(ex.sets) × \(ex.repsText)").font(.caption).foregroundStyle(.white.opacity(0.6)).frame(width: 76, alignment: .leading)
                    ForEach(0..<ex.sets, id: \.self) { i in
                        Text(i < n ? "✓" : "\(i + 1)").font(.caption.weight(.heavy))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(i < n ? AnyShapeStyle(GymStyle.orange) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(i < n ? .clear : .white.opacity(0.2), lineWidth: 1.5))
                    }
                }
            }
            .padding(12)
            .background(cur ? GymStyle.orange.opacity(0.12) : GymStyle.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(cur ? GymStyle.orange : .white.opacity(0.08), lineWidth: cur ? 1.5 : 1))
            .opacity(done ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Gerät (Entwurf 7 mit Variante V7)

struct GymExerciseView: View {
    let exercise: GymExercise
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var gym = GymModel.shared
    @State private var myTab = ""

    private var ex: GymExercise { exercise }

    var body: some View {
        let n = gym.run?.sets[ex.id]?.count ?? 0
        let done = n >= ex.sets
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let restLeft = gym.run?.restUntil.map { max(0, Int($0.timeIntervalSince(ctx.date))) } ?? 0
            ScrollView {
                VStack(spacing: 16) {
                    // Gerät im Kreis
                    ZStack {
                        Circle().fill(RadialGradient(colors: [GymStyle.orange.opacity(0.35), GymStyle.orange.opacity(0.05)], center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: 110))
                        Circle().strokeBorder(GymStyle.orange.opacity(0.4))
                        GymMachineIcon(path: ex.icon).padding(36)
                    }
                    .frame(width: 186, height: 186)
                    // Name links, Körper rechts
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ex.name).font(.system(size: 28, weight: .heavy))
                            Text(ex.machine).font(.caption).foregroundStyle(.white.opacity(0.6))
                            Text(ex.muscles.sorted { $0.value > $1.value }.prefix(2).map(\.key.title).joined(separator: " · "))
                                .font(.caption.weight(.semibold)).foregroundStyle(GymStyle.orangeLight)
                        }
                        Spacer()
                        BodyMapView(load: ex.muscles, showLabels: false).frame(width: 122)
                    }
                    if !ex.seconds {
                        valueRow(title: "kg", value: FitFmt.num(gym.run?.weights[ex.id] ?? 0, (gym.run?.weights[ex.id] ?? 0).truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1),
                                 minus: { gym.setWeight(ex, (gym.run?.weights[ex.id] ?? 0) - ex.step) },
                                 plus: { gym.setWeight(ex, (gym.run?.weights[ex.id] ?? 0) + ex.step) },
                                 hint: "Stift auf \(Int(((gym.run?.weights[ex.id] ?? 0) / max(ex.step, 1)).rounded()))")
                    }
                    valueRow(title: ex.seconds ? "Sekunden" : "Wiederholungen", value: "\(gym.run?.reps[ex.id] ?? ex.repsLow)",
                             minus: { gym.setReps(ex, (gym.run?.reps[ex.id] ?? ex.repsLow) - (ex.seconds ? 5 : 1)) },
                             plus: { gym.setReps(ex, (gym.run?.reps[ex.id] ?? ex.repsLow) + (ex.seconds ? 5 : 1)) },
                             hint: "Ziel \(ex.repsText)", big: false)
                    HStack(spacing: 10) {
                        ForEach(0..<ex.sets, id: \.self) { i in
                            let log = gym.run?.sets[ex.id]?[safe: i]
                            VStack(spacing: 2) {
                                Text("Satz \(i + 1)").font(.caption2).foregroundStyle(i < n ? .white.opacity(0.85) : .white.opacity(0.55))
                                Text(log.map { "✓ \($0.reps)" } ?? (i == n ? "jetzt" : ex.repsText)).font(.headline.weight(.heavy))
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(i < n ? AnyShapeStyle(GymStyle.orange) : AnyShapeStyle(Color.white.opacity(0.06)), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(i == n ? GymStyle.orange : .white.opacity(0.1), lineWidth: i == n ? 1.5 : 1))
                        }
                    }
                    if restLeft > 0 {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().stroke(GymStyle.green.opacity(0.2), lineWidth: 6)
                                Circle().trim(from: 0, to: Double(restLeft) / Double(ex.rest))
                                    .stroke(GymStyle.green, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                            }
                            .frame(width: 54, height: 54)
                            VStack(alignment: .leading) {
                                Text(GymSessionView.clock(Double(restLeft))).font(.title2.weight(.heavy)).monospacedDigit()
                                Text("Pause · trinken, durchatmen").font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                            Button("Überspringen") { gym.skipRest() }.font(.subheadline.weight(.semibold)).tint(GymStyle.green)
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        Text(ex.tip).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    }
                    Button {
                        if done {
                            dismiss()
                        } else {
                            withAnimation { gym.logSet(ex) }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    } label: {
                        Text(done ? (gym.current.map { "Weiter: \($0.name) ›" } ?? "Alle Geräte geschafft ›") : "Satz \(n + 1) fertig")
                            .font(.headline.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.plain)
                    .background(done ? GymStyle.green : GymStyle.orange, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(color: (done ? GymStyle.green : GymStyle.orange).opacity(0.35), radius: 16, y: 10)
                    if n > 0 {
                        Button("Letzten Satz zurücknehmen") { withAnimation { gym.undoSet(ex) } }
                            .font(.footnote).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .foregroundStyle(.white)
        .background(GymBackground())
        .environment(\.colorScheme, .dark)
        .navigationTitle(gymIndexTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { myTab = store.selectedTab; TabBarVisibility.shared.hide(myTab) }
        .onDisappear { TabBarVisibility.shared.show(myTab) }
    }

    private var gymIndexTitle: String {
        let list = gym.exercisesInOrder
        guard let i = list.firstIndex(of: ex) else { return ex.name }
        return "Gerät \(i + 1) von \(list.count)"
    }

    private func valueRow(title: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void, hint: String, big: Bool = true) -> some View {
        HStack(spacing: 18) {
            Button(action: minus) {
                Image(systemName: "minus").font(.title3.weight(.bold)).frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.07), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) weniger")
            VStack(spacing: 0) {
                Text(value).font(.system(size: big ? 52 : 34, weight: .heavy)).monospacedDigit().contentTransition(.numericText())
                Text("\(title) · \(hint)").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .frame(minWidth: 150)
            Button(action: plus) {
                Image(systemName: "plus").font(.title3.weight(.bold)).frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.07), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) mehr")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: Geschafft (Entwurf 11)

struct GymSummaryView: View {
    let log: GymLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GESCHAFFT · " + log.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                            .font(.caption.weight(.heavy)).tracking(1).foregroundStyle(GymStyle.green)
                        Text(log.program.title).font(.title.weight(.heavy))
                    }
                    HStack {
                        stat("Zeit", FitFmt.dur(log.end.timeIntervalSince(log.start)))
                        stat("Sätze", "\(log.sets.values.map(\.count).reduce(0, +))")
                        stat("bewegt", log.volume >= 1000 ? FitFmt.num(log.volume / 1000, 1) + " t" : FitFmt.int(log.volume) + " kg")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trainierte Muskeln").font(.caption.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        BodyMapView(load: log.muscles).frame(maxWidth: 340).frame(maxWidth: .infinity)
                    }
                    .padding(14)
                    .background(GymStyle.card, in: RoundedRectangle(cornerRadius: 24))
                    VStack(spacing: 0) {
                        ForEach(log.program.exercises.filter { log.sets[$0.id] != nil }) { ex in
                            let sets = log.sets[ex.id] ?? []
                            HStack {
                                Text(ex.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sets.map { ex.seconds ? "\($0.reps) s" : "\($0.reps)×\(FitFmt.num($0.weight, 0))" }.joined(separator: "  "))
                                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.vertical, 10).padding(.horizontal, 14)
                            Divider().overlay(.white.opacity(0.06))
                        }
                    }
                    .background(GymStyle.card, in: RoundedRectangle(cornerRadius: 20))
                    let next = log.program == .a ? GymProgram.b : GymProgram.a
                    Text("Nächstes Mal: **\(next.title)** – \(next.exercises.prefix(3).map(\.name).joined(separator: ", ")).")
                        .font(.subheadline).foregroundStyle(Color(red: 0.78, green: 0.96, blue: 0.84))
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(GymStyle.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(18)
            }
            .foregroundStyle(.white)
            .background(GymBackground())
            .environment(\.colorScheme, .dark)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }

    private func stat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.caption).foregroundStyle(.white.opacity(0.6))
            Text(v).font(.title3.weight(.heavy)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
