import SwiftUI
import Charts

// MARK: - Strom-Verlauf (HA-Langzeitstatistik) und Ladevorgänge (evcc)

struct EnergyDay: Identifiable {
    let date: Date
    var pv: Double?
    var bought: Double?
    var sold: Double?
    var boughtCost: Double?          // nach Tageszeit-Tarif
    var id: Date { date }

    var valid: Bool { pv != nil && bought != nil && sold != nil }
    var usage: Double { max((pv ?? 0) + (bought ?? 0) - (sold ?? 0), 0) }
    /// Selbst verbrauchter Solarstrom
    var own: Double { max(usage - (bought ?? 0), 0) }
    var autarky: Double { usage > 0 ? max(0, min(1, own / usage)) : 0 }
}

/// Evcc-Namen der Ladepunkte (so heißen sie in der evcc-Historie)
extension EnergyConfig {
    static let evccTitles: [String: String] = [
        "openwb": "openWB", "garage_ebike": "Garage Ebike", "pool_wasserpumpe": "Pool Wasserpumpe",
        "pool_warmepumpe": "Pool Wärmepumpe", "elternbad_heizkorper": "Elternbad Heizkörper",
        "kinderbad_heizkorper": "Kinderbad Heizkörper", "konvektor_hobbyraum": "Konvektor Hobbyraum",
        "konvektor_technikraum": "Konvektor Technikraum", "midea_klima_schlafzimmer": "Midea Klima Schlafzimmer",
    ]
    static let sessionsScript = "familie_evcc_sessions"
}

struct ChargeSession: Identifiable {
    let id: Int
    let start: Date
    let end: Date?
    let loadpoint: String
    let vehicle: String
    let kwh: Double
    let price: Double?
    let pricePerKWh: Double?
    let referencePerKWh: Double?
    let solar: Double?
    let duration: TimeInterval
    let odometer: Double?
}

@MainActor
extension AppStore {
    func energyDays(since start: Date) async -> [EnergyDay] {
        let ids = [EnergyConfig.pvEnergy, EnergyConfig.importEnergy, EnergyConfig.exportEnergy]
        guard let r = try? await client.websocket([
            "type": "recorder/statistics_during_period", "start_time": HADate.iso.string(from: start),
            "statistic_ids": ids, "period": "day", "types": ["change"],
        ]), let obj = r.object else { return [] }
        var days: [Double: EnergyDay] = [:]
        for (id, list) in obj {
            for p in list.array ?? [] {
                guard let ms = p["start"]?.double else { continue }
                var d = days[ms] ?? EnergyDay(date: Date(timeIntervalSince1970: ms / 1000))
                let c = p["change"]?.double
                switch id {
                case EnergyConfig.pvEnergy: d.pv = c.map { max($0, 0) }                       // kleine Minuswerte nachts
                case EnergyConfig.importEnergy: d.bought = c.flatMap { $0 >= 0 && $0 < 300 ? $0 : nil }  // Zählersprünge raus
                case EnergyConfig.exportEnergy: d.sold = c.flatMap { $0 >= 0 && $0 < 300 ? $0 : nil }
                default: break
                }
                days[ms] = d
            }
        }
        let costs = await boughtCostByDay(since: start)
        let cal = Calendar.current
        return days.values.filter(\.valid).map { d in
            var d = d
            d.boughtCost = costs[cal.startOfDay(for: d.date)]
            return d
        }.sorted { $0.date < $1.date }
    }

    func chargeSessions(year: Int, month: Int) async -> [ChargeSession] {
        guard let r = try? await client.callWithResponse("script", EnergyConfig.sessionsScript,
                                                          ["year": year, "month": month], timeout: 30) else { return [] }
        let list = (r["content"] ?? r).array ?? r["content"]?["result"]?.array ?? []
        return list.compactMap { s in
            guard let id = s["id"]?.int, let start = HADate.parse(s["created"]?.string) else { return nil }
            let end = HADate.parse(s["finished"]?.string)
            return ChargeSession(
                id: id, start: start, end: end,
                loadpoint: s["loadpoint"]?.string ?? "", vehicle: s["vehicle"]?.string ?? "",
                kwh: s["chargedEnergy"]?.double ?? 0, price: s["price"]?.double,
                pricePerKWh: s["pricePerKWh"]?.double, referencePerKWh: s["referencePricePerKWh"]?.double,
                solar: s["solarPercentage"]?.double,
                duration: (s["chargeDuration"]?.double ?? 0) / 1_000_000_000,   // evcc liefert Nanosekunden
                odometer: s["odometer"]?.double)
        }
        .sorted { $0.start > $1.start }
    }
}

