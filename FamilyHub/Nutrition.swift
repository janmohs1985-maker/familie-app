import SwiftUI
import Charts

// MARK: - Ernährung (Yazio → Apple Health) und Körperwerte (Renpho → Apple Health)

enum NutritionTargets {
    @MainActor static var deficit: Double { UserDefaults.standard.object(forKey: "nutDeficit") as? Double ?? 550 }
    @MainActor static var proteinPerKg: Double { UserDefaults.standard.object(forKey: "nutProteinKg") as? Double ?? 1.6 }
    @MainActor static var goalKg: Double { UserDefaults.standard.object(forKey: "fitGoalKg") as? Double ?? FitnessConfig.defaultGoalKg }
}

@MainActor
extension FitnessModel {
    var nutritionToday: NutritionDay? { nutrition.last.flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil } }

    /// Ø Verbrauch (Ruhe + Bewegung) der letzten 7 vollständigen Tage
    var avgBurned: Double? {
        let past = nutrition.dropLast().suffix(7).compactMap(\.burned).filter { $0 > 1500 }
        return past.isEmpty ? nil : past.reduce(0, +) / Double(past.count)
    }

    var kcalTarget: Double { max(1400, (avgBurned ?? 2750) - NutritionTargets.deficit) }
    var proteinTarget: Double { (NutritionTargets.proteinPerKg * NutritionTargets.goalKg).rounded() }
}

