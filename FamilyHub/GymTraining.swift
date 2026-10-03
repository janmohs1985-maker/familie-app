import SwiftUI
import HealthKit
import UserNotifications

// MARK: - Gym-Training (Anfängerplan MC Shape Nersingen, Life Fitness Insignia)
//
// Zwei Ganzkörper-Tage A und B. Sätze werden abgehakt, Gewichte gemerkt und beim nächsten Mal
// vorgeschlagen (Steigerung, wenn alle Sätze die obere Wiederholungszahl erreicht haben).
// Verlauf liegt nur auf dem iPhone (Application Support/gym_verlauf.json).

struct GymExercise: Identifiable, Hashable {
    let id: String
    let name: String
    let machine: String
    let icon: String            // Piktogramm als SVG-Pfad (24×24, absolut)
    let muscles: [Muscle: Double]
    let sets: Int
    let repsLow: Int
    let repsHigh: Int
    let seconds: Bool           // Halteübung (Wiederholungen = Sekunden)
    let startWeight: Double
    let step: Double
    let rest: Int
    let tip: String

    var repsText: String { seconds ? "\(repsHigh) s" : "\(repsLow)–\(repsHigh)" }

    static func == (a: GymExercise, b: GymExercise) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum GymProgram: String, CaseIterable, Identifiable, Codable {
    case a, b
    var id: String { rawValue }
    var title: String { self == .a ? "Gym A · Ganzkörper" : "Gym B · Ganzkörper" }
    var short: String { self == .a ? "Gym A" : "Gym B" }

    static func from(title: String) -> GymProgram { title.lowercased().contains("gym b") ? .b : .a }

    var exercises: [GymExercise] {
        switch self {
        case .a: [
            GymExercise(id: "legpress", name: "Beinpresse", machine: "Insignia · Leg Press",
                        icon: "M4 18H11L14 12H18M14 12L17 6M17 6H20M6 18L4 21M11 18L12 21",
                        muscles: [.quads: 1, .glutes: 0.6, .hamstrings: 0.3], sets: 3, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 50, step: 5, rest: 90, tip: "2 Sek. drücken, 2 Sek. zurück. Knie nicht ganz durchstrecken, Rücken an der Lehne."),
            GymExercise(id: "chestpress", name: "Brustpresse", machine: "Insignia · Chest Press",
                        icon: "M6 4V20M18 4V20M6 10H10M14 10H18M10 10C10 12 14 12 14 10M9 20H15",
                        muscles: [.chest: 1, .delts: 0.5, .triceps: 0.5], sets: 3, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 25, step: 5, rest: 90, tip: "Griffe auf Brusthöhe. Schulterblätter nach hinten-unten, ruhig ausatmen beim Drücken."),
            GymExercise(id: "seatedrow", name: "Rudern sitzend", machine: "Insignia · Seated Row",
                        icon: "M3 12H8M16 12H21M8 12L12 9L16 12M12 9V17M8 20H16",
                        muscles: [.lats: 1, .traps: 0.6, .biceps: 0.5, .delts: 0.3], sets: 3, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 30, step: 5, rest: 90, tip: "Brust an das Polster, Ellbogen nah am Körper nach hinten ziehen, kurz halten."),
            GymExercise(id: "legext", name: "Beinstrecker", machine: "Insignia · Leg Extension",
                        icon: "M5 5V16H11M11 16L16 11M16 11L19 12M5 20H14",
                        muscles: [.quads: 1], sets: 2, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 20, step: 5, rest: 60, tip: "Knie auf Höhe der Drehachse. Oben kurz halten, langsam ablassen."),
            GymExercise(id: "backext", name: "Rückenstrecker", machine: "Insignia · Back Extension",
                        icon: "M4 19L11 15L17 7M7 21H18M17 4H18",
                        muscles: [.lowerback: 1, .glutes: 0.5, .hamstrings: 0.3], sets: 2, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 20, step: 5, rest: 60, tip: "Ruhig und kontrolliert, nicht ins Hohlkreuz schwingen."),
            GymExercise(id: "plank", name: "Plank", machine: "Matte · Functional Area",
                        icon: "M3 16H15L20 13M5 16V19M15 16V19M20 10H21",
                        muscles: [.abs: 1, .obliques: 0.6, .delts: 0.2], sets: 3, repsLow: 20, repsHigh: 30, seconds: true,
                        startWeight: 0, step: 0, rest: 45, tip: "Unterarme unter den Schultern, Körper gerade wie ein Brett, Bauch fest."),
        ]
        case .b: [
            GymExercise(id: "legcurl", name: "Beinbeuger", machine: "Insignia · Seated Leg Curl",
                        icon: "M5 6V16H11M11 16L15 20M15 20H19M5 20H11",
                        muscles: [.hamstrings: 1, .calves: 0.2], sets: 3, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 25, step: 5, rest: 90, tip: "Knie auf Höhe der Drehachse, Polster über den Knöcheln, langsam zurück."),
            GymExercise(id: "pulldown", name: "Latzug", machine: "Insignia · Pulldown",
                        icon: "M4 4H20M8 4L10 10M16 4L14 10M10 10H14M12 10V20M9 20H15",
                        muscles: [.lats: 1, .biceps: 0.6, .traps: 0.4], sets: 3, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 30, step: 5, rest: 90, tip: "Zur oberen Brust ziehen, Brust raus, nicht nach hinten lehnen."),
            GymExercise(id: "shoulderpress", name: "Schulterpresse", machine: "Insignia · Shoulder Press",
                        icon: "M6 20V8M18 20V8M6 8H18M9 8V4M15 8V4M12 12V20",
                        muscles: [.delts: 1, .triceps: 0.5, .traps: 0.3], sets: 3, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 15, step: 5, rest: 90, tip: "Griffe auf Schulterhöhe, nach oben drücken ohne die Arme ganz zu strecken."),
            GymExercise(id: "hip", name: "Po-Maschine", machine: "Insignia · Hip Abduction / Glute",
                        icon: "M6 18L10 8H14L18 18M12 8V4M9 21H15",
                        muscles: [.glutes: 1, .hamstrings: 0.2], sets: 2, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 30, step: 5, rest: 60, tip: "Gerade sitzen, Beine kontrolliert nach außen drücken, langsam zurück."),
            GymExercise(id: "abdominal", name: "Bauchmaschine", machine: "Insignia · Abdominal",
                        icon: "M8 4H16V20H8ZM8 9H16M8 14H16",
                        muscles: [.abs: 1, .obliques: 0.4], sets: 2, repsLow: 12, repsHigh: 15, seconds: false,
                        startWeight: 20, step: 5, rest: 60, tip: "Oberkörper einrollen, aus dem Bauch arbeiten – nicht mit den Armen ziehen."),
            GymExercise(id: "sideplank", name: "Seitstütz", machine: "Matte · je Seite",
                        icon: "M3 18L19 8M5 18V21M19 8H21",
                        muscles: [.obliques: 1, .abs: 0.5, .delts: 0.3], sets: 2, repsLow: 15, repsHigh: 20, seconds: true,
                        startWeight: 0, step: 0, rest: 45, tip: "Ellbogen unter der Schulter, Hüfte oben halten. Danach Seite wechseln."),
        ]
        }
    }
}

// MARK: Verlauf

struct GymSetLog: Codable, Hashable {
    var weight: Double
    var reps: Int
}

struct GymLog: Codable, Identifiable, Hashable {
    var id = UUID()
    var program: GymProgram
    var start: Date
    var end: Date
    var sets: [String: [GymSetLog]]          // Übung → Sätze