// MARK: - Verlauf

struct EnergyHistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var mode = "tage"
    @State private var days: [EnergyDay] = []
    @State private var loading = true
    /// Der Tag bzw. Monat, der unten im Detail steht
    @State private var selected: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    /// Nur solange der Finger auf dem Diagramm liegt (Charts setzt das danach wieder auf nil)
    @State private var chartTouch: Date?
    /// Richtung der Blätter-Animation
    @State private var forward = true

    private var price: Double { EnergyConfig.dayPrice }
    private var feed: Double { store.num(EnergyConfig.feedIn) ?? 0.11 }
    private var unit: Calendar.Component { mode == "tage" ? .day : .month }

    /// Alle geladenen Tage bzw. Monate (für das Blättern im Detail)
    private var all: [EnergyDay] {
        if mode == "tage" { return days }
        let cal = Calendar.current
        let grouped = Dictionary(grouping: days) { cal.date(from: cal.dateComponents([.year, .month], from: $0.date))! }
        return grouped.map { Self.sum($0.value, date: $0.key) }.sorted { $0.date < $1.date }
    }

    private var selectedIndex: Int? {
        all.firstIndex { Calendar.current.isDate($0.date, equalTo: selected, toGranularity: unit) }
    }

    /// Diagramm: 30 Tage bzw. 12 Monate rund um die Auswahl
    private var entries: [EnergyDay] {
        let list = all
        let window = mode == "tage" ? 30 : 12
        guard list.count > window, let idx = selectedIndex else { return Array(list.suffix(window)) }
        if idx >= list.count - window { return Array(list.suffix(window)) }
        let start = max(0, idx - window / 2)
        return Array(list[start..<min(list.count, start + window)])
    }

    static func sum(_ list: [EnergyDay], date: Date) -> EnergyDay {
        var pv: Double = 0
        var bought: Double = 0
        var sold: Double = 0
        var cost: Double = 0
        for d in list {
            pv += d.pv ?? 0
            bought += d.bought ?? 0
            sold += d.sold ?? 0
            cost += d.boughtCost ?? (d.bought ?? 0) * EnergyConfig.dayPrice
        }
        return EnergyDay(date: date, pv: pv, bought: bought, sold: sold, boughtCost: cost)
    }

    private var selectedEntry: EnergyDay? { selectedIndex.map { all[$0] } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Zeitraum", selection: $mode) {
                    Text("Tage").tag("tage")
                    Text("Monate").tag("monate")
                }
                .pickerStyle(.segmented)

                if loading {
                    ProgressView().frame(height: 220)
                } else if all.isEmpty {
                    ContentUnavailableView("Keine Daten", systemImage: "chart.bar")
                } else {
                    detailCard
                    chartCard
                    sumCard
                }
                Text("Kosten nach Tageszeit: \(EnergyConfig.tariffNote.replacingOccurrences(of: "Tarif: ", with: "")), Einspeisung \(Int((feed * 100).rounded())) ct.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Strom-Verlauf")
        .task {
            let start = Calendar.current.date(byAdding: .month, value: -24, to: Date())!
            days = await store.energyDays(since: Calendar.current.startOfDay(for: start))
            loading = false
            if mode == "tage", selectedIndex == nil, let last = days.last { selected = last.date }
        }
        .onChange(of: mode) { _, m in
            selected = m == "tage" ? (Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()) : Date()
        }
        .onChange(of: chartTouch) { _, t in
            if let t { selected = t }
        }
    }

    private func dim(_ d: EnergyDay) -> Bool {
        guard let sel = selectedEntry else { return false }
        return sel.id != d.id
    }

    // MARK: Detail mit Blättern

    private func step(_ by: Int) {
        guard let idx = selectedIndex else { return }
        let n = idx + by
        guard all.indices.contains(n) else { return }
        forward = by > 0
        withAnimation(.snappy) { selected = all[n].date }
    }

    private var canBack: Bool { (selectedIndex ?? 0) > 0 }
    private var canForward: Bool { (selectedIndex ?? all.count) < all.count - 1 }

    @ViewBuilder private var detailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32)
                }
                .disabled(!canBack)
                Spacer()
                VStack(spacing: 1) {
                    Text(detailTitle(selected)).font(.headline)
                    if mode == "tage", !isNear(selected) {
                        Text(selected.formatted(.dateTime.day().month(.wide).year())).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentTransition(.numericText())
                Spacer()
                Button { step(1) } label: {
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32)
                }
                .disabled(!canForward)
            }
            .buttonStyle(.borderless)
            .overlay(alignment: .trailing) { datePickerButton.padding(.trailing, 40) }

            Group {
                if let d = selectedEntry {
                    EnergySummaryBlock(e: d, price: price, feed: feed)
                        .id(d.id)
                        .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                removal: .opacity))
                } else {
                    Text("Für diesen Tag gibt es keine Messwerte.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .clipped()
            Text(mode == "tage" ? "Wischen für andere Tage" : "Wischen für andere Monate")
                .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    if v.translation.width > 50 { step(-1) }       // nach rechts ziehen = früher
                    else if v.translation.width < -50 { step(1) } // nach links ziehen = später
                }
        )
    }

    /// Kleines Kalender-Symbol: Tag direkt auswählen
    @ViewBuilder private var datePickerButton: some View {
        if mode == "tage", let first = days.first?.date, let last = days.last?.date {
            ZStack {
                Image(systemName: "calendar").font(.subheadline).foregroundStyle(Color.accentColor)
                DatePicker("Tag wählen", selection: Binding(get: { selected }, set: { v in
                    forward = v > selected
                    withAnimation(.snappy) { selected = v }
                }), in: first...last, displayedComponents: .date)
                .labelsHidden()
                .colorMultiply(.clear)       // unsichtbar über dem Symbol, tippen öffnet den Kalender
                .frame(width: 32, height: 32)
                .clipped()
            }
            .frame(width: 32, height: 32)
            .accessibilityLabel("Tag wählen")
        }
    }

    private func isNear(_ date: Date) -> Bool {
        let cal = Calendar.current
        return cal.isDateInToday(date) || cal.isDateInYesterday(date)
    }

    private func detailTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if mode != "tage" { return date.formatted(.dateTime.month(.wide).year()) }
        if cal.isDateInYesterday(date) { return "Gestern" }
        if cal.isDateInToday(date) { return "Heute (bisher)" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    // MARK: Diagramm

    private var chartTitle: String {
        guard let f = entries.first?.date, let l = entries.last?.date else { return "" }
        if mode == "tage" {
            if entries.last?.id == all.last?.id { return "Letzte 30 Tage" }
            return f.formatted(.dateTime.day().month(.abbreviated)) + " – " + l.formatted(.dateTime.day().month(.abbreviated).year())
        }
        if entries.last?.id == all.last?.id { return "Letzte 12 Monate" }
        return f.formatted(.dateTime.month(.abbreviated).year()) + " – " + l.formatted(.dateTime.month(.abbreviated).year())
    }

    private var chartCard: some View {
        Card(title: chartTitle, symbol: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(entries) { d in
                        BarMark(x: .value("Datum", d.date, unit: unit), y: .value("kWh", d.own))
                            .foregroundStyle(by: .value("Art", "Eigener Solarstrom"))
                            .opacity(dim(d) ? 0.35 : 1)
                        BarMark(x: .value("Datum", d.date, unit: unit), y: .value("kWh", d.bought ?? 0))
                            .foregroundStyle(by: .value("Art", "Aus dem Netz"))
                            .opacity(dim(d) ? 0.35 : 1)
                    }
                }
                .chartForegroundStyleScale(["Eigener Solarstrom": Color.green, "Aus dem Netz": Color.red.opacity(0.75)])
                .chartXSelection(value: $chartTouch)
                .chartXAxis {
                    if mode == "tage" {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    } else {
                        AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                            AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                }
                .frame(height: 200)
                Text("Balken antippen oder darüber wischen für Details").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var sumCard: some View {
        let total = Self.sum(entries, date: Date())
        return Card(title: mode == "tage" ? "Summe dieser 30 Tage" : "Summe dieser 12 Monate", symbol: "sum") {
            EnergySummaryBlock(e: total, price: price, feed: feed)
        }
    }
}

struct EnergySummaryBlock: View {
    let e: EnergyDay
    let price: Double
    let feed: Double

    var body: some View {
        let cost = e.boughtCost ?? (e.bought ?? 0) * price
        let income = (e.sold ?? 0) * feed
        let saved = e.own * price
        VStack(spacing: 12) {
            HStack {
                StatBlock(value: Fmt.kwh(e.pv), label: "erzeugt", color: .yellow)
                StatBlock(value: Fmt.kwh(e.usage), label: "verbraucht", color: .blue)
                StatBlock(value: "\(Int((e.autarky * 100).rounded())) %", label: "autark", color: .green)
            }
            Divider()
            VStack(spacing: 6) {
                MoneyRow(symbol: "arrow.down.circle.fill", color: .red, label: "Gekauft \(Fmt.kwh(e.bought))", value: "−" + Fmt.euro(cost))
                MoneyRow(symbol: "arrow.up.circle.fill", color: .green, label: "Eingespeist \(Fmt.kwh(e.sold))", value: "+" + Fmt.euro(income))
                MoneyRow(symbol: "sun.max.fill", color: .yellow, label: "Solar selbst genutzt \(Fmt.kwh(e.own))", value: "gespart " + Fmt.euro(saved))
                Divider()
                HStack {
                    Text("Stromrechnung netto").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Fmt.euro(cost - income)).font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(cost - income > 0 ? Color.primary : Color.green)
                }
            }
        }
    }
}

struct MoneyRow: View {
    let symbol: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            Label(label, systemImage: symbol).foregroundStyle(color).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit())
        }
    }
}

