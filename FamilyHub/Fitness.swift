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
    case gym, padel, basketball, rad, schwimmen, laufen, gehen, andere
    var id: String { rawValue }

    static func of(_ t: HKWorkoutActivityType) -> Sport {
        switch t {
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining,
             .highIntensityIntervalTraining, .crossTraining, .flexibility: return .gym
        // Padel zeichnet Jan als „Sonstiges“ auf (die Watch kennt kein Padel)
        case .other, .tennis, .racquetball, .squash, .badminton, .pickleball, .tableTennis: return .padel
        case .basketball: return .basketball
        case .cycling, .handCycling: return .rad
        case .swimming, .waterFitness: return .schwimmen
        case .running: return .laufen
        case .walking, .hiking: return .gehen
        default: return .andere
        }
    }

    var title: String {
        switch self {
        case .gym: "Gym"
        case .padel: "Padel"
        case .basketball: "Basketball"
        case .rad: "Rad"
        case .schwimmen: "Schwimmen"
        case .laufen: "Laufen"
        case .gehen: "Gehen"
        case .andere: "Sonstiges"
        }
    }
    var symbol: String {
        switch self {
        case .gym: "dumbbell.fill"
        case .padel: "figure.tennis"
        case .basketball: "figure.basketball"
        case .rad: "figure.outdoor.cycle"
        case .schwimmen: "figure.pool.swim"
        case .laufen: "figure.run"
        case .gehen: "figure.walk"
        case .andere: "figure.mixed.cardio"
        }
    }
    var color: Color {
        switch self {
        case .gym: Color(red: 1.0, green: 0.48, blue: 0.10)
        case .padel: Color(red: 0.12, green: 0.62, blue: 0.33)
        case .basketball: Color(red: 0.58, green: 0.36, blue: 0.95)
        case .rad: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .schwimmen: Color(red: 0.08, green: 0.72, blue: 0.78)
        case .laufen: Color(red: 0.90, green: 0.29, blue: 0.50)
        case .gehen: Color(red: 0.72, green: 0.52, blue: 0.22)
        case .andere: Color(.systemGray)
        }
    }

    /// Welche Muskeln die Sportart typischerweise beansprucht (0…1)
    var muscles: [Muscle: Double] {
        switch self {
        case .gym: [.quads: 0.7, .glutes: 0.6, .hamstrings: 0.5, .chest: 0.7, .lats: 0.7, .traps: 0.4,
                    .delts: 0.5, .biceps: 0.4, .triceps: 0.4, .lowerback: 0.5, .abs: 0.5, .obliques: 0.4]
        case .padel: [.quads: 0.6, .calves: 0.6, .glutes: 0.4, .delts: 0.6, .forearms: 0.5, .obliques: 0.5, .abs: 0.3]
        case .basketball: [.quads: 0.8, .calves: 0.8, .glutes: 0.5, .hamstrings: 0.4, .delts: 0.4, .forearms: 0.3, .abs: 0.4, .obliques: 0.3]
        case .rad: [.quads: 1, .glutes: 0.6, .hamstrings: 0.5, .calves: 0.6]
        case .schwimmen: [.lats: 0.8, .delts: 0.7, .chest: 0.5, .triceps: 0.5, .traps: 0.4, .abs: 0.4, .quads: 0.3]
        case .laufen: [.quads: 0.7, .calves: 0.8, .hamstrings: 0.6, .glutes: 0.5]
        case .gehen: [.calves: 0.5, .quads: 0.4, .glutes: 0.3, .hamstrings: 0.3]
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

struct NutritionDay: Identifiable, Hashable {
    let date: Date
    let kcal: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let water: Double?
    let active: Double?
    let basal: Double?
    var id: Date { date }
    var burned: Double? { (active == nil && basal == nil) ? nil : (active ?? 0) + (basal ?? 0) }
    var logged: Bool { (kcal ?? 0) > 100 }
}

struct FoodMeal: Identifiable, Hashable {
    var start: Date
    var end: Date
    var kcal: Double
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var id: Date { start }
    var name: String {
        let h = Calendar.current.component(.hour, from: start)
        switch h {
        case ..<11: return "Frühstück"
        case 11..<15: return "Mittagessen"
        case 15..<17: return "Snack"
        default: return "Abendessen"
        }
    }
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
    var hrv: [FitPoint] = []
    var lean: [FitPoint] = []
    var bmi: [FitPoint] = []
    var nutrition: [NutritionDay] = []      // letzte 35 Tage, ältester zuerst
    var lastMealAt: Date?                   // letzter Eintrag mit Kalorien (Yazio)
    var mealsToday: [FoodMeal] = []

    private var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [
            HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage), HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming),
            HKQuantityType(.activeEnergyBurned), HKQuantityType(.appleExerciseTime), HKQuantityType(.restingHeartRate),
            HKQuantityType(.vo2Max), HKQuantityType(.heartRate), HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(), HKObjectType.activitySummaryType(), HKSeriesType.workoutRoute(),
            // Ernährung (Yazio) und Waage (Renpho)
            HKQuantityType(.dietaryEnergyConsumed), HKQuantityType(.dietaryProtein), HKQuantityType(.dietaryCarbohydrates),
            HKQuantityType(.dietaryFatTotal), HKQuantityType(.dietaryFiber), HKQuantityType(.dietarySugar),
            HKQuantityType(.dietaryWater), HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.leanBodyMass), HKQuantityType(.bodyMassIndex),
            HKQuantityType(.heartRateVariabilitySDNN)
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
            async let hv = quantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: cal.date(byAdding: .day, value: -60, to: now)!)
            async let ln = quantity(.leanBodyMass, unit: .gramUnit(with: .kilo), from: twoYears)
            async let bm = quantity(.bodyMassIndex, unit: .count(), from: twoYears)
            async let nu = loadNutrition(days: 35)
            async let me = loadMealsToday()
            weights = try await w
            bodyFat = try await f.map { FitPoint(date: $0.date, value: $0.value * 100) }
            restingHR = try await r
            vo2 = try await v
            let hidden = hiddenWorkouts
            workouts = try await wo.filter { !hidden.contains($0.id.uuidString) }
            sleep = (try? await sl) ?? []
            stepsToday = await st
            kmToday = await km
            activity = await act
            hrv = (try? await hv) ?? []
            lean = (try? await ln) ?? []
            bmi = (try? await bm) ?? []
            nutrition = await nu
            mealsToday = await me
            lastMealAt = await latestSample(.dietaryEnergyConsumed)
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
                case .laufen, .gehen: HKQuantityType(.distanceWalkingRunning)
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
        case .other: "Padel"
        case .basketball: "Basketball"
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
        // Ohne Uhr in der Nacht: „Im Bett“ aus der Schlafenszeit des iPhones als Ersatz
        var inBed: [Date: Double] = [:]
        for s in all where s.value == HKCategoryValueSleepAnalysis.inBed.rawValue {
            let day = Calendar.current.startOfDay(for: s.endDate)
            inBed[day, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
        }
        for (day, h) in inBed where perNight[day] == nil && h > 2 { perNight[day] = min(h, 12) }
        return perNight.map { FitPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    // MARK: Ernährung

    private func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int) async -> [Date: Double] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: .now))!
        let q = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: nil)),
            options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
        guard let coll = try? await q.result(for: health) else { return [:] }
        var out: [Date: Double] = [:]
        for s in coll.statistics() {
            if let v = s.sumQuantity()?.doubleValue(for: unit) { out[cal.startOfDay(for: s.startDate)] = v }
        }
        return out
    }

    private func loadNutrition(days: Int) async -> [NutritionDay] {
        async let kcal = daily(.dietaryEnergyConsumed, unit: .kilocalorie(), days: days)
        async let pro = daily(.dietaryProtein, unit: .gram(), days: days)
        async let carb = daily(.dietaryCarbohydrates, unit: .gram(), days: days)
        async let fat = daily(.dietaryFatTotal, unit: .gram(), days: days)
        async let fib = daily(.dietaryFiber, unit: .gram(), days: days)
        async let sug = daily(.dietarySugar, unit: .gram(), days: days)
        async let wat = daily(.dietaryWater, unit: .liter(), days: days)
        async let act = daily(.activeEnergyBurned, unit: .kilocalorie(), days: days)
        async let bas = daily(.basalEnergyBurned, unit: .kilocalorie(), days: days)
        let (k, p, c, f, fi, s, w, a, b) = await (kcal, pro, carb, fat, fib, sug, wat, act, bas)
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: .now))!
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start)!
            return NutritionDay(date: d, kcal: k[d], protein: p[d], carbs: c[d], fat: f[d], fiber: fi[d], sugar: s[d],
                                water: w[d], active: a[d], basal: b[d])
        }
    }

    private func loadMealsToday() async -> [FoodMeal] { await meals(on: .now) }

    /// Zeitpunkt des neuesten Eintrags (z. B. letzte Mahlzeit)
    private func latestSample(_ id: HKQuantityTypeIdentifier) async -> Date? {
        let from = Calendar.current.date(byAdding: .day, value: -4, to: .now)!
        let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        return try? await q.result(for: health).first?.endDate
    }

    /// Mahlzeiten eines Tages: Einträge, die zeitlich nah beieinander liegen (45 Min), sind eine Mahlzeit
    func meals(on day: Date) async -> [FoodMeal] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        func samples(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> [(Date, Double)] {
            let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
            return ((try? await q.result(for: health)) ?? []).map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
        }
        let kcal = await samples(.dietaryEnergyConsumed, .kilocalorie())
        let pro = await samples(.dietaryProtein, .gram())
        let carb = await samples(.dietaryCarbohydrates, .gram())
        let fat = await samples(.dietaryFatTotal, .gram())
        var meals: [FoodMeal] = []
        for (t, v) in kcal {
            if let last = meals.last, t.timeIntervalSince(last.end) < 45 * 60 {
                meals[meals.count - 1].kcal += v
                meals[meals.count - 1].end = t
            } else {
                meals.append(FoodMeal(start: t, end: t, kcal: v))
            }
        }
        func add(_ list: [(Date, Double)], _ kp: WritableKeyPath<FoodMeal, Double>) {
            for (t, v) in list {
                guard let i = meals.indices.min(by: { abs(meals[$0].start.timeIntervalSince(t)) < abs(meals[$1].start.timeIntervalSince(t)) }) else { continue }
                meals[i][keyPath: kp] += v
            }
        }
        add(pro, \.protein)
        add(carb, \.carbs)
        add(fat, \.fat)
        return meals
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

    // MARK: Trainings löschen / ausblenden

    /// in der App ausgeblendete Trainings (fremde Apps – die darf die App in Apple Health nicht löschen)
    var hiddenWorkouts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "fitAusgeblendet") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "fitAusgeblendet") }
    }

    /// Hat die Familie-App (iPhone oder Uhr) dieses Training gespeichert? Nur dann darf sie es löschen.
    func isOwn(_ w: FitWorkout) -> Bool {
        w.workout.sourceRevision.source.bundleIdentifier.hasPrefix("es.mohs.familie")
    }

    func hide(_ w: FitWorkout) {
        hiddenWorkouts.insert(w.id.uuidString)
        workouts.removeAll { $0.id == w.id }
    }

    func unhideAll() async {
        hiddenWorkouts = []
        await refresh(maxAge: 0)
    }

    /// Löschen: eigenes Training aus Apple Health + Gym-Verlauf; fremdes nur ausblenden
    @discardableResult
    func delete(_ w: FitWorkout) async -> Bool {
        if let log = GymModel.shared.log(for: w) { GymModel.shared.deleteLog(log) }
        guard isOwn(w) else { hide(w); return false }
        do {
            try await health.requestAuthorization(toShare: [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)], read: [])
            try await health.delete(w.workout)
            workouts.removeAll { $0.id == w.id }
            return true
        } catch {
            hide(w)
            self.error = "In Apple Health nicht gelöscht – in der App ausgeblendet."
            return false
        }
    }

    // MARK: Erholung (auch ohne Uhr in der Nacht)

    enum Feeling: String { case fit, okay, muede }

    private static var feelingKey: String { "gefuehl-" + HADate.day.string(from: .now) }

    /// eigene Einschätzung für heute (per Tipp)
    var feeling: Feeling? {
        get { _ = feelingStamp; return UserDefaults.standard.string(forKey: Self.feelingKey).flatMap(Feeling.init) }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: Self.feelingKey)
            feelingStamp += 1
        }
    }
    private var feelingStamp = 0

    struct Recovery {
        let label: String           // gut / okay / müde
        let color: Color
        let reasons: [String]
        var good: Bool { label == "gut" }
    }

    /// Ruhepuls und HRV gegen den eigenen 30-Tage-Schnitt, Trainingslast gestern, Schlaf (wenn vorhanden), eigenes Gefühl
    var recovery: Recovery? {
        var score = 0.0
        var reasons: [String] = []
        var signals = 0
        let avg = { (l: [FitPoint]) -> Double? in let v = l.suffix(30).map(\.value); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        if let r = restingHR.last?.value, let a = avg(restingHR) {
            signals += 1
            if r > a + 5 { score -= 2; reasons.append("Ruhepuls \(Int(r)) – deutlich höher als sonst") }
            else if r > a + 2 { score -= 1; reasons.append("Ruhepuls \(Int(r)) – etwas erhöht") }
            else { score += r < a - 1 ? 1 : 0.5; reasons.append("Ruhepuls \(Int(r))") }
        }
        let todayHRV = hrv.filter { Calendar.current.isDateInToday($0.date) || $0.date > .now.addingTimeInterval(-36 * 3600) }.map(\.value)
        if !todayHRV.isEmpty, let a = avg(hrv) {
            signals += 1
            let v = todayHRV.reduce(0, +) / Double(todayHRV.count)
            if v < a * 0.8 { score -= 2; reasons.append("HRV niedrig (\(Int(v)) ms)") }
            else if v < a * 0.9 { score -= 1; reasons.append("HRV etwas niedrig") }
            else { score += v > a * 1.1 ? 1 : 0.5; reasons.append("HRV gut (\(Int(v)) ms)") }
        }
        if let s = sleep.last, Calendar.current.isDateInToday(s.date) {
            signals += 1
            if s.value < 6 { score -= 1.5; reasons.append("nur \(FitFmt.hm(s.value)) Schlaf") }
            else if s.value >= 7 { score += 1; reasons.append("\(FitFmt.hm(s.value)) Schlaf") }
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!
        let load = workouts.filter { Calendar.current.isDate($0.start, inSameDayAs: yesterday) }.map(\.duration).reduce(0, +) / 60
        if load > 90 { score -= 1; reasons.append("gestern \(Int(load)) Min Training") }
        if let f = feeling {
            signals += 1
            switch f {
            case .fit: score += 2; reasons.insert("du fühlst dich fit", at: 0)
            case .okay: reasons.insert("du fühlst dich okay", at: 0)
            case .muede: score -= 2.5; reasons.insert("du fühlst dich müde", at: 0)
            }
        }
        guard signals > 0 else { return nil }
        if score >= 1 { return Recovery(label: "gut", color: .green, reasons: reasons) }
        if score <= -2 { return Recovery(label: "müde", color: .orange, reasons: reasons) }
        return Recovery(label: "okay", color: .blue, reasons: reasons)
    }

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
            // Gym: wenn in der App abgehakt, die echten Geräte nehmen
            let profile = (w.sport == .gym ? GymModel.shared.log(for: w)?.muscles : nil) ?? w.sport.muscles
            for (m, f) in profile { sum[m, default: 0] += f * minutes }
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
