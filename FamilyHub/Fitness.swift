import SwiftUI
import HealthKit
import CoreLocation

// MARK: - Fitness (nur Jan): Daten aus Apple Health
//
// Alles wird direkt auf dem iPhone aus Apple Health gelesen – nichts geht an Home Assistant.
// Ziel (Start-/Zielgewicht) liegt in den App-Einstellungen (@AppStorage).

enum FitnessConfig {
    static let defaultStartKg = 127.0
    static let defaultGoalKg = 108.0
}

struct FitPoint: Identifiable, Hashable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Sportarten, wie die App sie zusammenfasst
enum Sport: String, CaseIterable, Identifiable {
    case gym, padel, rad, schwimmen, laufen, andere
    var id: String { rawValue }

    static func of(_ t: HKWorkoutActivityType) -> Sport {
        switch t {
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining,
             .highIntensityIntervalTraining, .crossTraining, .flexibility: return .gym
        case .tennis, .racquetball, .squash, .badminton, .pickleball, .tableTennis: return .padel
        case .cycling, .handCycling: return .rad
        case .swimming, .waterFitness: return .schwimmen
        case .running, .walking, .hiking: return .laufen
        default: return .andere
        }
    }

    var title: String {
        switch self {
        case .gym: "Gym"
        case .padel: "Padel"
        case .rad: "Rad"
        case .schwimmen: "Schwimmen"
        case .laufen: "Laufen"
        case .andere: "Sonstiges"
        }
    }
    var symbol: String {
        switch self {
        case .gym: "dumbbell.fill"
        case .padel: "figure.tennis"
        case .rad: "figure.outdoor.cycle"
        case .schwimmen: "figure.pool.swim"
        case .laufen: "figure.run"
        case .andere: "figure.mixed.cardio"
        }
    }
    var color: Color {
        switch self {
        case .gym: Color(red: 1.0, green: 0.48, blue: 0.10)
        case .padel: Color(red: 0.12, green: 0.62, blue: 0.33)
        case .rad: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .schwimmen: Color(red: 0.08, green: 0.72, blue: 0.78)
        case .laufen: Color(red: 0.90, green: 0.29, blue: 0.50)
        case .andere: Color(.systemGray)
        }
    }

    /// Welche Muskeln die Sportart typischerweise beansprucht (0…1)
    var muscles: [Muscle: Double] {
        switch self {
        case .gym: [.quads: 0.7, .glutes: 0.6, .hamstrings: 0.5, .chest: 0.7, .lats: 0.7, .traps: 0.4,
                    .delts: 0.5, .biceps: 0.4, .triceps: 0.4, .lowerback: 0.5, .abs: 0.5, .obliques: 0.4]
        case .padel: [.quads: 0.6, .calves: 0.6, .glutes: 0.4, .delts: 0.6, .forearms: 0.5, .obliques: 0.5, .abs: 0.3]
        case .rad: [.quads: 1, .glutes: 0.6, .hamstrings: 0.5, .calves: 0.6]
        case .schwimmen: [.lats: 0.8, .delts: 0.7, .chest: 0.5, .triceps: 0.5, .traps: 0.4, .abs: 0.4, .quads: 0.3]
        case .laufen: [.quads: 0.7, .calves: 0.8, .hamstrings: 0.6, .glutes: 0.5]
        case .andere: [.quads: 0.3, .abs: 0.2]
        }
    }
}

/// Ein Training aus Apple Health, schon ausgewertet
struct FitWorkout: Identifiable, Hashable {
    let id: UUID
    let sport: Sport
    let name: String
    let start: Date
    let end: Date
    let kcal: Double?
    let km: Double?
    let avgHR: Double?
    let maxHR: Double?
    let source: String
    let workout: HKWorkout

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

@MainActor @Observable
final class FitnessModel {
    static let shared = FitnessModel()
    let health = HKHealthStore()

    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    var askedOnce = false
    var loading = false
    var loaded: Date?
    var error: String?

    var weights: [FitPoint] = []
    var bodyFat: [FitPoint] = []
    var restingHR: [FitPoint] = []
    var vo2: [FitPoint] = []
    var sleep: [FitPoint] = []          // Stunden pro Nacht (Datum = Aufwachtag)
    var workouts: [FitWorkout] = []     // neueste zuerst, letzte 365 Tage
    var stepsToday: Double?
    var kmToday: Double?
    var activity: HKActivitySummary?
    var age: Int?

