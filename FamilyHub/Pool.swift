import SwiftUI
import Charts

// MARK: - Pool: Wasserwerte, Pumpe & Wärmepumpe (über EVCC), Sonnenstrom
//
// Pumpe/Wärmepumpe werden NICHT direkt geschaltet, sondern über den EVCC-Modus (off / smart / now).
// Kinder dürfen die Pumpe pausieren: script.familie_pool_pause stellt danach den vorherigen Modus wieder her.

enum PoolConfig {
    static let pumpMode = "select.evcc_pool_wasserpumpe_mode"
    static let pumpRunning = "binary_sensor.evcc_pool_wasserpumpe_charging"
    static let pumpPower = "sensor.shellyplus1pm_wasserpumpe_switch_0_power"
    static let pumpSolar = "sensor.evcc_pool_wasserpumpe_session_solar_percentage"
    static let pumpPV = "sensor.evcc_pool_wasserpumpe_pv_action_value"
    static let heatMode = "select.evcc_pool_warmepumpe_mode"
    static let heatRunning = "binary_sensor.evcc_pool_warmepumpe_charging"
    static let heatPower = "sensor.shellyplus1pm_warmepumpe_switch_0_power"
    static let heatSolar = "sensor.evcc_pool_warmepumpe_session_solar_percentage"
    static let tempIn = "sensor.pool_temperature_vorlauf"
    static let tempOut = "sensor.pool_temperature_ruecklauf"
    static let ph = "sensor.tomtut_pool_dosing_ph"
    static let redox = "sensor.tomtut_pool_dosing_redox"
    static let flow = "sensor.tomtut_pool_dosing_flow"
    static let phPump = "binary_sensor.tomtut_pool_dosing_ph_pumpe"
    static let redoxPump = "binary_sensor.tomtut_pool_dosing_redox_pumpe"
    static let uvc = "switch.pool_uvc_lampe_2"
    static let pvPower = "sensor.evcc_pv_power"
    static let batterySoc = "sensor.evcc_battery_soc"
    static let gridPower = "sensor.evcc_grid_power"
    static let pauseScript = "familie_pool_pause"

    static let phRange = 7.0...7.4          // Idealbereich
    static let redoxRange = 650.0...750.0   // mV

    static func modeLabel(_ m: String) -> String {
        ["off": "Aus", "smart": "Mit Sonnenstrom", "now": "Sofort an"][m] ?? m
    }
}

struct PoolPoint: Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

@MainActor
extension AppStore {
    func num(_ id: String) -> Double? { states[id].flatMap { Double($0.state) } }

    func poolHistory(_ entity: String, hours: Int = 24) async -> [PoolPoint] {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        guard let raw = try? await client.history(entity: entity, since: since) else { return [] }
        return raw.compactMap { p in
            guard let v = p["state"]?.string.flatMap(Double.init),
                  let t = HADate.parse(p["last_changed"]?.string ?? p["last_updated"]?.string) else { return nil }
            return PoolPoint(time: t, value: v)
        }
    }

    func setEvccMode(_ select: String, _ mode: String) async {
        do {
            _ = try await client.call("select", "select_option", ["entity_id": select, "option": mode])
            try? await Task.sleep(for: .seconds(1))
            await refreshStates()
        } catch { report(error) }
    }

    /// Pumpe für `minutes` ausschalten, danach automatisch wieder wie vorher
    func pausePoolPump(minutes: Int) async {
        let who = activeKid.flatMap { FamilyConfig.kid($0)?.name } ?? myParentID.flatMap { FamilyConfig.parent($0)?.name } ?? "Jemand"
        do {
            _ = try await client.call("script", PoolConfig.pauseScript, ["dauer": minutes, "von": who])
            try? await Task.sleep(for: .seconds(1.5))
            await refreshStates()
            if activeKid != nil {
                await notify("eltern", "🏊 Poolpumpe pausiert", "\(who) hat die Poolpumpe für \(minutes / 60) Std. ausgeschaltet.")
            }
        } catch { report(error) }
    }
}

// MARK: - Ansicht