struct NutritionView: View {
    @State private var fit = FitnessModel.shared
    @State private var tab = 0
    @State private var showTargets = false
    @AppStorage("nutDeficit") private var deficit = 550.0
    @AppStorage("nutProteinKg") private var proteinKg = 1.6
    @AppStorage("nutCarbsMax") private var carbsMax = 200.0
    @AppStorage("nutFatMax") private var fatMax = 70.0
    @AppStorage("nutFiberMin") private var fiberMin = 30.0
    @AppStorage("nutSugarMax") private var sugarMax = 50.0
    @AppStorage("nutWaterMin") private var waterMin = 3.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $tab) {
                    Text("Heute").tag(0)
                    Text("Woche").tag(1)
                }
                .pickerStyle(.segmented)
                if !fit.nutrition.contains(where: \.logged) {
                    Label("Noch keine Ernährungsdaten. In Yazio unter Einstellungen › Apple Health das Teilen der Ernährung einschalten.",
                          systemImage: "fork.knife")
                        .font(.subheadline).foregroundStyle(.orange)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface(radius: 18)
                }
                if tab == 0 { today } else { week }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Ernährung")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTargets = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Ziele")
            }
        }
        .refreshable { await fit.refresh(maxAge: 0) }
        .task { await fit.refresh(maxAge: 120) }
        .sheet(isPresented: $showTargets) { targetsSheet }
    }

    // MARK: Heute

    @ViewBuilder private var today: some View {
        let d = fit.nutritionToday
        let eaten = d?.kcal ?? 0
        let target = fit.kcalTarget
        let left = target - eaten
        let burned = d?.burned
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.green.opacity(0.16), lineWidth: 14)
                    Circle().trim(from: 0, to: min(1, eaten / max(target, 1)))
                        .stroke(left >= 0 ? Color.green : Color.red, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(FitFmt.int(abs(left))).font(.system(size: 28, weight: .heavy)).monospacedDigit()
                        Text(left >= 0 ? "kcal übrig" : "kcal drüber").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 136, height: 136)
                VStack(alignment: .leading, spacing: 8) {
                    labeled("Gegessen", FitFmt.int(eaten) + " kcal", big: true)
                    labeled("Ziel", FitFmt.int(target) + " kcal")
                    labeled("Verbraucht bisher", burned.map { FitFmt.int($0) + " kcal" } ?? "–")
                }
            }
        }
        .padding(16)
        .cardSurface()

        if let b = burned, eaten > 0 {
            let bal = b - eaten
            HStack(spacing: 10) {
                Text((bal >= 0 ? "−" : "+") + FitFmt.int(abs(bal))).font(.system(size: 26, weight: .heavy)).foregroundStyle(bal >= 0 ? .green : .orange)
                Text(bal >= 0 ? "kcal Defizit bisher. Für etwa −0,5 kg pro Woche reichen rund −550 am Tag."
                              : "kcal Überschuss bisher – heute ist noch Bewegung drin.")
                    .font(.footnote)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((bal >= 0 ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }

        VStack(alignment: .leading, spacing: 14) {
            Text("Nährstoffe").font(.headline)
            macroRow("Eiweiß", d?.protein, fit.proteinTarget, "g", Sport.gym.color, isMin: true)
            macroRow("Kohlenhydrate", d?.carbs, carbsMax, "g", .blue, isMin: false)
            macroRow("Fett", d?.fat, fatMax, "g", Color(red: 0.9, green: 0.63, blue: 0), isMin: false)
            macroRow("Ballaststoffe", d?.fiber, fiberMin, "g", .green, isMin: true)
            macroRow("Zucker", d?.sugar, sugarMax, "g", .pink, isMin: false)
            macroRow("Wasser", d?.water, waterMin, "L", .teal, isMin: true, digits: 1)
        }
        .padding(16)
        .cardSurface()

        if !fit.mealsToday.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mahlzeiten").font(.headline).padding([.horizontal, .top], 16).padding(.bottom, 4)
                ForEach(fit.mealsToday) { m in
                    HStack(spacing: 12) {
                        Text(m.start.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.subheadline.weight(.semibold))
                            Text("\(FitFmt.int(m.protein)) g Eiweiß · \(FitFmt.int(m.carbs)) g KH · \(FitFmt.int(m.fat)) g Fett")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(FitFmt.int(m.kcal)).font(.subheadline.weight(.bold)).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
            }
            .padding(.bottom, 8)
            .cardSurface()
        }
        Text("Kalorienziel = Ø Verbrauch der letzten 7 Tage minus \(FitFmt.int(deficit)) kcal. Eiweiß \(FitFmt.num(proteinKg, 1)) g pro kg Zielgewicht.")
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    private func labeled(_ l: String, _ v: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l).font(.caption).foregroundStyle(.secondary)
            Text(v).font(big ? .title3.weight(.heavy) : .subheadline.weight(.bold)).monospacedDigit()
        }
    }

    private func macroRow(_ name: String, _ value: Double?, _ target: Double, _ unit: String, _ color: Color, isMin: Bool, digits: Int = 0) -> some View {
        let v = value ?? 0
        let r = target > 0 ? v / target : 0
        var state = ""
        var stateColor: Color = .secondary
        if isMin {
            state = r >= 1 ? "✓" : "noch " + FitFmt.num(target - v, digits)
            stateColor = r >= 1 ? .green : .orange
        } else if r > 1 {
            state = "zu viel"; stateColor = .red
        } else if r > 0.9 {
            state = "fast voll"; stateColor = .orange
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Text(FitFmt.num(v, digits)).bold()) / \(FitFmt.num(target, digits)) \(unit)").font(.footnote)
                if !state.isEmpty { Text(state).font(.footnote.weight(.bold)).foregroundStyle(stateColor) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(r > 1 && !isMin ? Color.red : color).frame(width: g.size.width * min(1, r))
                }
            }
            .frame(height: 10)
        }
    }

    // MARK: Woche

    private struct BarEntry: Identifiable { let day: Date; let kind: String; let kcal: Double; var id: String { "\(day)\(kind)" } }

    @ViewBuilder private var week: some View {
        let last7 = Array(fit.nutrition.suffix(7))
        let logged = last7.filter(\.logged)
        let complete = logged.filter { !Calendar.current.isDateInToday($0.date) }
        let avgEat = logged.isEmpty ? nil : logged.compactMap(\.kcal).reduce(0, +) / Double(logged.count)
        let defs = complete.compactMap { d in d.burned.map { $0 - (d.kcal ?? 0) } }
        let avgDef = defs.isEmpty ? nil : defs.reduce(0, +) / Double(defs.count)
        let proteinDays = logged.filter { ($0.protein ?? 0) >= fit.proteinTarget }.count
        HStack(spacing: 10) {
            stat("Ø gegessen", avgEat.map { FitFmt.int($0) } ?? "–", "kcal/Tag")
            stat("Ø Defizit", avgDef.map { ($0 >= 0 ? "−" : "+") + FitFmt.int(abs($0)) } ?? "–", "kcal/Tag", color: (avgDef ?? 0) >= 0 ? .green : .orange)
            stat("Eiweiß-Ziel", "\(proteinDays)/\(logged.count)", "Tage")
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Gegessen und verbraucht").font(.headline)
            let bars = last7.flatMap { d -> [BarEntry] in
                [BarEntry(day: d.date, kind: "gegessen", kcal: d.kcal ?? 0), BarEntry(day: d.date, kind: "verbraucht", kcal: d.burned ?? 0)]
            }
            Chart(bars) { b in
                BarMark(x: .value("Tag", b.day, unit: .day), y: .value("kcal", b.kcal))
                    .foregroundStyle(by: .value("Art", b.kind))
                    .position(by: .value("Art", b.kind))
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale(["gegessen": Color.green, "verbraucht": Sport.gym.color])
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 180)
        }
        .padding(16)
        .cardSurface()

        let p = logged.compactMap(\.protein).reduce(0, +)
        let c = logged.compactMap(\.carbs).reduce(0, +)
        let f = logged.compactMap(\.fat).reduce(0, +)
        let total = p * 4 + c * 4 + f * 9
        if total > 0, !logged.isEmpty {
            let n = Double(logged.count)
            VStack(alignment: .leading, spacing: 10) {
                Text("Nährstoffe pro Tag (Ø)").font(.headline)
                GeometryReader { g in
                    HStack(spacing: 0) {
                        Rectangle().fill(Sport.gym.color).frame(width: g.size.width * p * 4 / total)
                        Rectangle().fill(Color.blue).frame(width: g.size.width * c * 4 / total)
                        Rectangle().fill(Color(red: 0.9, green: 0.63, blue: 0))
                    }
                }
                .frame(height: 18).clipShape(Capsule())
                HStack {
                    Text("Eiweiß \(FitFmt.int(p / n)) g · \(Int((p * 4 / total * 100).rounded())) %").foregroundStyle(Sport.gym.color)
                    Spacer()
                    Text("KH \(FitFmt.int(c / n)) g").foregroundStyle(.blue)
                    Spacer()
                    Text("Fett \(FitFmt.int(f / n)) g").foregroundStyle(Color(red: 0.6, green: 0.42, blue: 0))
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(16)
            .cardSurface()
        }

        if let txt = compareText(complete) {
            Text(txt).font(.subheadline)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Sport.gym.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// Rechnerisch (Defizit / 7700 kcal pro kg) gegen Waage
    private func compareText(_ days: [NutritionDay]) -> String? {
        let def = days.compactMap { d in d.burned.map { $0 - (d.kcal ?? 0) } }.reduce(0, +)
        guard days.count >= 3 else { return nil }
        let calc = -def / 7700
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        guard let now = fit.weights.last, let before = fit.weights.last(where: { $0.date <= weekAgo }) else {
            return "Rechnerisch \(calc <= 0 ? "−" : "+")\(FitFmt.num(abs(calc), 1)) kg in den letzten \(days.count) Tagen."
        }
        let real = now.value - before.value
        return "Rechnerisch \(calc <= 0 ? "−" : "+")\(FitFmt.num(abs(calc), 1)) kg, die Waage zeigt \(real <= 0 ? "−" : "+")\(FitFmt.num(abs(real), 1)) kg in einer Woche."
    }

    private func stat(_ l: String, _ v: String, _ s: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(l).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.title3.weight(.heavy)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(s).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 18)
    }

    private var targetsSheet: some View {
        NavigationStack {
            Form {
                Section("Kalorien") {
                    Stepper(value: $deficit, in: 0...1000, step: 50) { LabeledContent("Defizit pro Tag", value: FitFmt.int(deficit) + " kcal") }
                }
                Section("Nährstoffe") {
                    Stepper(value: $proteinKg, in: 1...2.5, step: 0.1) { LabeledContent("Eiweiß pro kg Zielgewicht", value: FitFmt.num(proteinKg, 1) + " g") }
                    Stepper(value: $carbsMax, in: 50...400, step: 10) { LabeledContent("Kohlenhydrate höchstens", value: FitFmt.int(carbsMax) + " g") }
                    Stepper(value: $fatMax, in: 30...150, step: 5) { LabeledContent("Fett höchstens", value: FitFmt.int(fatMax) + " g") }
                    Stepper(value: $fiberMin, in: 10...60, step: 5) { LabeledContent("Ballaststoffe mindestens", value: FitFmt.int(fiberMin) + " g") }
                    Stepper(value: $sugarMax, in: 10...100, step: 5) { LabeledContent("Zucker höchstens", value: FitFmt.int(sugarMax) + " g") }
                    Stepper(value: $waterMin, in: 1...5, step: 0.25) { LabeledContent("Wasser mindestens", value: FitFmt.num(waterMin, 2) + " L") }
                }
            }
            .navigationTitle("Ziele")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showTargets = false } } }
        }
    }
}

