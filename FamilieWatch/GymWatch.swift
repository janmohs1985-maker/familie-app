import SwiftUI
import WatchKit
import HealthKit
import WatchConnectivity

// MARK: - Gym-Training auf der Uhr (Entwürfe 8–10, 14)
//
// Plan und vorgeschlagene Gewichte kommen vom iPhone (Kontext „gym“). Die Uhr zeichnet ein Krafttraining
// in Apple Health auf (Puls, Kalorien) und schickt die Sätze am Ende ans iPhone.

struct WGymExercise: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let machine: String
    let icon: String
    let muscles: [String: Double]
    let sets: Int
    let repsLow: Int
    let repsHigh: Int
    let seconds: Bool
    let weight: Double
    let reps: Int
    let step: Double
    let rest: Int
    let tip: String
}

struct WGymProgram: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let short: String
    let exercises: [WGymExercise]
}

struct WGymData: Codable, Equatable {
    let next: String
    let programs: [WGymProgram]

    static func == (a: WGymData, b: WGymData) -> Bool { a.next == b.next && a.programs.map(\.id) == b.programs.map(\.id) }
}

struct WGymSet: Codable, Hashable {
    var weight: Double
    var reps: Int
}

struct WGymLog: Codable {
    var id = UUID()
    var program: String
    var start: Date
    var end: Date
    var sets: [String: [WGymSet]]
}

private let gymOrange = Color(red: 1.0, green: 0.48, blue: 0.10)
private let gymOrangeLight = Color(red: 1.0, green: 0.60, blue: 0.30)
private let gymGreen = Color(red: 0.29, green: 0.87, blue: 0.50)

/// Geräte-Piktogramm
struct WMachineIcon: View {
    let path: String
    var color: Color = gymOrangeLight
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            var c = ctx
            c.translateBy(x: (size.width - 24 * s) / 2, y: (size.height - 24 * s) / 2)
            c.scaleBy(x: s, y: s)
            c.stroke(BodyShapes.svg(path), with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: Aufzeichnung (Apple Health)

@MainActor
final class WatchWorkout: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    @Published var heartRate: Double?
    @Published var kcal: Double = 0
    @Published var recording = false

    func start() async {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)],
                                                 read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)])
            let cfg = HKWorkoutConfiguration()
            cfg.activityType = .traditionalStrengthTraining
            cfg.locationType = .indoor
            let s = try HKWorkoutSession(healthStore: store, configuration: cfg)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: cfg)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            let now = Date()
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            recording = true
        } catch {
            // ohne Apple Health geht es trotzdem – dann eben ohne Puls/Kalorien
            recording = false
        }
    }

    /// Beenden und speichern → (kcal, Ø Puls)
    func finish() async -> (Double, Double?) {
        guard let s = session, let b = builder else { return (0, nil) }
        s.end()
        let avg = b.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        do {
            try await b.endCollection(at: .now)
            try await b.addMetadata([HKMetadataKeyWorkoutBrandName: "Familie Gym"])
            _ = try await b.finishWorkout()
        } catch {}
        session = nil
        builder = nil
        recording = false
        return (kcal, avg)
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?.doubleValue(for: bpm)
        let k = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            if let hr { self.heartRate = hr }
            if let k { self.kcal = k }
        }
    }
}

// MARK: Ablauf

@MainActor
final class WGymRun: ObservableObject {
    enum Phase { case work, rest, next, done }

    let program: WGymProgram
    let start = Date()
    @Published var order: [String]
    @Published var sets: [String: [WGymSet]] = [:]
    @Published var weights: [String: Double] = [:]
    @Published var reps: [String: Int] = [:]
    @Published var phase: Phase = .work
    @Published var restUntil: Date?
    @Published var currentID: String
    @Published var result: (kcal: Double, hr: Double?)?
    let workout = WatchWorkout()

    init(program: WGymProgram) {
        self.program = program
        order = program.exercises.map(\.id)
        currentID = program.exercises.first?.id ?? ""
        for ex in program.exercises {
            weights[ex.id] = ex.weight
            reps[ex.id] = ex.reps
        }
    }

    func ex(_ id: String) -> WGymExercise? { program.exercises.first { $0.id == id } }
    var current: WGymExercise? { ex(currentID) }
    func done(_ e: WGymExercise) -> Bool { (sets[e.id]?.count ?? 0) >= e.sets }
    var doneCount: Int { program.exercises.filter { done($0) }.count }
    var nextOpen: WGymExercise? { order.compactMap { ex($0) }.first { !done($0) } }

