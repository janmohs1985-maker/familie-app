import SwiftUI
import Charts

// MARK: - Haus & Strom: SolarEdge, Hausakku, Netz, EVCC-Verbraucher, Tarif

enum EnergyConfig {
    static let pv = "sensor.evcc_pv_power"
    static let home = "sensor.evcc_home_power"
    static let grid = "sensor.evcc_grid_power"            // + Bezug / − Einspeisung
    static let battery = "sensor.evcc_battery_power"      // + Entladen / − Laden
    static let soc = "sensor.evcc_battery_soc"
    static let batteryHealth = "sensor.solaredge_i1_b1_state_of_health"
    static let batteryTemp = "sensor.solaredge_i1_b1_average_temperature"
    static let batteryCapacity = "sensor.solaredge_i1_b1_maximum_energy"
    static let batteryLock = "switch.evcc_battery_discharge_control"
    static let inverterTemp = "sensor.solaredge_i1_temp_sink"
    static let gridFrequency = "sensor.solaredge_i1_m1_ac_frequency"
    static let voltages = ["sensor.solaredge_i1_m1_ac_voltage_an", "sensor.solaredge_i1_m1_ac_voltage_bn", "sensor.solaredge_i1_m1_ac_voltage_cn"]
    static let phasePower = ["sensor.solaredge_i1_m1_ac_power_a", "sensor.solaredge_i1_m1_ac_power_b", "sensor.solaredge_i1_m1_ac_power_c"]
    static let price = "sensor.evcc_tariff_grid"
    static let feedIn = "sensor.evcc_tariff_feed_in"
    static let co2 = "sensor.evcc_tariff_co2"
    static let solarShareTotal = "sensor.evcc_stat_total_solar_percentage"

    // Zähler für „Heute“ (Statistik-Änderung seit Mitternacht)
    static let pvEnergy = "sensor.pv_erzeugung_kwh"
    static let importEnergy = "sensor.solaredge_i1_m1_ac_energy_imported"
    static let exportEnergy = "sensor.solaredge_i1_m1_ac_energy_exported"
    static let water = "sensor.watermeter_value"

    struct Loadpoint: Identifiable {
        let key: String
        let name: String
        let symbol: String
        var id: String { key }
        var mode: String { "select.evcc_\(key)_mode" }
        var power: String { "sensor.evcc_\(key)_charge_power" }         // kW
        var charging: String { "binary_sensor.evcc_\(key)_charging" }
        var solar: String { "sensor.evcc_\(key)_session_solar_percentage" }
    }
    static let car = Loadpoint(key: "openwb", name: "Auto (Wallbox)", symbol: "car.fill")
    static let loadpoints: [Loadpoint] = [
        car,
        Loadpoint(key: "garage_ebike", name: "E-Bike", symbol: "bicycle"),
        Loadpoint(key: "pool_wasserpumpe", name: "Poolpumpe", symbol: "drop.fill"),
        Loadpoint(key: "pool_warmepumpe", name: "Pool-Wärmepumpe", symbol: "thermometer.sun.fill"),
    ] + heaters
    static let heaters: [Loadpoint] = [
        Loadpoint(key: "elternbad_heizkorper", name: "Heizkörper Elternbad", symbol: "heater.vertical.fill"),
        Loadpoint(key: "kinderbad_heizkorper", name: "Heizkörper Kinderbad", symbol: "heater.vertical.fill"),
        Loadpoint(key: "konvektor_hobbyraum", name: "Konvektor Hobbyraum", symbol: "heater.vertical"),
        Loadpoint(key: "konvektor_technikraum", name: "Konvektor Technikraum", symbol: "heater.vertical"),
        Loadpoint(key: "midea_klima_schlafzimmer", name: "Klima Schlafzimmer", symbol: "air.conditioner.horizontal.fill"),
    ]
}

