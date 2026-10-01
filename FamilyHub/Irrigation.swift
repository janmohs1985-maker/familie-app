import SwiftUI

// MARK: - Bewässerung (OpenSprinkler)

enum IrrigationConfig {
    struct Zone: Identifiable {
        let name: String
        let symbol: String
        let key: String          // Präfix der Status-/Running-Sensoren
        let switchKey: String    // Präfix des Station-Schalters (weicht teils ab)
        var id: String { key }
        var status: String { "sensor.\(key)_station_status" }
        var running: String { "binary_sensor.\(switchKey)_station_running" }
        var enabled: String { "switch.\(switchKey)_station_enabled" }
    }
    static let zones: [Zone] = [
        Zone(name: "Sprinkler Süd", symbol: "sprinkler.and.droplets.fill", key: "sprinkler_sud", switchKey: "sprinkler_sud"),
        Zone(name: "Sprinkler West", symbol: "sprinkler.and.droplets.fill", key: "sprinkler_west", switchKey: "sprinkler_west"),
        Zone(name: "Sprinkler Weg", symbol: "sprinkler.and.droplets.fill", key: "sprinkler_weg", switchKey: "s06"),
        Zone(name: "Blumenbeet hinten (Tropfer)", symbol: "drop.fill", key: "microdrip_blumenbeet_hinten", switchKey: "microdrip_blumenbeet_hinten"),
        Zone(name: "Baum Katalpa", symbol: "tree.fill", key: "baum_katalpa", switchKey: "geht"),
        Zone(name: "Wassersteckdose Pool", symbol: "spigot.fill", key: "wassersteckdose_pool", switchKey: "wassersteckdose_pool"),
        Zone(name: "Wassersteckdose Einfahrt", symbol: "spigot.fill", key: "wassersteckdose_einfahrt", switchKey: "wassersteckdose_einfahrt"),
        Zone(name: "Wassersteckdose Garage", symbol: "spigot.fill", key: "wassersteckdose_garage", switchKey: "wassersteckdose_garage"),
    ]
    static let controller = "switch.opensprinkler_enabled"
    static let rainDelay = "binary_sensor.opensprinkler_rain_delay_active"
    static let rainDelayEnd = "sensor.opensprinkler_rain_delay_stop_time"
    static let paused = "binary_sensor.opensprinkler_paused"
    static let waterLevel = "sensor.opensprinkler_water_level"
    static let lastRun = "sensor.opensprinkler_last_run"
    static let nextRun = "sensor.garten_opensprinkler_next_run"
    static let weatherRestriction = "binary_sensor.garten_opensprinkler_weather_restriction_active"

    static let durations = [5, 10, 15, 20, 30, 45, 60]
}

@MainActor
extension AppStore {
    func zoneIsRunning(_ z: IrrigationConfig.Zone) -> Bool {
        if states[z.running]?.state == "on" { return true }
        let s = states[z.status]?.state ?? "idle"
        return !["idle", "disabled", "waiting", "unknown", "unavailable"].contains(s)
    }
    func zoneIsWaiting(_ z: IrrigationConfig.Zone) -> Bool { states[z.status]?.state == "waiting" }

    func zoneEnd(_ z: IrrigationConfig.Zone) -> Date? {
        HADate.parse(states[z.status]?.attr("end_time")?.string ?? states[z.running]?.attr("end_time")?.string)
    }

    var anyZoneRunning: Bool { IrrigationConfig.zones.contains { zoneIsRunning($0) || zoneIsWaiting($0) } }

    private func sprinkler(_ service: String, _ data: [String: Any]) async {
        do {
            _ = try await client.call("opensprinkler", service, data)
            for _ in 0..<3 {                       // OpenSprinkler meldet den neuen Zustand mit etwas Verzögerung
                try? await Task.sleep(for: .seconds(2))
                await refreshStates()
            }
        } catch { report(error) }
    }

    func startZone(_ z: IrrigationConfig.Zone, minutes: Int) async {
        await IrrigationLive.start(zone: z.name, symbol: z.symbol, minutes: minutes)
        await sprinkler("run", ["entity_id": z.enabled, "run_seconds": minutes * 60])
    }
    func stopZone(_ z: IrrigationConfig.Zone) async {
        await sprinkler("stop", ["entity_id": z.enabled])
        await IrrigationLive.endAll()
    }
    func stopAllZones() async {
        await sprinkler("stop", ["entity_id": IrrigationConfig.controller])
        await IrrigationLive.endAll()
    }
    func setRainDelay(hours: Int) async {
        await sprinkler("set_rain_delay", ["entity_id": IrrigationConfig.controller, "rain_delay": hours])
    }
}