    private var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [
            HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage), HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming),
            HKQuantityType(.activeEnergyBurned), HKQuantityType(.appleExerciseTime), HKQuantityType(.restingHeartRate),
            HKQuantityType(.vo2Max), HKQuantityType(.heartRate), HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(), HKObjectType.activitySummaryType(), HKSeriesType.workoutRoute()
        ]
        s.insert(HKCharacteristicType(.dateOfBirth))
        return s
    }

    /// Wurde schon einmal nach Erlaubnis gefragt? Dann still laden (z. B. für die Karte auf „Zuhause“).
    func refreshIfAllowed() async {
        guard available else { return }
        let status = try? await health.statusForAuthorizationRequest(toShare: [], read: readTypes)
        if status == .unnecessary { await refresh(maxAge: 120) }
    }

    func requestAndLoad() async {
        guard available else { error = "Apple Health ist auf diesem Gerät nicht verfügbar."; return }
        do {
            try await health.requestAuthorization(toShare: [], read: readTypes)
            askedOnce = true
            await refresh(maxAge: 0)
        } catch {
            self.error = "Apple Health ist für die App noch nicht freigeschaltet (\(error.localizedDescription))."
        }
    }

    func refresh(maxAge: TimeInterval) async {
        if let l = loaded, -l.timeIntervalSinceNow < maxAge { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let now = Date.now
        let cal = Calendar.current
        let yearAgo = cal.date(byAdding: .day, value: -365, to: now)!
        let twoYears = cal.date(byAdding: .year, value: -2, to: now)!
        do {
            async let w = quantity(.bodyMass, unit: .gramUnit(with: .kilo), from: twoYears)
            async let f = quantity(.bodyFatPercentage, unit: .percent(), from: yearAgo)
            async let r = quantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: yearAgo)
            async let v = quantity(.vo2Max, unit: HKUnit(from: "ml/kg*min"), from: yearAgo)
            async let wo = loadWorkouts(from: yearAgo)
            async let sl = loadSleep(days: 60)
            async let st = todaySum(.stepCount, unit: .count())
            async let km = todaySum(.distanceWalkingRunning, unit: .meterUnit(with: .kilo))
            async let act = activitySummaryToday()
            weights = try await w
            bodyFat = try await f.map { FitPoint(date: $0.date, value: $0.value * 100) }
            restingHR = try await r
            vo2 = try await v
            workouts = try await wo
            sleep = (try? await sl) ?? []
            stepsToday = await st
            kmToday = await km
            activity = await act
            if let comps = try? health.dateOfBirthComponents(), let dob = cal.date(from: comps) {
                age = cal.dateComponents([.year], from: dob, to: now).year
            }
            loaded = .now
            error = nil
        } catch {
            self.error = "Daten aus Apple Health konnten nicht gelesen werden."
        }
    }

    // MARK: Abfragen

    private func quantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date) async throws -> [FitPoint] {
        let type = HKQuantityType(id)
        let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        return try await q.result(for: health).map { FitPoint(date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    private func todaySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: .now)
        let q = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: nil)),
                                            options: .cumulativeSum)
        return try? await q.result(for: health)?.sumQuantity()?.doubleValue(for: unit)
    }

    private func activitySummaryToday() async -> HKActivitySummary? {
        var comps = Calendar.current.dateComponents([.era, .year, .month, .day], from: .now)
        comps.calendar = Calendar.current
        let pred = HKQuery.predicate(forActivitySummariesBetweenStart: comps, end: comps)
        return await withCheckedContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: pred) { _, list, _ in cont.resume(returning: list?.first) }
            health.execute(q)
        }
    }

    private func loadWorkouts(from: Date) async throws -> [FitWorkout] {
        let q = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(withStart: from, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return try await q.result(for: health).map { w in
            let sport = Sport.of(w.workoutActivityType)
            let distType: HKQuantityType? = switch sport {
                case .rad: HKQuantityType(.distanceCycling)
                case .schwimmen: HKQuantityType(.distanceSwimming)
                case .laufen: HKQuantityType(.distanceWalkingRunning)
                default: nil
            }
            let km = distType.flatMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) }
            let hr = w.statistics(for: HKQuantityType(.heartRate))
            return FitWorkout(id: w.uuid, sport: sport, name: Self.name(w.workoutActivityType, sport),
                              start: w.startDate, end: w.endDate,
                              kcal: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                              km: (km ?? 0) > 0.05 ? km : nil,
                              avgHR: hr?.averageQuantity()?.doubleValue(for: bpm),
                              maxHR: hr?.maximumQuantity()?.doubleValue(for: bpm),
                              source: w.sourceRevision.source.name, workout: w)
        }
    }

    private static func name(_ t: HKWorkoutActivityType, _ s: Sport) -> String {
        switch t {
        case .traditionalStrengthTraining: "Krafttraining"
        case .functionalStrengthTraining: "Funktionelles Training"
        case .coreTraining: "Rumpftraining"
        case .highIntensityIntervalTraining: "HIIT"
        case .tennis: "Tennis/Padel"
        case .walking: "Gehen"
        case .hiking: "Wandern"
        case .running: "Laufen"
        case .cycling: "Radfahren"
        case .swimming: "Schwimmen"
        default: s == .padel ? "Padel" : s.title
        }
    }

    private func loadSleep(days: Int) async throws -> [FitPoint] {
        let from = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let q = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        let all = try await q.result(for: health)
        let asleep = all.filter { HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue).contains($0.value) }
        // Uhr bevorzugen, damit iPhone und Watch nicht doppelt zählen
        let watch = asleep.filter { $0.sourceRevision.productType?.hasPrefix("Watch") == true }
        let use = watch.isEmpty ? asleep : watch
        var perNight: [Date: Double] = [:]
        for s in use {
            let day = Calendar.current.startOfDay(for: s.endDate)
            perNight[day, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
        }
        return perNight.map { FitPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    // MARK: Einzelnes Training: Puls und Strecke

    func heartRates(for w: FitWorkout) async -> [FitPoint] {
        let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.heartRate),
                                                                     predicate: HKQuery.predicateForSamples(withStart: w.start, end: w.end))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return (try? await q.result(for: health).map { FitPoint(date: $0.startDate, value: $0.quantity.doubleValue(for: bpm)) }) ?? []
    }

    func route(for w: FitWorkout) async -> [CLLocationCoordinate2D] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { cont in
            let q = HKAnchoredObjectQuery(type: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: w.workout),
                                          anchor: nil, limit: HKObjectQueryNoLimit) { _, samples, _, _, _ in
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            health.execute(q)
        }
        guard let r = routes.first else { return [] }
        final class Collector: @unchecked Sendable { var points: [CLLocationCoordinate2D] = []; var done = false }
        let box = Collector()
        return await withCheckedContinuation { cont in
            let q = HKWorkoutRouteQuery(route: r) { _, locs, finished, error in
                box.points += (locs ?? []).map(\.coordinate)
                if (finished || error != nil) && !box.done { box.done = true; cont.resume(returning: box.points) }
            }
            health.execute(q)
        }
    }

    // MARK: Auswertungen

    var currentWeight: FitPoint? { weights.last }

    /// kg pro Woche aus den letzten 8 Wochen (negativ = abnehmen)
    var weeklyTrend: Double? {
        let from = Calendar.current.date(byAdding: .day, value: -56, to: .now)!
        let pts = weights.filter { $0.date >= from }
        guard pts.count >= 3, let t0 = pts.first?.date else { return nil }
        let xs = pts.map { $0.date.timeIntervalSince(t0) / (7 * 86400) }, ys = pts.map(\.value)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let den = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        return den > 0 ? num / den : nil
    }

    func workouts(since: Date) -> [FitWorkout] { workouts.filter { $0.start >= since } }

    /// Muskelbelastung aus den Trainings (Minuten × Sportart), auf 0…1 normiert
    func muscleLoad(since: Date) -> [Muscle: Double] {
        var sum: [Muscle: Double] = [:]
        for w in workouts(since: since) {
            let minutes = w.duration / 60
            for (m, f) in w.sport.muscles { sum[m, default: 0] += f * minutes }
        }
        let mx = sum.values.max() ?? 0
        guard mx > 0 else { return [:] }
        return sum.mapValues { $0 / mx }
    }

    static var startOfWeek: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? Calendar.current.startOfDay(for: .now)
    }
}
