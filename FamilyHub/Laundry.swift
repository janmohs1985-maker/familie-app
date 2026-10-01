import SwiftUI
import Charts

// MARK: - Wäsche: Waschmaschine & Trockner (Tasmota-Steckdosen)
//
// Home Assistant (Automation „Familie: Wäsche fertig“) erkennt Start und Ende am Stromverbrauch und
// trägt jeden Durchgang in todo.waesche_verlauf ein: Fälligkeit = Start, Beschreibung = "gerät;kWh;€;Minuten;€/kWh".

enum LaundryConfig {
    struct Device: Identifiable {
        let key: String
        let name: String
        let symbol: String
        let color: Color
        var id: String { key }
        var power: String { "sensor.\(key)_energy_power" }
        var total: String { "sensor.\(key)_energy_total" }
        var running: String { "input_boolean.\(key)_lauft" }
        var start: String { "input_datetime.\(key)_start" }
        var startKWh: String { "input_number.\(key)_start_kwh" }
        var startPrice: String { "input_number.\(key)_start_preis" }
    }
    static let devices: [Device] = [
        Device(key: "waschmaschine", name: "Waschmaschine", symbol: "washer.fill", color: .blue),
        Device(key: "trockner", name: "Trockner", symbol: "dryer.fill", color: .orange),
    ]
    static let history = "todo.waesche_verlauf"
}

struct LaundryRun: Identifiable, Hashable {
    let id: String
    let device: String
    let start: Date
    let kwh: Double
    let cost: Double
    let minutes: Int
    let price: Double?
}

@MainActor
extension AppStore {
    func laundryIsRunning(_ d: LaundryConfig.Device) -> Bool { states[d.running]?.state == "on" }

    func laundryStart(_ d: LaundryConfig.Device) -> Date? {
        HADate.serviceDateTime.date(from: states[d.start]?.state ?? "")
    }

    /// Verbrauch und Kosten des laufenden Durchgangs
    func laundryCurrent(_ d: LaundryConfig.Device) -> (kwh: Double, cost: Double) {
        let kwh = max((num(d.total) ?? 0) - (num(d.startKWh) ?? 0), 0)
        let price = num(d.startPrice) ?? num(EnergyConfig.price) ?? 0.3
        return (kwh, kwh * price)
    }

    func loadLaundryRuns() async -> [LaundryRun] {
        guard let r = try? await client.callWithResponse("todo", "get_items", ["entity_id": LaundryConfig.history,
                                                                                 "status": ["needs_action", "completed"]]),
              let items = r[LaundryConfig.history]?["items"]?.array else { return [] }
        var out: [LaundryRun] = []
        for i in items {
            guard let uid = i["uid"]?.string, let start = HADate.parse(i["due"]?.string),
                  let parts = i["description"]?.string?.split(separator: ";").map(String.init), parts.count >= 4 else { continue }
            out.append(LaundryRun(id: uid, device: parts[0], start: start,
                                  kwh: Double(parts[1]) ?? 0, cost: Double(parts[2]) ?? 0,
                                  minutes: Int(Double(parts[3]) ?? 0),
                                  price: parts.count > 4 ? Double(parts[4]) : nil))
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Typische Dauer (Median der letzten 10 Durchgänge)
    func typicalMinutes(_ runs: [LaundryRun], device: String) -> Int? {
        let m = runs.filter { $0.device == device }.prefix(10).map(\.minutes).sorted()
        guard !m.isEmpty else { return nil }
        return m[m.count / 2]
    }

    /// kWh je Monat aus der Langzeitstatistik der Steckdosen
    func laundryMonths() async -> [String: [PoolPoint]] {
        let ids = LaundryConfig.devices.map(\.total)
        let start = Calendar.current.date(byAdding: .month, value: -11, to: Date())!
        let first = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: start))!
        guard let r = try? await client.websocket([
            "type": "recorder/statistics_during_period", "start_time": HADate.iso.string(from: first),
            "statistic_ids": ids, "period": "month", "types": ["change"],
        ]), let obj = r.object else { return [:] }
        var out: [String: [PoolPoint]] = [:]
        for (k, v) in obj {
            out[k] = (v.array ?? []).compactMap { p in
                guard let s = p["start"]?.double, let c = p["change"]?.double else { return nil }
                return PoolPoint(time: Date(timeIntervalSince1970: s / 1000), value: (c >= 0 && c < 200) ? c : 0)  // Zählersprünge raus
            }
        }
        return out
    }
}