// MARK: - Ladevorgänge

struct ChargeSessionsView: View {
    @Environment(AppStore.self) private var store
    let lp: EnergyConfig.Loadpoint
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var cache: [Date: [ChargeSession]] = [:]
    @State private var loadingMonths = true
    @State private var selectedMonth: Date?

    private var evccName: String { EnergyConfig.evccTitles[lp.key] ?? lp.name }
    private var months: [Date] {
        (0..<12).reversed().compactMap { Calendar.current.date(byAdding: .month, value: -$0, to: currentMonth) }
    }
    private var currentMonth: Date { Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))! }
    private func sessions(_ m: Date) -> [ChargeSession] { (cache[m] ?? []).filter { $0.loadpoint == evccName } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                yearCard
                monthHeader
                monthSummary
                listCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(lp.name)
        .task { await loadYear() }
        .onChange(of: selectedMonth) { _, m in
            if let m, let hit = months.first(where: { Calendar.current.isDate($0, equalTo: m, toGranularity: .month) }) { month = hit }
        }
    }

    private func loadYear() async {
        let cal = Calendar.current
        let st = store
        await withTaskGroup(of: (Date, [ChargeSession]).self) { group in
            for m in months where cache[m] == nil {
                let c = cal.dateComponents([.year, .month], from: m)
                let y = c.year ?? 2026, mo = c.month ?? 1
                group.addTask {
                    return (m, await st.chargeSessions(year: y, month: mo))
                }
            }
            for await (m, list) in group { cache[m] = list }
        }
        loadingMonths = false
    }

    // Jahresbalken
    private var yearCard: some View {
        Card(title: "Letzte 12 Monate", symbol: "chart.bar.fill") {
            if loadingMonths {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(months, id: \.self) { m in
                        let t = SessionTotals(sessions(m))
                        let barOpacity: Double = Calendar.current.isDate(m, equalTo: month, toGranularity: .month) ? 1 : 0.45
                        let solarKwh: Double = t.solarKwh
                        let gridKwh: Double = t.kwh - t.solarKwh
                        BarMark(x: .value("Monat", m, unit: .month), y: .value("kWh", solarKwh))
                            .foregroundStyle(by: .value("Art", "Sonne"))
                            .opacity(barOpacity)
                        BarMark(x: .value("Monat", m, unit: .month), y: .value("kWh", gridKwh))
                            .foregroundStyle(by: .value("Art", "Netz/Akku"))
                            .opacity(barOpacity)
                    }
                }
                .chartForegroundStyleScale(["Sonne": Color.yellow, "Netz/Akku": Color.gray.opacity(0.6)])
                .chartXSelection(value: $selectedMonth)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                        AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 170)
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .disabled(month <= months.first!)
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(month >= currentMonth)
        }
        .buttonStyle(.bordered)
    }

    private func shift(_ by: Int) {
        if let m = Calendar.current.date(byAdding: .month, value: by, to: month) { month = m }
    }

    private var monthSummary: some View {
        let list = sessions(month)
        let t = SessionTotals(list, fallbackPrice: EnergyConfig.dayPrice)
        let kwh: Double = t.kwh
        let cost: Double = t.cost
        let solar: Double = t.solarShare
        let reference: Double = t.reference
        return Card(title: "\(list.count) Ladevorgänge", symbol: lp.symbol) {
            VStack(spacing: 12) {
                HStack {
                    StatBlock(value: Fmt.kwh(kwh), label: "geladen", color: .blue)
                    StatBlock(value: Fmt.euro(cost), label: "gekostet", color: .red)
                    StatBlock(value: "\(Int((solar * 100).rounded())) %", label: "Sonne", color: .yellow)
                }
                if kwh > 0 {
                    Divider()
                    MoneyRow(symbol: "eurosign.circle", color: .secondary, label: "Ø Preis",
                             value: "\(Int((cost / kwh * 100).rounded())) ct/kWh")
                    MoneyRow(symbol: "leaf.fill", color: .green, label: "Gespart ggü. Netzstrom",
                             value: Fmt.euro(max(reference - cost, 0)))
                }
            }
        }
    }

    private var listCard: some View {
        let list = sessions(month)
        return Card(title: "Einzelne Ladungen", symbol: "list.bullet") {
            if loadingMonths && cache[month] == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else if list.isEmpty {
                Text("Keine Ladungen in diesem Monat").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        SessionRow(s: s)
                        if s.id != list.last?.id { Divider().padding(.vertical, 8) }
                    }
                }
            }
        }
    }
}