struct EnergyToday {
    var pv: Double?
    var bought: Double?
    var sold: Double?
    var water: Double?
    /// Verbrauch ≈ Erzeugung + Bezug − Einspeisung (Akku gleicht sich über den Tag weitgehend aus)
    var usage: Double? {
        guard let pv, let bought, let sold else { return nil }
        return max(pv + bought - sold, 0)
    }
    var autarky: Double? {
        guard let usage, let bought, usage > 0 else { return nil }
        return max(0, min(1, 1 - bought / usage))
    }
}

@MainActor
extension AppStore {
    /// Stundenmittelwerte aus der HA-Statistik (klein und schnell, auch für 24 h)
    func hourlyMeans(_ ids: [String], hours: Int = 24) async -> [String: [PoolPoint]] {
        let start = HADate.iso.string(from: Date().addingTimeInterval(-Double(hours) * 3600))
        guard let r = try? await client.websocket([
            "type": "recorder/statistics_during_period", "start_time": start,
            "statistic_ids": ids, "period": "hour", "types": ["mean"],
        ]), let obj = r.object else { return [:] }
        var out: [String: [PoolPoint]] = [:]
        for (k, v) in obj {
            out[k] = (v.array ?? []).compactMap { p in
                guard let s = p["start"]?.double, let m = p["mean"]?.double else { return nil }
                return PoolPoint(time: Date(timeIntervalSince1970: s / 1000), value: m)
            }
        }
        return out
    }

    /// Zuwachs eines Zählers seit Mitternacht
    func todayChange(_ id: String) async -> Double? {
        let r = try? await client.websocket([
            "type": "recorder/statistic_during_period", "statistic_id": id,
            "calendar": ["period": "day"], "types": ["change"],
        ])
        return r?["change"]?.double
    }

    func energyToday() async -> EnergyToday {
        async let pv = todayChange(EnergyConfig.pvEnergy)
        async let b = todayChange(EnergyConfig.importEnergy)
        async let s = todayChange(EnergyConfig.exportEnergy)
        async let w = todayChange(EnergyConfig.water)
        return await EnergyToday(pv: pv, bought: b, sold: s, water: w)
    }

    func setSwitch(_ entity: String, _ on: Bool) async {
        do {
            _ = try await client.call("switch", on ? "turn_on" : "turn_off", ["entity_id": entity])
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStates()
        } catch { report(error) }
    }
}

enum Fmt {
    static func watts(_ w: Double) -> String {
        abs(w) >= 1000 ? String(format: "%.1f kW", w / 1000) : "\(Int(w.rounded())) W"
    }
    static func kwh(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v >= 100 ? String(format: "%.0f kWh", v) : String(format: "%.1f kWh", v)
    }
    static func euro(_ v: Double) -> String { String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",") }
}

// MARK: - Ansicht