// MARK: - Seite

struct LaundryView: View {
    @Environment(AppStore.self) private var store
    @State private var runs: [LaundryRun] = []
    @State private var months: [String: [PoolPoint]] = [:]
    @State private var showAll = false

    private var price: Double { EnergyConfig.dayPrice }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                ForEach(LaundryConfig.devices) { d in deviceCard(d) }
                monthCard
                historyCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wäsche")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        async let r = store.loadLaundryRuns()
        async let m = store.laundryMonths()
        async let s: Void = store.refreshStates()
        runs = await r
        months = await m
        _ = await s
    }

    // MARK: Gerät

    private func deviceCard(_ d: LaundryConfig.Device) -> some View {
        let running = store.laundryIsRunning(d)
        let watts = store.num(d.power) ?? 0
        let start = store.laundryStart(d)
        let cur = store.laundryCurrent(d)
        let typical = store.typicalMinutes(runs, device: d.key)
        let last = runs.first { $0.device == d.key }
        return Card(title: d.name, symbol: d.symbol) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(running ? d.color.opacity(0.15) : Color(.tertiarySystemFill)).frame(width: 64, height: 64)
                        Image(systemName: d.symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(running ? d.color : Color.secondary)
                            .symbolEffect(.pulse, isActive: running)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if running, let start {
                            Text("Läuft seit \(start.formatted(date: .omitted, time: .shortened))").font(.headline)
                            Text(start, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(d.color)
                        } else if let last {
                            Text("Aus").font(.headline)
                            Text("Zuletzt \(DayText.label(last.start)), \(last.start.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Aus").font(.headline)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.watts(watts)).font(.title3.weight(.bold).monospacedDigit())
                        Text("gerade").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if running {
                    if let typical, let start {
                        let end = start.addingTimeInterval(Double(typical) * 60)
                        let progress = min(max(Date().timeIntervalSince(start) / (Double(typical) * 60), 0), 1)
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: progress).tint(d.color)
                            Text(end > Date() ? "fertig ca. \(end.formatted(date: .omitted, time: .shortened)) Uhr (üblich \(typical) min)"
                                              : "dauert länger als üblich (\(typical) min)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        StatBlock(value: String(format: "%.2f kWh", cur.kwh).replacingOccurrences(of: ".", with: ","), label: "bisher", color: d.color)
                        StatBlock(value: Fmt.euro(cur.cost), label: "Kosten bisher", color: .red)
                    }
                } else if let last {
                    HStack {
                        StatBlock(value: "\(last.minutes) min", label: "letzte Dauer", color: d.color)
                        StatBlock(value: String(format: "%.1f kWh", last.kwh).replacingOccurrences(of: ".", with: ","), label: "Verbrauch", color: .blue)
                        StatBlock(value: Fmt.euro(last.cost), label: "Kosten", color: .red)
                    }
                }
            }
        }
    }

    // MARK: Monate

    private var monthCard: some View {
        let wm = months[LaundryConfig.devices[0].total] ?? []
        let tr = months[LaundryConfig.devices[1].total] ?? []
        let totalKWh = (wm + tr).reduce(0.0) { $0 + $1.value }
        let thisMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
        let thisKWh = (wm + tr).filter { Calendar.current.isDate($0.time, equalTo: thisMonth, toGranularity: .month) }.reduce(0.0) { $0 + $1.value }
        return Card(title: "Kosten pro Monat", symbol: "eurosign.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if wm.isEmpty && tr.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart {
                        ForEach(wm) { p in
                            BarMark(x: .value("Monat", p.time, unit: .month), y: .value("€", p.value * price))
                                .foregroundStyle(by: .value("Gerät", "Waschmaschine"))
                        }
                        ForEach(tr) { p in
                            BarMark(x: .value("Monat", p.time, unit: .month), y: .value("€", p.value * price))
                                .foregroundStyle(by: .value("Gerät", "Trockner"))
                        }
                    }
                    .chartForegroundStyleScale(["Waschmaschine": Color.blue, "Trockner": Color.orange])
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                            AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel { if let e = v.as(Double.self) { Text(String(format: "%.0f €", e)) } }
                        }
                    }
                    .frame(height: 170)
                    HStack {
                        StatBlock(value: Fmt.euro(thisKWh * price), label: "dieser Monat", color: .red)
                        StatBlock(value: Fmt.euro(totalKWh * price), label: "12 Monate", color: .red)
                        StatBlock(value: String(format: "%.0f kWh", totalKWh), label: "Verbrauch", color: .blue)
                    }
                    Text("Monatskosten ca., gerechnet mit \(Int((price * 100).rounded())) ct/kWh. Die einzelnen Durchgänge unten nutzen den echten Hauspreis inkl. Solarstrom.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Verlauf

    private var historyCard: some View {
        Card(title: "Letzte Durchgänge", symbol: "list.bullet") {
            if runs.isEmpty {
                Text("Noch keine Durchgänge aufgezeichnet – ab jetzt wird jede Wäsche mitgeschrieben.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs.prefix(showAll ? 60 : 8)) { r in
                        let d = LaundryConfig.devices.first { $0.key == r.device }
                        HStack(spacing: 12) {
                            Image(systemName: d?.symbol ?? "circle")
                                .foregroundStyle(d?.color ?? .gray)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(DayText.label(r.start)), \(r.start.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline.weight(.medium))
                                Text("\(d?.name ?? r.device) · \(r.minutes / 60):\(String(format: "%02d", r.minutes % 60)) Std")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(Fmt.euro(r.cost)).font(.subheadline.weight(.semibold).monospacedDigit())
                                Text(String(format: "%.1f kWh", r.kwh).replacingOccurrences(of: ".", with: ","))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        if r.id != runs.prefix(showAll ? 60 : 8).last?.id { Divider() }
                    }
                    if runs.count > 8 {
                        Button(showAll ? "Weniger" : "Alle anzeigen") { showAll.toggle() }
                            .font(.subheadline).padding(.top, 6)
                    }
                }
            }
        }
    }
}

