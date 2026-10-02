import SwiftUI

// MARK: - Rauchmelder (Develco über Zigbee2MQTT) und Zigbee-Geräteübersicht

enum SmokeConfig {
    struct Detector: Identifiable {
        let key: String
        let name: String
        var id: String { key }
        var smoke: String { "binary_sensor.rauchmelder_\(key)_smoke" }
        var battery: String { "sensor.rauchmelder_\(key)_battery" }
        var batteryLow: String { "binary_sensor.rauchmelder_\(key)_battery_low" }
        var fault: String { "binary_sensor.rauchmelder_\(key)_fault" }
        var test: String { "binary_sensor.rauchmelder_\(key)_test" }
        var temperature: String { "sensor.rauchmelder_\(key)_temperature" }
        var siren: String { "switch.rauchmelder_\(key)_alarm" }
    }
    static let detectors: [Detector] = [
        Detector(key: "flur_keller", name: "Flur Keller"),
        Detector(key: "technikraum", name: "Technikraum"),
        Detector(key: "flur_eg", name: "Flur EG"),
        Detector(key: "wohnzimmer", name: "Wohnzimmer"),
        Detector(key: "speisekammer", name: "Speisekammer"),
        Detector(key: "flur_og", name: "Flur OG"),
        Detector(key: "schlafzimmer", name: "Schlafzimmer"),
        Detector(key: "jan", name: "Jan"),
        Detector(key: "vanessa", name: "Vanessa"),
        Detector(key: "emma", name: "Emma"),
        Detector(key: "leoni", name: "Leoni"),
    ]
    static let zigbeeScript = "familie_zigbee"
}

enum SmokeState { case alarm, offline, fault, lowBattery, ok }

struct ZigbeeDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let maker: String
    let room: String
    let battery: Double?
    let batteryLow: Bool
    let offline: Bool
    let linkQuality: Int?
    var hasProblem: Bool { offline || batteryLow || (battery ?? 100) <= 20 }
    static let noRoom = "Ohne Raum"
}

@MainActor
extension AppStore {
    func smokeState(_ d: SmokeConfig.Detector) -> SmokeState {
        let s = states[d.smoke]?.state
        if s == "on" { return .alarm }
        if s == nil || s == "unavailable" { return .offline }
        if states[d.fault]?.state == "on" { return .fault }
        if states[d.batteryLow]?.state == "on" || (num(d.battery) ?? 100) <= 20 { return .lowBattery }
        return .ok
    }

    var smokeAlarm: [SmokeConfig.Detector] { SmokeConfig.detectors.filter { smokeState($0) == .alarm } }
    var smokeProblems: [SmokeConfig.Detector] {
        SmokeConfig.detectors.filter { [.offline, .fault, .lowBattery].contains(smokeState($0)) }
    }

    func loadZigbee() async -> (devices: [ZigbeeDevice], bridgeOnline: Bool)? {
        guard let r = try? await client.callWithResponse("script", SmokeConfig.zigbeeScript, [:], timeout: 40) else { return nil }
        let list = r["geraete"]?.array ?? []
        let devices: [ZigbeeDevice] = list.compactMap { d in
            guard let id = d["id"]?.string else { return nil }
            return ZigbeeDevice(id: id, name: d["name"]?.string ?? "Gerät", model: d["model"]?.string ?? "",
                                maker: d["hersteller"]?.string ?? "", room: d["raum"]?.string ?? ZigbeeDevice.noRoom,
                                battery: d["akku"]?.double, batteryLow: d["akku_schwach"]?.string == "true",
                                offline: d["offline"]?.string == "true", linkQuality: d["lq"]?.int)
        }
        return (devices.sorted { $0.name < $1.name }, r["bridge"]?.string == "on")
    }