    var volume: Double { sets.values.flatMap { $0 }.map { $0.weight * Double($0.reps) }.reduce(0, +) }

    /// Muskelprofil dieses Trainings (0…1)
    var muscles: [Muscle: Double] {
        var sum: [Muscle: Double] = [:]
        for ex in program.exercises {
            let n = Double(sets[ex.id]?.count ?? 0)
            for (m, f) in ex.muscles { sum[m, default: 0] += f * n }
        }
        let mx = sum.values.max() ?? 0
        return mx > 0 ? sum.mapValues { $0 / mx } : [:]
    }
}

/// Laufende Einheit (wird bei jeder Änderung gesichert, damit nichts verloren geht)
struct GymRun: Codable {
    var program: GymProgram
    var start: Date
    var order: [String]
    var sets: [String: [GymSetLog]] = [:]
    var weights: [String: Double] = [:]
    var reps: [String: Int] = [:]
    var restUntil: Date?
}

@MainActor @Observable
final class GymModel {
    static let shared = GymModel()

    var history: [GymLog] = []
    var run: GymRun? { didSet { saveRun() } }

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "gym_verlauf.json")
    }

    init() {
        if let d = try? Data(contentsOf: file), let h = try? JSONDecoder().decode([GymLog].self, from: d) { history = h }
        if let s = UserDefaults.standard.data(forKey: "gymRun"), let r = try? JSONDecoder().decode(GymRun.self, from: s) {
            // nur weiterführen, wenn die Einheit nicht älter als 4 Stunden ist
            if -r.start.timeIntervalSinceNow < 4 * 3600 { run = r }
        }
    }

    private func saveRun() {
        if let run, let d = try? JSONEncoder().encode(run) { UserDefaults.standard.set(d, forKey: "gymRun") }
        else { UserDefaults.standard.removeObject(forKey: "gymRun") }
    }

    private func saveHistory() {
        if let d = try? JSONEncoder().encode(history) { try? d.write(to: file, options: .atomic) }
    }

    func exercise(_ id: String) -> GymExercise? {
        GymProgram.allCases.flatMap(\.exercises).first { $0.id == id }
    }

    /// Letzte Sätze einer Übung
    func last(_ ex: GymExercise) -> [GymSetLog]? {
        history.sorted { $0.start > $1.start }.lazy.compactMap { $0.sets[ex.id] }.first { !$0.isEmpty }
    }

    /// Vorschlag fürs Gewicht: letztes Gewicht, +1 Stufe wenn alle Sätze die obere Zahl geschafft haben
    func suggestedWeight(_ ex: GymExercise) -> Double {
        guard !ex.seconds else { return 0 }
        guard let l = last(ex), let w = l.map(\.weight).max() else { return ex.startWeight }
        let allTop = l.count >= ex.sets && l.allSatisfy { $0.reps >= ex.repsHigh }
        return allTop ? w + ex.step : w
    }

    func suggestedReps(_ ex: GymExercise) -> Int {
        guard ex.seconds else { return ex.repsLow }
        guard let l = last(ex), let r = l.map(\.reps).max() else { return ex.repsLow }
        return min(ex.repsHigh + 30, r + (l.allSatisfy { $0.reps >= r } ? 5 : 0))
    }

    // MARK: Ablauf

    func start(_ p: GymProgram) {
        var r = GymRun(program: p, start: .now, order: p.exercises.map(\.id))
        for ex in p.exercises {
            r.weights[ex.id] = suggestedWeight(ex)
            r.reps[ex.id] = suggestedReps(ex)
        }
        run = r
    }

    func logSet(_ ex: GymExercise) {
        guard var r = run else { return }
        let entry = GymSetLog(weight: r.weights[ex.id] ?? 0, reps: r.reps[ex.id] ?? ex.repsLow)
        r.sets[ex.id, default: []].append(entry)
        let done = (r.sets[ex.id]?.count ?? 0) >= ex.sets
        r.restUntil = done ? nil : Date.now.addingTimeInterval(Double(ex.rest))
        run = r
        if !done { Self.scheduleRestEnd(ex, after: ex.rest) }
    }

    func undoSet(_ ex: GymExercise) {
        guard var r = run, !(r.sets[ex.id] ?? []).isEmpty else { return }
        r.sets[ex.id]?.removeLast()
        r.restUntil = nil
        run = r
    }

    func skipRest() {
        run?.restUntil = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gym-pause"])
    }

    func setWeight(_ ex: GymExercise, _ w: Double) { run?.weights[ex.id] = max(0, w) }
    func setReps(_ ex: GymExercise, _ n: Int) { run?.reps[ex.id] = max(1, n) }

    /// Gerät besetzt → ans Ende der Liste
    func postpone(_ ex: GymExercise) {
        guard var r = run, let i = r.order.firstIndex(of: ex.id) else { return }
        r.order.remove(at: i)
        r.order.append(ex.id)
        run = r
    }

    func isDone(_ ex: GymExercise) -> Bool { (run?.sets[ex.id]?.count ?? 0) >= ex.sets }
    var exercisesInOrder: [GymExercise] { (run?.order ?? []).compactMap { exercise($0) } }
    var current: GymExercise? { exercisesInOrder.first { !isDone($0) } }
    var doneCount: Int { exercisesInOrder.filter { isDone($0) }.count }

    /// Beenden → in den Verlauf, optional als Krafttraining in Apple Health
    @discardableResult
    func finish(saveToHealth: Bool) async -> GymLog? {
        guard let r = run else { return nil }
        let log = GymLog(program: r.program, start: r.start, end: .now, sets: r.sets.filter { !$0.value.isEmpty })
        run = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gym-pause"])
        guard !log.sets.isEmpty else { return nil }
        history.append(log)
        saveHistory()
        if saveToHealth { await Self.saveWorkout(log) }
        return log
    }

    func cancel() {
        run = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gym-pause"])
    }

    /// Log zu einem Krafttraining aus Apple Health (gleicher Zeitraum ± 30 Min)
    func log(for w: FitWorkout) -> GymLog? {
        history.first { abs($0.start.timeIntervalSince(w.start)) < 1800 || ($0.start < w.end && $0.end > w.start) }
    }

    // MARK: Hilfen

    private static func scheduleRestEnd(_ ex: GymExercise, after seconds: Int) {
        let c = UNMutableNotificationContent()
        c.title = "Pause vorbei"
        c.body = "Weiter mit \(ex.name)."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: "gym-pause", content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    /// Als Krafttraining in Apple Health speichern – nur, wenn die Watch nicht schon eins aufgezeichnet hat
    private static func saveWorkout(_ log: GymLog) async {
        let fit = FitnessModel.shared
        let store = fit.health
        let overlap = fit.workouts.contains { $0.sport == .gym && $0.start < log.end && $0.end > log.start }
        guard !overlap else { return }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)], read: [])
            let cfg = HKWorkoutConfiguration()
            cfg.activityType = .traditionalStrengthTraining
            cfg.locationType = .indoor
            let b = HKWorkoutBuilder(healthStore: store, configuration: cfg, device: .local())
            try await b.beginCollection(at: log.start)
            // grobe Schätzung: 5 MET × Körpergewicht × Stunden
            let kg = fit.currentWeight?.value ?? 100
            let kcal = 5 * kg * log.end.timeIntervalSince(log.start) / 3600
            let sample = HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                          quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: log.start, end: log.end)
            try await b.addSamples([sample])
            try await b.addMetadata([HKMetadataKeyWorkoutBrandName: "Familie · \(log.program.short)"])
            try await b.endCollection(at: log.end)
            _ = try await b.finishWorkout()
            await fit.refresh(maxAge: 0)
        } catch {
            fit.error = "Training nicht in Apple Health gespeichert: \(error.localizedDescription)"
        }
    }
}