    func logSet() {
        guard let e = current else { return }
        sets[e.id, default: []].append(WGymSet(weight: weights[e.id] ?? 0, reps: reps[e.id] ?? e.repsLow))
        WKInterfaceDevice.current().play(.success)
        if done(e) {
            restUntil = nil
            phase = nextOpen == nil ? .done : .next
        } else {
            restUntil = Date().addingTimeInterval(Double(e.rest))
            phase = .rest
            let until = restUntil
            Task {
                try? await Task.sleep(for: .seconds(e.rest))
                if self.phase == .rest, self.restUntil == until {
                    WKInterfaceDevice.current().play(.notification)
                    self.phase = .work
                    self.restUntil = nil
                }
            }
        }
    }

    func skipRest() {
        restUntil = nil
        phase = .work
    }

    func goNext() {
        if let n = nextOpen { currentID = n.id; phase = .work } else { phase = .done }
    }

    func jump(to id: String) {
        currentID = id
        restUntil = nil
        phase = .work
    }

    /// Gerät besetzt → ans Ende
    func postpone() {
        guard let e = current, let i = order.firstIndex(of: e.id) else { return }
        order.remove(at: i)
        order.append(e.id)
        goNext()
    }

    func finish() async {
        let r = await workout.finish()
        result = (r.0, r.1)
        phase = .done
        let log = WGymLog(program: program.id, start: start, end: Date(), sets: sets.filter { !$0.value.isEmpty })
        guard !log.sets.isEmpty else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(log), WCSession.default.activationState == .activated {
            WCSession.default.transferUserInfo(["gymLog": String(decoding: d, as: UTF8.self)])
        }
    }

    var muscleLoad: [Muscle: Double] {
        var sum: [Muscle: Double] = [:]
        for e in program.exercises {
            let n = Double(sets[e.id]?.count ?? 0)
            for (k, v) in e.muscles { if let m = Muscle(rawValue: k) { sum[m, default: 0] += v * n } }
        }
        let mx = sum.values.max() ?? 0
        return mx > 0 ? sum.mapValues { $0 / mx } : [:]
    }
}

// MARK: Auswahl A / B

struct GymWatchStart: View {
    let data: WGymData

    var body: some View {
        List {
            ForEach(data.programs.sorted { a, _ in a.id == data.next }) { p in
                NavigationLink { GymWatchRunView(program: p) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.short).font(.headline)
                            if p.id == data.next { Text("dran").font(.caption2.weight(.bold)).foregroundStyle(gymOrange) }
                        }
                        Text(p.exercises.prefix(3).map(\.name).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .listItemTint(p.id == data.next ? gymOrange.opacity(0.35) : nil)
            }
        }
        .navigationTitle("Gym")
    }
}

// MARK: Training

struct GymWatchRunView: View {
    @StateObject private var run: WGymRun
    @State private var showList = false
    @State private var crown: Double = 0
    @State private var confirmEnd = false

    init(program: WGymProgram) { _run = StateObject(wrappedValue: WGymRun(program: program)) }