struct PoolView: View {
    @Environment(AppStore.self) private var store
    @State private var tempHist: [PoolPoint] = []
    @State private var phHist: [PoolPoint] = []
    @State private var redoxHist: [PoolPoint] = []
    @State private var chart = "temp"

    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                waterCard
                if isParent { fillCard }
                chartCard
                pumpCard
                heatCard
                sunCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Pool")
        .refreshable { await store.refreshStates(); await loadHistory() }
        .task { await loadHistory() }
    }

    private func loadHistory() async {
        async let t = store.poolHistory(PoolConfig.tempIn)
        async let p = store.poolHistory(PoolConfig.ph)
        async let r = store.poolHistory(PoolConfig.redox)
        (tempHist, phHist, redoxHist) = await (t, p, r)
    }

    // MARK: Wasser

    private var waterCard: some View {
        let temp = store.num(PoolConfig.tempIn)
        let ph = store.num(PoolConfig.ph)
        let redox = store.num(PoolConfig.redox)
        let flowing = (store.num(PoolConfig.flow) ?? 0) > 0 || store.states[PoolConfig.pumpRunning]?.state == "on"
        return Card(title: "Wasser", symbol: "drop.fill") {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(temp.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                    Text("°C").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label(flowing ? "Wasser fließt" : "Pumpe steht", systemImage: flowing ? "arrow.triangle.2.circlepath" : "pause.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(flowing ? Color.blue : Color.secondary)
                        if store.states[PoolConfig.uvc]?.state == "on" {
                            Label("UV-C an", systemImage: "light.max").font(.caption).foregroundStyle(.purple)
                        }
                    }
                }
                if !flowing {
                    Text("Ohne Durchfluss sind Temperatur, pH und Redox nur ungefähre Werte vom letzten Umwälzen.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    PoolGauge(title: "pH", value: ph, format: "%.2f", range: 6.4...8.2, ideal: PoolConfig.phRange,
                          dosing: store.states[PoolConfig.phPump]?.state == "on")
                    PoolGauge(title: "Redox", value: redox, format: "%.0f mV", range: 450...850, ideal: PoolConfig.redoxRange,
                          dosing: store.states[PoolConfig.redoxPump]?.state == "on")
                }
            }
        }
    }

    // MARK: Verlauf

    private var chartCard: some View {
        let (points, unit, ideal): ([PoolPoint], String, ClosedRange<Double>?) = {
            switch chart {
            case "ph": return (phHist, "pH", PoolConfig.phRange)
            case "redox": return (redoxHist, "mV", PoolConfig.redoxRange)
            default: return (tempHist, "°C", nil)
            }
        }()
        return Card(title: "Letzte 24 Stunden", symbol: "chart.xyaxis.line") {
            VStack(spacing: 10) {
                Picker("Wert", selection: $chart) {
                    Text("Temperatur").tag("temp")
                    Text("pH").tag("ph")
                    Text("Redox").tag("redox")
                }
                .pickerStyle(.segmented)
                if points.count < 2 {
                    Text("Noch keine Daten").foregroundStyle(.secondary).frame(height: 160)
                } else {
                    let lo = points.map(\.value).min() ?? 0, hi = points.map(\.value).max() ?? 1
                    let pad = max((hi - lo) * 0.15, unit == "mV" ? 10 : 0.1)
                    Chart {
                        if let ideal {
                            RectangleMark(yStart: .value("von", ideal.lowerBound), yEnd: .value("bis", ideal.upperBound))
                                .foregroundStyle(Color.green.opacity(0.12))
                        }
                        ForEach(points) { p in
                            LineMark(x: .value("Zeit", p.time), y: .value(unit, p.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Color.blue)
                        }
                    }
                    .chartYScale(domain: min(lo, ideal?.lowerBound ?? lo) - pad ... max(hi, ideal?.upperBound ?? hi) + pad)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .frame(height: 170)
                    if ideal != nil {
                        Label("Grün = Idealbereich", systemImage: "square.fill")
                            .font(.caption2).foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Pumpe

    // MARK: Wasser nachfüllen (OpenSprinkler-Zone „Wassersteckdose Pool“)

    private var fillCard: some View {
        let zone = IrrigationConfig.zones.first { $0.key == "wassersteckdose_pool" }!
        let running = store.zoneIsRunning(zone) || store.zoneIsWaiting(zone)
        let end = store.zoneEnd(zone)
        return Card(title: "Wasser nachfüllen", symbol: "spigot.fill") {
            VStack(alignment: .leading, spacing: 12) {
                if running {
                    HStack(spacing: 12) {
                        Image(systemName: "drop.fill")
                            .font(.title2).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                            .symbolEffect(.pulse, isActive: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wasser läuft in den Pool").font(.headline)
                            if let end {
                                Text("noch \(end, style: .timer)").font(.subheadline.monospacedDigit()).foregroundStyle(.blue)
                            }
                        }
                        Spacer()
                    }
                    Button(role: .destructive) { Task { await store.stopZone(zone) } } label: {
                        Label("Wasser stoppen", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Text("Frischwasser über die Bewässerung einlassen – stoppt automatisch.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach([5, 10, 15, 20], id: \.self) { m in
                            Button { Task { await store.startZone(zone, minutes: m) } } label: {
                                VStack(spacing: 2) {
                                    Text("\(m)").font(.title3.weight(.bold))
                                    Text("Min").font(.caption2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }
                    }
                }
            }
        }
    }

    private var pumpCard: some View {
        let mode = store.states[PoolConfig.pumpMode]?.state ?? "off"
        let running = store.states[PoolConfig.pumpRunning]?.state == "on"
        let power = store.num(PoolConfig.pumpPower) ?? 0
        let paused = store.states["script.\(PoolConfig.pauseScript)"]?.state == "on"
        return Card(title: "Poolpumpe", symbol: "fan.fill") {
            VStack(alignment: .leading, spacing: 12) {
                DeviceStatusRow(running: running, power: power, mode: mode,
                                note: paused ? "Pausiert – schaltet sich danach wieder ein" : store.states[PoolConfig.pumpPV]?.state)
                if isParent {
                    ModePicker(select: PoolConfig.pumpMode, mode: mode)
                }
                if mode != "off" && !paused {
                    Button {
                        Task { await store.pausePoolPump(minutes: 120) }
                    } label: {
                        Label("Pumpe 2 Stunden ausschalten", systemImage: "pause.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Text("Zum Baden: Die Pumpe geht danach von selbst wieder an.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if paused {
                    Label("Pause läuft", systemImage: "hourglass").font(.subheadline).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Wärmepumpe

    private var heatCard: some View {
        let mode = store.states[PoolConfig.heatMode]?.state ?? "off"
        let running = store.states[PoolConfig.heatRunning]?.state == "on"
        let power = store.num(PoolConfig.heatPower) ?? 0
        let tin = store.num(PoolConfig.tempIn), tout = store.num(PoolConfig.tempOut)
        return Card(title: "Pool-Wärmepumpe", symbol: "thermometer.sun.fill") {
            VStack(alignment: .leading, spacing: 12) {
                DeviceStatusRow(running: running, power: power, mode: mode, note: nil)
                if let tin, let tout {
                    HStack {
                        Label(String(format: "Vorlauf %.1f °C", tin), systemImage: "arrow.right")
                        Spacer()
                        Label(String(format: "Rücklauf %.1f °C", tout), systemImage: "arrow.left")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if isParent {
                    ModePicker(select: PoolConfig.heatMode, mode: mode)
                }
            }
        }
    }

    // MARK: Sonnenstrom

    private var sunCard: some View {
        let pv = store.num(PoolConfig.pvPower) ?? 0
        let soc = store.num(PoolConfig.batterySoc)
        let grid = store.num(PoolConfig.gridPower) ?? 0
        return Card(title: "Sonnenstrom", symbol: "sun.max.fill") {
            HStack {
                SunStat(symbol: "sun.max.fill", color: .yellow, value: pv >= 1000 ? String(format: "%.1f kW", pv / 1000) : "\(Int(pv)) W", label: "PV")
                SunStat(symbol: "battery.75", color: .green, value: soc.map { "\(Int($0)) %" } ?? "–", label: "Akku")
                SunStat(symbol: grid > 50 ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                        color: grid > 50 ? .red : .blue,
                        value: "\(Int(abs(grid))) W", label: grid > 50 ? "aus dem Netz" : "ins Netz")
            }
        }
    }
}

// MARK: - Bausteine

struct PoolGauge: View {
    let title: String
    let value: Double?
    let format: String
    let range: ClosedRange<Double>
    let ideal: ClosedRange<Double>
    let dosing: Bool

    private var color: Color {
        guard let v = value else { return .gray }
        if ideal.contains(v) { return .green }
        let dist = min(abs(v - ideal.lowerBound), abs(v - ideal.upperBound))
        return dist < (ideal.upperBound - ideal.lowerBound) * 0.6 ? .orange : .red
    }
    private var verdict: String {
        guard let v = value else { return "keine Daten" }
        if ideal.contains(v) { return "ideal" }
        return v < ideal.lowerBound ? "zu niedrig" : "zu hoch"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if dosing {
                    Label("dosiert", systemImage: "syringe.fill").font(.caption2).foregroundStyle(.purple)
                }
            }
            Text(value.map { String(format: format, $0) } ?? "–")
                .font(.title2.weight(.bold).monospacedDigit())
            GeometryReader { geo in
                let w = geo.size.width
                let pos: (Double) -> CGFloat = { CGFloat(($0 - range.lowerBound) / (range.upperBound - range.lowerBound)) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 8)
                    Capsule().fill(Color.green.opacity(0.35))
                        .frame(width: max(pos(ideal.upperBound) - pos(ideal.lowerBound), 4), height: 8)
                        .offset(x: pos(ideal.lowerBound))
                    if let v = value {
                        Circle().fill(color).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .offset(x: min(max(pos(v), 0), w) - 7)
                    }
                }
            }
            .frame(height: 14)
            Text(verdict).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct DeviceStatusRow: View {
    let running: Bool
    let power: Double
    let mode: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(running ? Color.green : Color.gray).frame(width: 10, height: 10)
                Text(running ? "Läuft" : "Aus").font(.headline)
                if running { Text("· \(Int(power)) W").foregroundStyle(.secondary) }
                Spacer()
                Text(PoolConfig.modeLabel(mode))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            if let note, !note.isEmpty, !["unknown", "unavailable"].contains(note) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ModePicker: View {
    @Environment(AppStore.self) private var store
    let select: String
    let mode: String

    var body: some View {
        Picker("Modus", selection: Binding(get: { mode }, set: { new in Task { await store.setEvccMode(select, new) } })) {
            Text("Aus").tag("off")
            Text("Sonne").tag("smart")
            Text("Sofort").tag("now")
        }
        .pickerStyle(.segmented)
    }
}

struct SunStat: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