// MARK: - Karte auf „Heute“ (nur solange etwas läuft)

/// „Aktuell“ auf Heute: laufende Wäsche und Hausakku als Ring-Kacheln
struct LaundryTodayCard: View {
    @Environment(AppStore.self) private var store
    @State private var runs: [LaundryRun] = []

    private var parent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        let active = LaundryConfig.devices.filter { store.laundryIsRunning($0) }
        if !active.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(active) { d in
                        NavigationLink { LaundryView() } label: { laundryTile(d, now: ctx.date) }
                            .buttonStyle(.plain)
                            .dismissable(store.dismissKeyLaundry(d))
                    }
                }
            }
            .task { runs = await store.loadLaundryRuns() }
        }
    }

    private func laundryTile(_ d: LaundryConfig.Device, now: Date) -> some View {
        let start = store.laundryStart(d)
        let typical = store.typicalMinutes(runs, device: d.key)
        let elapsed = start.map { max(0, now.timeIntervalSince($0) / 60) }
        var progress: Double? = nil
        var label = "läuft"
        var sub = "läuft"
        if let elapsed {
            if let typical, typical > 0 {
                let left = Int((Double(typical) - elapsed).rounded())
                progress = elapsed / Double(typical)
                label = left > 0 ? "\(left)m" : "gleich"
                let end = start!.addingTimeInterval(Double(typical) * 60)
                sub = left > 0 ? "fertig ca. \(end.formatted(date: .omitted, time: .shortened))" : "gleich fertig"
            } else {
                label = "\(Int(elapsed))m"
                sub = "seit \(start!.formatted(date: .omitted, time: .shortened))"
            }
        }
        return tile(ring: ProgressRing(progress: progress, color: d.color, label: label),
                    symbol: d.symbol, color: d.color, title: d.name, sub: sub)
    }

    private func batteryTile(_ soc: Double) -> some View {
        let pv = store.num(EnergyConfig.pv) ?? 0
        let bat = store.num(EnergyConfig.battery) ?? 0
        let color: Color = soc < 20 ? .orange : .green
        let state = bat < -30 ? "lädt" : (bat > 30 ? "entlädt" : "Pause")
        let sub = pv >= 20 ? "Sonne \(Fmt.watts(pv)) · \(state)" : state
        return tile(ring: ProgressRing(progress: soc / 100, color: color, label: "\(Int(soc.rounded()))%"),
                    symbol: "bolt.fill", color: .yellow, title: "Hausakku", sub: sub)
    }

    private func tile(ring: ProgressRing, symbol: String, color: Color, title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ring
                Spacer(minLength: 4)
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(color)
            }
            Text(title).font(.subheadline.weight(.bold)).lineLimit(1).padding(.top, 12)
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
    }
}