struct IrrigationView: View {
    @Environment(AppStore.self) private var store
    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                statusCard
                zonesCard
                infoCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bewässerung")
        .refreshable { await store.refreshStates() }
        .toolbar {
            if isParent && store.anyZoneRunning {
                Button(role: .destructive) { Task { await store.stopAllZones() } } label: {
                    Label("Alle stoppen", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let enabled = store.states[IrrigationConfig.controller]?.state == "on"
        let rain = store.states[IrrigationConfig.rainDelay]?.state == "on"
        let rainEnd = HADate.parse(store.states[IrrigationConfig.rainDelayEnd]?.state)
        let paused = store.states[IrrigationConfig.paused]?.state == "on"
        let level = store.num(IrrigationConfig.waterLevel)
        let running = IrrigationConfig.zones.filter { store.zoneIsRunning($0) }
        return Card(title: "OpenSprinkler", symbol: "sprinkler.and.droplets.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: running.isEmpty ? "drop" : "drop.fill")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background((running.isEmpty ? Color.gray : Color.blue).gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        if let z = running.first {
                            Text("\(z.name) läuft").font(.headline)
                            if let end = store.zoneEnd(z) {
                                Text("noch \(end, style: .timer)").font(.caption.monospacedDigit()).foregroundStyle(.blue)
                            }
                        } else {
                            Text(!enabled ? "Bewässerung ausgeschaltet" : (rain ? "Regenpause" : (paused ? "Pausiert" : "Alles aus")))
                                .font(.headline)
                            if rain, let rainEnd {
                                Text("bis \(rainEnd.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let level {
                                Text("Wetteranpassung \(Int(level)) %").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                if isParent {
                    Toggle(isOn: Binding(get: { enabled },
                                         set: { v in Task { await store.setSwitch(IrrigationConfig.controller, v) } })) {
                        Label("Automatik (Programme) aktiv", systemImage: "calendar.badge.clock")
                    }
                    .font(.subheadline)
                    HStack {
                        Label("Regenpause", systemImage: "cloud.rain.fill").font(.subheadline)
                        Spacer()
                        Menu {
                            ForEach([24, 48, 72, 168], id: \.self) { h in
                                Button(h == 168 ? "1 Woche" : "\(h) Stunden") { Task { await store.setRainDelay(hours: h) } }
                            }
                            if rain {
                                Button("Regenpause beenden", role: .destructive) { Task { await store.setRainDelay(hours: 0) } }
                            }
                        } label: {
                            Text(rain ? "aktiv" : "aus").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(rain ? AnyShapeStyle(Color.blue.opacity(0.2)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: Zonen

    private var zonesCard: some View {
        Card(title: "Zonen", symbol: "square.grid.2x2.fill") {
            VStack(spacing: 0) {
                ForEach(IrrigationConfig.zones) { z in
                    ZoneRow(zone: z, editable: isParent)
                    if z.id != IrrigationConfig.zones.last?.id { Divider().padding(.vertical, 8) }
                }
            }
        }
    }

    // MARK: Info

    @ViewBuilder private var infoCard: some View {
        let last = store.states[IrrigationConfig.lastRun]
        let lastDate = HADate.parse(last?.state)
        let lastIdx = last?.attr("last_run_station")?.int
        let lastDur = last?.attr("last_run_duration")?.int
        let next = store.states[IrrigationConfig.nextRun]
        let nextDate = HADate.parse(next?.state)
        if lastDate != nil || nextDate != nil {
            Card(title: "Verlauf", symbol: "clock.arrow.circlepath") {
                VStack(spacing: 8) {
                    if let lastDate {
                        let name = lastIdx.flatMap { i in IrrigationConfig.zones.first { store.states[$0.status]?.attr("index")?.int == i }?.name }
                        InfoRow("Zuletzt", [name, lastDur.map { "\($0 / 60) min" },
                                            lastDate.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let nextDate {
                        InfoRow("Nächster Lauf", [next?.attr("next_run_station_name")?.string,
                                                  nextDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())].compactMap { $0 }.joined(separator: " · "))
                    }
                    if store.states[IrrigationConfig.weatherRestriction]?.state == "on" {
                        InfoRow("Wetter", "Bewässerung wegen Wetter eingeschränkt")
                    }
                }
            }
        }
    }
}

struct ZoneRow: View {
    @Environment(AppStore.self) private var store
    let zone: IrrigationConfig.Zone
    let editable: Bool

    var body: some View {
        let running = store.zoneIsRunning(zone)
        let waiting = store.zoneIsWaiting(zone)
        let disabled = store.states[zone.enabled]?.state == "off"
        HStack(spacing: 12) {
            Image(systemName: zone.symbol)
                .foregroundStyle(running ? Color.white : (disabled ? Color.secondary : Color.blue))
                .frame(width: 34, height: 34)
                .background(running ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(Color.blue.opacity(0.1)),
                            in: RoundedRectangle(cornerRadius: 9))
                .symbolEffect(.pulse, isActive: running)
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.name).font(.subheadline.weight(.semibold))
                Group {
                    if running, let end = store.zoneEnd(zone) {
                        Text("läuft · noch \(end, style: .timer)").foregroundStyle(.blue)
                    } else if running {
                        Text("läuft").foregroundStyle(.blue)
                    } else if waiting {
                        Text("wartet").foregroundStyle(.orange)
                    } else if disabled {
                        Text("deaktiviert").foregroundStyle(.secondary)
                    } else {
                        Text("aus").foregroundStyle(.secondary)
                    }
                }
                .font(.caption.monospacedDigit())
            }
            Spacer()
            if editable && !disabled {
                if running || waiting {
                    Button { Task { await store.stopZone(zone) } } label: {
                        Label("Stopp", systemImage: "stop.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Menu {
                        ForEach(IrrigationConfig.durations, id: \.self) { m in
                            Button("\(m) Minuten") { Task { await store.startZone(zone, minutes: m) } }
                        }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(.white)
                            .background(Color.blue.gradient, in: Capsule())
                    }
                }
            }
        }
    }
}