    /// Bereiche (Räume) aus Home Assistant, alphabetisch
    func loadAreas() async throws -> [(id: String, name: String)] {
        let list = try await client.websocket(["type": "config/area_registry/list"]).array ?? []
        return list.compactMap { a -> (id: String, name: String)? in
            guard let id = a["area_id"]?.string, let n = a["name"]?.string else { return nil }
            return (id, n)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func setDeviceArea(_ device: String, area: String?) async throws {
        _ = try await client.websocket(["type": "config/device_registry/update", "device_id": device,
                                        "area_id": area ?? NSNull()])
    }
}

// MARK: - Rauchmelder

struct SmokeView: View {
    @Environment(AppStore.self) private var store
    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                summary
                Card(title: "Alle Rauchmelder", symbol: "smoke.fill") {
                    VStack(spacing: 0) {
                        ForEach(SmokeConfig.detectors) { d in
                            SmokeRow(detector: d, editable: isParent)
                            if d.id != SmokeConfig.detectors.last?.id { Divider().padding(.vertical, 8) }
                        }
                    }
                }
                if isParent {
                    NavigationLink { DevicesView() } label: {
                        Label("Alle Zigbee-Geräte ansehen", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Bei Rauch bekommen alle vier Handys eine kritische Mitteilung – auch wenn sie lautlos sind.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Rauchmelder")
        .refreshable { await store.refreshStates() }
    }

    private var summary: some View {
        let alarm = store.smokeAlarm
        let problems = store.smokeProblems
        let color: Color = !alarm.isEmpty ? .red : (problems.isEmpty ? .green : .orange)
        return HStack(spacing: 14) {
            Image(systemName: !alarm.isEmpty ? "flame.fill" : (problems.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill"))
                .font(.system(size: 30)).foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 16))
                .symbolEffect(.pulse, isActive: !alarm.isEmpty)
            VStack(alignment: .leading, spacing: 3) {
                if !alarm.isEmpty {
                    Text("RAUCH – \(alarm.map(\.name).joined(separator: ", "))").font(.title3.weight(.bold)).foregroundStyle(.red)
                } else if problems.isEmpty {
                    Text("Alles in Ordnung").font(.title3.weight(.bold))
                    Text("\(SmokeConfig.detectors.count) Rauchmelder bereit").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(problems.count) \(problems.count == 1 ? "Rauchmelder braucht" : "Rauchmelder brauchen") Aufmerksamkeit")
                        .font(.headline)
                    Text(problems.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SmokeRow: View {
    @Environment(AppStore.self) private var store
    let detector: SmokeConfig.Detector
    let editable: Bool

    var body: some View {
        let st = store.smokeState(detector)
        let battery = store.num(detector.battery)
        let temp = store.num(detector.temperature)
        let sirenOn = store.states[detector.siren]?.state == "on"
        HStack(spacing: 12) {
            Image(systemName: icon(st))
                .font(.title3)
                .foregroundStyle(color(st))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(detector.name).font(.subheadline.weight(.semibold))
                Text(text(st)).font(.caption).foregroundStyle(st == .ok ? Color.secondary : color(st))
            }
            Spacer()
            if let temp, st != .offline {
                Text(String(format: "%.0f°", temp)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let battery {
                BatteryBadge(percent: battery)
            }
            if editable && (st == .alarm || sirenOn) {
                Button { Task { await store.setSwitch(detector.siren, false) } } label: {
                    Label("Sirene aus", systemImage: "speaker.slash.fill").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
    }

    private func icon(_ s: SmokeState) -> String {
        switch s {
        case .alarm: "flame.fill"
        case .offline: "wifi.slash"
        case .fault: "exclamationmark.triangle.fill"
        case .lowBattery: "battery.25percent"
        case .ok: "checkmark.circle.fill"
        }
    }
    private func color(_ s: SmokeState) -> Color {
        switch s {
        case .alarm: .red
        case .offline, .fault: .orange
        case .lowBattery: .yellow
        case .ok: .green
        }
    }
    private func text(_ s: SmokeState) -> String {
        switch s {
        case .alarm: "RAUCH ERKANNT"
        case .offline: "Nicht erreichbar – kann keinen Alarm melden"
        case .fault: "Störung"
        case .lowBattery: "Batterie bald wechseln"
        case .ok: "Bereit"
        }
    }
}

struct BatteryBadge: View {
    let percent: Double

    var body: some View {
        let c: Color = percent <= 20 ? .red : (percent <= 40 ? .orange : .green)
        HStack(spacing: 3) {
            Image(systemName: percent <= 20 ? "battery.25percent" : (percent <= 60 ? "battery.50percent" : "battery.100percent"))
            Text("\(Int(percent)) %").monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(c)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(c.opacity(0.12), in: Capsule())
    }
}

// MARK: - Zigbee-Geräte

struct DevicesView: View {
    @Environment(AppStore.self) private var store
    @State private var devices: [ZigbeeDevice] = []
    @State private var bridgeOnline = true
    @State private var loading = true
    @State private var filter = "probleme"
    @State private var search = ""
    @State private var showJoin = false
    @State private var unnamed = 0
    @State private var moving: ZigbeeDevice?

    private var shown: [ZigbeeDevice] {
        var list = devices
        switch filter {
        case "probleme": list = list.filter(\.hasProblem)
        case "akku": list = list.filter { $0.battery != nil || $0.batteryLow }.sorted { ($0.battery ?? 0) < ($1.battery ?? 0) }
        default: break
        }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.room.localizedCaseInsensitiveContains(search) } }
        return list
    }
    private var rooms: [String] {
        if filter == "akku" { return [""] }
        // „Ohne Raum“ immer ans Ende
        return Array(Set(shown.map(\.room))).sorted {
            ($0 == ZigbeeDevice.noRoom ? 1 : 0, $0) < ($1 == ZigbeeDevice.noRoom ? 1 : 0, $1)
        }
    }
    private var canJoin: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        List {
            Section {
                HStack {
                    StatBlock(value: "\(devices.count)", label: "Geräte", color: .blue)
                    StatBlock(value: "\(devices.filter(\.offline).count)", label: "offline", color: .orange)
                    StatBlock(value: "\(devices.filter { !$0.offline && ($0.batteryLow || ($0.battery ?? 100) <= 20) }.count)", label: "Akku schwach", color: .red)
                }
                if !bridgeOnline {
                    Label("Zigbee2MQTT ist nicht verbunden!", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Picker("Anzeige", selection: $filter) {
                    Text("Probleme").tag("probleme")
                    Text("Akkus").tag("akku")
                    Text("Alle").tag("alle")
                }
                .pickerStyle(.segmented)
            }
            if canJoin && unnamed > 0 {
                Section {
                    Button { showJoin = true } label: {
                        Label(unnamed == 1 ? "1 neues Gerät hat noch keinen Namen" : "\(unnamed) neue Geräte haben noch keinen Namen",
                              systemImage: "sparkles")
                            .foregroundStyle(.purple)
                    }
                }
            }
            if loading && devices.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if shown.isEmpty {
                Section { Label("Keine Probleme – alle Geräte erreichbar", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            ForEach(rooms, id: \.self) { room in
                Section(room) {
                    ForEach(filter == "akku" ? shown : shown.filter { $0.room == room }) { d in
                        if store.isAdmin {
                            Button { moving = d } label: { DeviceRow(device: d) }
                                .foregroundStyle(.primary)
                        } else {
                            DeviceRow(device: d)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Gerät oder Raum")
        .navigationTitle("Zigbee-Geräte")
        .toolbar {
            if canJoin {
                ToolbarItem(placement: .primaryAction) {
                    Button { showJoin = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Neues Gerät anlernen")
                }
            }
        }
        .sheet(isPresented: $showJoin, onDismiss: { Task { await load() } }) {
            NavigationStack {
                List { ZigbeeJoinSection() }
                    .navigationTitle("Neues Gerät")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showJoin = false } } }
            }
        }
        .sheet(item: $moving, onDismiss: { Task { await load() } }) { d in
            ZigbeeRoomPicker(device: d)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        if let r = await store.loadZigbee() {
            devices = r.devices
            bridgeOnline = r.bridgeOnline
        }
        if canJoin, let l = try? await store.loadNewZigbee() {
            unnamed = l.filter(\.unnamed).count
        }
        loading = false
    }
}

/// Raum (Bereich in Home Assistant) eines Zigbee-Geräts ändern – nur Jan
struct ZigbeeRoomPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let device: ZigbeeDevice
    @State private var areas: [(id: String, name: String)] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.headline)
                        Text([device.maker, device.model].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("Raum") {
                    if areas.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(areas, id: \.id) { a in
                        Button { set(a.id) } label: {
                            HStack {
                                Text(a.name).foregroundStyle(.primary)
                                Spacer()
                                if a.name == device.room { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }
                    }
                    if device.room != ZigbeeDevice.noRoom {
                        Button("Ohne Raum", role: .destructive) { set(nil) }
                    }
                }
            }
            .disabled(busy)
            .navigationTitle("In welchen Raum?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task {
                if let l = try? await store.loadAreas() { areas = l }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func set(_ area: String?) {
        busy = true
        Task {
            do {
                try await store.setDeviceArea(device.id, area: area)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct DeviceRow: View {
    let device: ZigbeeDevice

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(device.offline ? Color.orange : Color.green).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.subheadline.weight(.medium))
                Text([device.offline ? "nicht erreichbar" : nil, device.model.isEmpty ? nil : device.model]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(device.offline ? Color.orange : Color.secondary).lineLimit(1)
            }
            Spacer()
            if let b = device.battery {
                BatteryBadge(percent: b)
            } else if device.batteryLow {
                Label("schwach", systemImage: "battery.25percent").font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Karte auf „Heute“ (nur bei Alarm oder Problemen)

struct SafetyTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let alarm = store.smokeAlarm
        let problems = store.smokeProblems
        if !alarm.isEmpty || !problems.isEmpty {
            NavigationLink { SmokeView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: alarm.isEmpty ? "exclamationmark.shield.fill" : "flame.fill")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background((alarm.isEmpty ? Color.orange : Color.red).gradient, in: RoundedRectangle(cornerRadius: 12))
                        .symbolEffect(.pulse, isActive: !alarm.isEmpty)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alarm.isEmpty ? "Rauchmelder prüfen" : "RAUCHALARM").font(.headline)
                            .foregroundStyle(alarm.isEmpty ? Color.primary : Color.red)
                        Text((alarm.isEmpty ? problems : alarm).map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
    }
}