struct SessionTotals {
    var kwh: Double = 0
    var solarKwh: Double = 0
    var cost: Double = 0
    var reference: Double = 0

    init(_ list: [ChargeSession], fallbackPrice: Double = 0.29) {
        for s in list {
            let solarShare: Double = (s.solar ?? 0) / 100
            let refPrice: Double = s.referencePerKWh ?? fallbackPrice
            kwh += s.kwh
            solarKwh += s.kwh * solarShare
            cost += s.price ?? 0
            reference += s.kwh * refPrice
        }
    }
    var solarShare: Double { kwh > 0 ? solarKwh / kwh : 0 }
}

struct SessionRow: View {
    let s: ChargeSession

    private var durationText: String {
        let m = Int(s.duration / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.subheadline.weight(.semibold))
                Text(s.start.formatted(date: .omitted, time: .shortened) + (s.end.map { "–" + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.kwh(s.kwh)).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 10) {
                Label(durationText, systemImage: "clock").labelStyle(.titleAndIcon)
                if let p = s.price { Label(Fmt.euro(p), systemImage: "eurosign") }
                if let pk = s.pricePerKWh { Text("\(Int((pk * 100).rounded())) ct/kWh") }
                Spacer()
                if !s.vehicle.isEmpty && s.vehicle != s.loadpoint { Text(s.vehicle) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let solar = s.solar {
                HStack(spacing: 6) {
                    ProgressView(value: min(max(solar, 0), 100), total: 100).tint(.yellow)
                    Text("\(Int(solar.rounded())) % Sonne").font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}