    var body: some View {
        Group {
            switch run.phase {
            case .work: workView
            case .rest: restView
            case .next: nextView
            case .done: doneView
            }
        }
        .toolbar {
            if run.phase != .done {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showList = true } label: { Image(systemName: "list.bullet") }
                }
            }
        }
        .sheet(isPresented: $showList) { listView }
        .task { await run.workout.start() }
        .navigationBarBackButtonHidden(run.phase != .done)
    }

    // Übung (Entwurf 8)
    private var workView: some View {
        let e = run.current
        let n = e.map { run.sets[$0.id]?.count ?? 0 } ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(run.doneCount + 1)/\(run.program.exercises.count)").foregroundStyle(gymOrangeLight)
                Spacer()
                if let hr = run.workout.heartRate { Text("♥ \(Int(hr))").foregroundStyle(.red) }
            }
            .font(.caption.weight(.semibold))
            if let e {
                HStack(spacing: 6) {
                    WMachineIcon(path: e.icon).frame(width: 30, height: 30)
                    Text(e.name).font(.headline).lineLimit(2).minimumScaleFactor(0.7)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if e.seconds {
                        Text("\(run.reps[e.id] ?? e.reps)").font(.system(size: 44, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("s").font(.headline).foregroundStyle(gymOrangeLight)
                    } else {
                        Text(Self.kg(run.weights[e.id] ?? 0)).font(.system(size: 44, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("kg").font(.headline).foregroundStyle(gymOrangeLight)
                    }
                    Spacer()
                    Text(e.seconds ? "Ziel \(e.repsHigh) s" : "\(e.repsLow)–\(e.repsHigh)×").font(.caption2).foregroundStyle(.secondary)
                }
                .focusable(true)
                .digitalCrownRotation($crown, from: 0, through: 400, by: e.seconds ? 5 : max(e.step, 1),
                                       sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                .onChange(of: crown) { _, v in
                    if e.seconds { run.reps[e.id] = Int(v) } else { run.weights[e.id] = v }
                }
                .onAppear { crown = e.seconds ? Double(run.reps[e.id] ?? e.reps) : (run.weights[e.id] ?? 0) }
                .onChange(of: run.currentID) { _, _ in
                    if let c = run.current { crown = c.seconds ? Double(run.reps[c.id] ?? c.reps) : (run.weights[c.id] ?? 0) }
                }
                HStack(spacing: 4) {
                    ForEach(0..<e.sets, id: \.self) { i in
                        Capsule().fill(i < n ? gymOrange : (i == n ? gymOrange.opacity(0.45) : Color.white.opacity(0.15))).frame(height: 7)
                    }
                }
                Button { run.logSet() } label: {
                    Text("Satz \(n + 1) fertig").font(.headline.weight(.heavy)).frame(maxWidth: .infinity)
                }
                .tint(gymOrange)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 4)
    }

    // Pause
    private var restView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int((run.restUntil ?? ctx.date).timeIntervalSince(ctx.date)))
            let total = Double(run.current?.rest ?? 60)
            VStack(spacing: 4) {
                ZStack {
                    Circle().stroke(gymGreen.opacity(0.2), lineWidth: 11)
                    Circle().trim(from: 0, to: Double(left) / total)
                        .stroke(gymGreen, style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(left)").font(.system(size: 38, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("Pause").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                if let e = run.current {
                    Text("gleich Satz \((run.sets[e.id]?.count ?? 0) + 1)" + (e.seconds ? "" : " · \(Self.kg(run.weights[e.id] ?? 0)) kg"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { run.skipRest() }
        }
    }

    // Gerät geschafft → nächstes (Entwurf 8, letzter Schritt)
    private var nextView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("✓ \(run.current?.name.uppercased() ?? "") GESCHAFFT").font(.caption2.weight(.heavy)).foregroundStyle(gymGreen).lineLimit(2)
            Text("Als Nächstes").font(.caption).foregroundStyle(.secondary)
            if let n = run.nextOpen {
                HStack(spacing: 6) {
                    WMachineIcon(path: n.icon).frame(width: 28, height: 28)
                    Text(n.name).font(.headline).lineLimit(2).minimumScaleFactor(0.7)
                }
                Text(n.seconds ? "\(n.reps) s" : "\(Self.kg(n.weight)) kg").font(.title2.weight(.heavy))
            }
            Spacer(minLength: 2)
            Button("Los geht's") { run.goNext() }.tint(gymOrange).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 4)
    }

    // Geschafft (Entwurf 14)
    private var doneView: some View {
        ScrollView {
            VStack(spacing: 6) {
                if run.result == nil {
                    Text("Alle Geräte geschafft!").font(.headline).foregroundStyle(gymGreen)
                    Button("Training beenden") { Task { await run.finish() } }.tint(gymGreen).buttonStyle(.borderedProminent)
                } else {
                    Text("\(run.program.short) geschafft").font(.headline).foregroundStyle(gymGreen)
                    BodyMapView(load: run.muscleLoad, showLabels: false).frame(height: 110)
                    HStack {
                        stat("\(Int(Date().timeIntervalSince(run.start) / 60))′", "Zeit")
                        stat(run.result.map { "\(Int($0.kcal))" } ?? "–", "kcal")
                        stat(run.result?.hr.map { "\(Int($0))" } ?? "–", "Ø Puls")
                    }
                    Text("Ans iPhone gesendet").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 0) {
            Text(v).font(.headline.weight(.heavy))
            Text(l).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // Geräteliste (Entwurf 9)
    private var listView: some View {
        List {
            ForEach(run.order, id: \.self) { id in
                if let e = run.ex(id) {
                    Button {
                        run.jump(to: id)
                        showList = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: run.done(e) ? "checkmark.circle.fill" : (id == run.currentID ? "circle.inset.filled" : "circle"))
                                .foregroundStyle(run.done(e) ? gymGreen : (id == run.currentID ? gymOrange : .secondary))
                            Text(e.name).lineLimit(1).opacity(run.done(e) ? 0.55 : 1)
                            Spacer()
                            Text(e.seconds ? "\(run.reps[id] ?? e.reps)s" : Self.kg(run.weights[id] ?? 0)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Gerät besetzt – später") { run.postpone(); showList = false }
            Button("Training beenden", role: .destructive) { showList = false; Task { await run.finish() } }
        }
    }

    static func kg(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
}