struct EnergyView: View {
    @Environment(AppStore.self) private var store
    @State private var today = EnergyToday()
    @State private var hist: [String: [PoolPoint]] = [:]

    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                nowCard
                todayCard
                chartCard
                loadpointsCard
                priceCard
                technikCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Haus & Strom")
        .refreshable { await store.refreshStates(); await load() }
        .task { await load() }
    }

    private func load() async {
        async let t = store.energyToday()
        async let h = store.hourlyMeans([EnergyConfig.pv, EnergyConfig.home])
        (today, hist) = await (t, h)
    }

    // MARK: Jetzt

    private var nowCard: some View {
        let pv = store.num(EnergyConfig.pv) ?? 0
        let home = store.num(EnergyConfig.home) ?? 0
        let grid = store.num(EnergyConfig.grid) ?? 0
        let bat = store.num(EnergyConfig.battery) ?? 0
        let soc = store.num(EnergyConfig.soc)
        let own = home > 0 ? max(0, min(1, (home - max(grid, 0)) / home)) : 1
        return Card(title: "Jetzt", symbol: "bolt.fill") {
            VStack(spacing: 14) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        FlowTile(symbol: "sun.max.fill", color: .yellow, title: "Sonne", value: Fmt.watts(pv),
                                 note: pv < 20 ? "keine Erzeugung" : nil)
                        FlowTile(symbol: "house.fill", color: .blue, title: "Haus", value: Fmt.watts(home), note: nil)
                    }
                    GridRow {
                        FlowTile(symbol: grid > 30 ? "arrow.down.to.line" : "arrow.up.to.line",
                                 color: grid > 30 ? .red : .green,
                                 title: grid > 30 ? "Netz – Bezug" : (grid < -30 ? "Netz – Einspeisung" : "Netz"),
                                 value: Fmt.watts(abs(grid)), note: nil)
                        FlowTile(symbol: batterySymbol(soc), color: .green,
                                 title: "Akku \(soc.map { "\(Int($0.rounded())) %" } ?? "")",
                                 value: Fmt.watts(abs(bat)),
                                 note: bat > 30 ? "entlädt" : (bat < -30 ? "lädt" : "Pause"))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Eigenversorgung gerade").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((own * 100).rounded())) %").font(.caption.weight(.bold))
                    }
                    ProgressView(value: own).tint(own > 0.7 ? .green : (own > 0.3 ? .orange : .red))
                }
            }
        }
    }

    private func batterySymbol(_ soc: Double?) -> String {
        guard let s = soc else { return "battery.0percent" }
        switch s {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Heute

    private var todayCard: some View {
        let price = store.num(EnergyConfig.price) ?? 0
        let feed = store.num(EnergyConfig.feedIn) ?? 0
        return Card(title: "Heute", symbol: "calendar") {
            VStack(spacing: 12) {
                HStack {
                    StatBlock(value: Fmt.kwh(today.pv), label: "erzeugt", color: .yellow)
                    StatBlock(value: Fmt.kwh(today.usage), label: "verbraucht", color: .blue)
                    StatBlock(value: today.autarky.map { "\(Int(($0 * 100).rounded())) %" } ?? "–", label: "autark", color: .green)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Gekauft \(Fmt.kwh(today.bought))", systemImage: "arrow.down.circle.fill").foregroundStyle(.red)
                        if let b = today.bought, price > 0 { Text("ca. \(Fmt.euro(b * price))").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Label("Eingespeist \(Fmt.kwh(today.sold))", systemImage: "arrow.up.circle.fill").foregroundStyle(.green)
                        if let s = today.sold, feed > 0 { Text("ca. \(Fmt.euro(s * feed))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .font(.subheadline)
                if let w = today.water, w > 0 {
                    Divider()
                    Label("Wasser heute: \(Int((w * 1000).rounded())) Liter", systemImage: "drop.fill")
                        .font(.subheadline).foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Verlauf

    private var chartCard: some View {
        let pv = hist[EnergyConfig.pv] ?? []
        let home = hist[EnergyConfig.home] ?? []
        return Card(title: "Letzte 24 Stunden", symbol: "chart.xyaxis.line") {
            if pv.count < 2 && home.count < 2 {
                Text("Noch keine Daten").foregroundStyle(.secondary).frame(height: 160)
            } else {
                Chart {
                    ForEach(pv) { p in
                        AreaMark(x: .value("Zeit", p.time), y: .value("W", p.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(by: .value("Art", "Sonne"))
                    }
                    ForEach(home) { p in
                        LineMark(x: .value("Zeit", p.time), y: .value("W", p.value), series: .value("Art", "Haus"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(by: .value("Art", "Haus"))
                    }
                }
                .chartForegroundStyleScale(["Sonne": Color.yellow.opacity(0.6), "Haus": Color.blue])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let w = v.as(Double.self) { Text(Fmt.watts(w)) } }
                    }
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: Verbraucher

    private var loadpointsCard: some View {
        LoadpointList(title: "Verbraucher über EVCC", symbol: "ev.charger.fill", items: EnergyConfig.loadpoints, editable: isParent)
    }

    // MARK: Preis

    private var priceCard: some View {
        Card(title: "Strompreis", symbol: "eurosign.circle.fill") {
            HStack {
                StatBlock(value: store.num(EnergyConfig.price).map { "\(Int(($0 * 100).rounded())) ct" } ?? "–", label: "Bezug / kWh", color: .red)
                StatBlock(value: store.num(EnergyConfig.feedIn).map { "\(Int(($0 * 100).rounded())) ct" } ?? "–", label: "Einspeisung", color: .green)
                StatBlock(value: store.num(EnergyConfig.co2).map { "\(Int($0)) g" } ?? "–", label: "CO₂ / kWh", color: .gray)
            }
        }
    }

    // MARK: Technik

    private var technikCard: some View {
        let volts = EnergyConfig.voltages.compactMap { store.num($0) }
        let phases = EnergyConfig.phasePower.compactMap { store.num($0) }
        return Card(title: "Akku & Technik", symbol: "wrench.and.screwdriver.fill") {
            VStack(spacing: 8) {
                InfoRow("Akku-Gesundheit", store.num(EnergyConfig.batteryHealth).map { "\(Int($0)) %" })
                InfoRow("Akku-Kapazität", store.num(EnergyConfig.batteryCapacity).map { String(format: "%.1f kWh", $0) })
                InfoRow("Akku-Temperatur", store.num(EnergyConfig.batteryTemp).map { String(format: "%.0f °C", $0) })
                if store.states[EnergyConfig.batteryLock]?.state == "on" {
                    InfoRow("Akku-Entladung", "gesperrt (EVCC)")
                }
                InfoRow("Wechselrichter", store.num(EnergyConfig.inverterTemp).map { String(format: "%.0f °C", $0) })
                InfoRow("Netzfrequenz", store.num(EnergyConfig.gridFrequency).map { String(format: "%.2f Hz", $0) })
                if volts.count == 3 {
                    InfoRow("Spannung L1/L2/L3", volts.map { "\(Int($0.rounded()))" }.joined(separator: " / ") + " V")
                }
                if phases.count == 3 {
                    InfoRow("Netz je Phase", phases.map { Fmt.watts(-$0) }.joined(separator: " / "))
                }
                InfoRow("Sonnenanteil EVCC gesamt", store.num(EnergyConfig.solarShareTotal).map { "\(Int($0.rounded())) %" })
            }
        }
    }
}

// MARK: - Bausteine

struct FlowTile: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StatBlock: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct InfoRow: View {
    let label: String
    let value: String?
    init(_ label: String, _ value: String?) { self.label = label; self.value = value }

    var body: some View {
        if let value {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.subheadline)
        }
    }
}

struct LoadpointList: View {
    @Environment(AppStore.self) private var store
    let title: String
    let symbol: String
    let items: [EnergyConfig.Loadpoint]
    let editable: Bool

    var body: some View {
        let visible = items.filter { store.states[$0.mode].map { !$0.isUnavailable } ?? false }
        Card(title: title, symbol: symbol) {
            VStack(spacing: 0) {
                ForEach(visible) { lp in
                    LoadpointRow(lp: lp, editable: editable)
                    if lp.id != visible.last?.id { Divider().padding(.vertical, 6) }
                }
                if editable {
                    Text("Aus · Sonne = nur mit PV-Überschuss · Sofort = volle Leistung")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        }
    }
}

struct LoadpointRow: View {
    @Environment(AppStore.self) private var store
    let lp: EnergyConfig.Loadpoint
    let editable: Bool

    var body: some View {
        let mode = store.states[lp.mode]?.state ?? "off"
        let kw = store.num(lp.power) ?? 0
        let active = store.states[lp.charging]?.state == "on" || kw > 0.02
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: lp.symbol)
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background(active ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(lp.name).font(.subheadline.weight(.semibold))
                    Text(active ? "läuft · \(Fmt.watts(kw * 1000))" : PoolConfig.modeLabel(mode))
                        .font(.caption).foregroundStyle(active ? Color.green : Color.secondary)
                }
                Spacer()
                if lp.id == EnergyConfig.car.id, let soc = store.num("sensor.evcc_openwb_vehicle_soc"), soc > 0 {
                    Text("\(Int(soc)) %").font(.caption.weight(.semibold))
                }
            }
            if editable {
                ModePicker(select: lp.mode, mode: mode)
            }
        }
    }
}