// MARK: - Körperwerte (Entwurf E3)

struct BodyCompView: View {
    @State private var fit = FitnessModel.shared
    @State private var range = 182
    @AppStorage("fitStartKg") private var startKg = FitnessConfig.defaultStartKg

    private struct Pair: Identifiable { let date: Date; let fat: Double; let lean: Double; var id: Date { date } }

    /// Fett- und Magermasse an Tagen, an denen Gewicht und Körperfett gemessen wurden
    private var pairs: [Pair] {
        let cal = Calendar.current
        var fatByDay: [Date: Double] = [:]
        for p in fit.bodyFat { fatByDay[cal.startOfDay(for: p.date)] = p.value }
        var out: [Date: Pair] = [:]
        for w in fit.weights {
            let d = cal.startOfDay(for: w.date)
            guard let f = fatByDay[d] else { continue }
            let fm = w.value * f / 100
            out[d] = Pair(date: d, fat: fm, lean: w.value - fm)
        }
        return out.values.sorted { $0.date < $1.date }
    }

    var body: some View {
        let from = Calendar.current.date(byAdding: .day, value: -range, to: .now)!
        let ps = pairs
        let inRange = ps.filter { $0.date >= from }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let last = fit.weights.last {
                    Text("Letzte Messung: " + last.date.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    tile("Gewicht", fit.weights.last.map { FitFmt.num($0.value, 1) + " kg" },
                         fit.weights.last.map { $0.value - startKg }, "seit Start", unit: " kg", lowerIsBetter: true)
                    tile("Körperfett", fit.bodyFat.last.map { FitFmt.num($0.value, 1) + " %" },
                         delta(fit.bodyFat, from), "im Zeitraum", unit: " %", lowerIsBetter: true)
                    tile("Magermasse", fit.lean.last.map { FitFmt.num($0.value, 1) + " kg" } ?? ps.last.map { FitFmt.num($0.lean, 1) + " kg" },
                         fit.lean.isEmpty ? (inRange.count > 1 ? inRange.last!.lean - inRange.first!.lean : nil) : delta(fit.lean, from),
                         "im Zeitraum", unit: " kg", lowerIsBetter: false)
                    tile("BMI", fit.bmi.last.map { FitFmt.num($0.value, 1) }, delta(fit.bmi, from), "im Zeitraum", unit: "", lowerIsBetter: true)
                }
                Picker("Zeitraum", selection: $range) {
                    Text("1 Mon.").tag(30)
                    Text("3 Mon.").tag(91)
                    Text("6 Mon.").tag(182)
                    Text("1 Jahr").tag(365)
                }
                .pickerStyle(.segmented)
                if inRange.count > 1, let a = inRange.first, let b = inRange.last {
                    lostCard(a, b)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fett und Magermasse").font(.headline)
                        Chart {
                            ForEach(inRange) { p in
                                LineMark(x: .value("Datum", p.date), y: .value("kg", p.fat), series: .value("Art", "Fett"))
                                    .foregroundStyle(Color(red: 0.9, green: 0.63, blue: 0))
                                LineMark(x: .value("Datum", p.date), y: .value("kg", p.lean), series: .value("Art", "Magermasse"))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .frame(height: 170)
                        HStack(spacing: 14) {
                            Label("Fett \(FitFmt.num(b.fat, 1)) kg", systemImage: "circle.fill").foregroundStyle(Color(red: 0.75, green: 0.52, blue: 0))
                            Label("Magermasse \(FitFmt.num(b.lean, 1)) kg", systemImage: "circle.fill").foregroundStyle(.blue)
                        }
                        .font(.caption.weight(.semibold)).labelStyle(.titleAndIcon)
                    }
                    .padding(16)
                    .cardSurface()
                } else {
                    Text("Für Fett und Magermasse braucht es Messungen mit Körperfett (Renpho schreibt sie nach Apple Health, wenn das Teilen eingeschaltet ist).")
                        .font(.footnote).foregroundStyle(.secondary).padding(14).cardSurface(radius: 18)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Körperwerte")
        .refreshable { await fit.refresh(maxAge: 0) }
    }

    private func delta(_ list: [FitPoint], _ from: Date) -> Double? {
        let r = list.filter { $0.date >= from }
        guard let a = r.first, let b = r.last, r.count > 1 else { return nil }
        return b.value - a.value
    }

    private func tile(_ l: String, _ v: String?, _ d: Double?, _ suffix: String, unit: String, lowerIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.caption).foregroundStyle(.secondary)
            Text(v ?? "–").font(.title2.weight(.heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let d {
                let good = lowerIsBetter ? d <= 0 : d >= 0
                Text((d <= 0 ? "−" : "+") + FitFmt.num(abs(d), 1) + unit + " " + suffix)
                    .font(.caption.weight(.semibold)).foregroundStyle(good ? .green : .orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func lostCard(_ a: Pair, _ b: Pair) -> some View {
        let fatLost = a.fat - b.fat
        let leanLost = a.lean - b.lean
        let total = fatLost + leanLost
        return VStack(alignment: .leading, spacing: 10) {
            Text(total >= 0 ? "Was du verloren hast" : "Was sich verändert hat").font(.headline)
            if total > 0.2 {
                let fatShare = max(0, min(1, fatLost / total))
                GeometryReader { g in
                    HStack(spacing: 0) {
                        Text("Fett −\(FitFmt.num(fatLost, 1)) kg").font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                            .padding(.leading, 8).frame(width: g.size.width * fatShare, alignment: .leading)
                            .background(Color(red: 0.9, green: 0.63, blue: 0))
                        Text(FitFmt.num(-leanLost, 1)).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity).background(Color.blue)
                    }
                    .frame(height: 26)
                }
                .frame(height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(LocalizedStringKey("Von −\(FitFmt.num(total, 1)) kg waren **\(Int((fatShare * 100).rounded())) % Fett**. "
                     + (fatShare >= 0.75 ? "Die Magermasse (Muskeln, Wasser, Knochen) bleibt gut erhalten – das Krafttraining hilft dabei."
                                         : "Etwas viel Magermasse – mehr Eiweiß und Krafttraining helfen, Muskeln zu halten.")))
                    .font(.footnote)
            } else {
                Text("Fett \(fatLost >= 0 ? "−" : "+")\(FitFmt.num(abs(fatLost), 1)) kg · Magermasse \(leanLost >= 0 ? "−" : "+")\(FitFmt.num(abs(leanLost), 1)) kg im Zeitraum.")
                    .font(.footnote)
            }
        }
        .padding(16)
        .cardSurface()
    }
}
