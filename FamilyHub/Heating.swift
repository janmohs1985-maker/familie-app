import SwiftUI

// MARK: - Heizung: Proxon (Räume, Warmwasser, Heizstab, Lüftung) + Elektro-Heizkörper über EVCC

enum HeatingConfig {
    struct Room: Identifiable {
        let key: String          // für climate/switch-Namen
        let elementKey: String   // Heizelement-Namen weichen beim Flur ab
        let name: String
        let kid: String?         // Kind darf sein eigenes Zimmer einstellen
        var id: String { key }
        var climate: String { "climate.proxon_template_heizung_\(key)" }
        var current: String { "sensor.proxon_ist_temperatur_\(key)" }
        var elementOn: String { "sensor.proxon_heizelement_status_\(elementKey)" }
        var elementSwitch: String { "switch.proxon_heizelement_\(elementKey)" }
        var keyLock: String { "switch.proxon_tastensperre_\(elementKey)" }
    }
    static let rooms: [Room] = [
        Room(key: "wohnzimmer", elementKey: "wohnzimmer", name: "Wohnzimmer", kid: nil),
        Room(key: "eg_flur", elementKey: "flur", name: "Flur EG", kid: nil),
        Room(key: "schlafzimmer", elementKey: "schlafzimmer", name: "Schlafzimmer", kid: nil),
        Room(key: "jan", elementKey: "jan", name: "Jan", kid: nil),
        Room(key: "vanessa", elementKey: "vanessa", name: "Vanessa", kid: nil),
        Room(key: "emma", elementKey: "emma", name: "Emma", kid: "emma"),
        Room(key: "leoni", elementKey: "leoni", name: "Leoni", kid: "leoni"),
    ]

    static let mode = "input_select.proxon_betriebsart_select"
    static let fan = "input_select.proxon_luefterstufe_select"
    static let compressor = "binary_sensor.proxon_kompressor_status"
    static let heaterRunning = "binary_sensor.proxon_heizstab_status"
    static let heaterSwitch = "switch.proxon_heizstab"
    static let heaterRelease = "input_number.proxon_sollwert_freigabe_heizstab_slider"
    static let waterTop = "sensor.proxon_ist_temperatur_wasser"
    static let waterBottom = "sensor.proxon_temperatur_wasser_unten"
    static let waterTarget = "input_number.proxon_sollwert_wassertemperatur_slider"
    static let elementsGlobal = "switch.proxon_heizelemente_global"
    static let cooling = "switch.proxon_kuehlung"
    static let freshAir = "sensor.proxon_temperatur_frischluft"
    static let supplyAir = "sensor.proxon_temperatur_zuluft"
    static let extractAir = "sensor.proxon_temperatur_abluft"
    static let exhaustAir = "sensor.proxon_temperatur_fortluft"
    static let humidity = "sensor.proxon_luftfeuchte_wohnzimmer"
    static let filterDays = "sensor.proxon_filter_resttage"
    static let intensiveLeft = "sensor.proxon_intensivluftung_restzeit"

    static func modeShort(_ m: String) -> String {
        switch m {
        case "Sommerbetrieb": "Sommer"
        case "Winterbetrieb": "Winter"
        case "ECO Komfortbetrieb": "ECO Komfort"
        case "Ofenbetrieb": "Ofen"
        default: m
        }
    }

    static func modeSymbol(_ m: String) -> String {
        switch m {
        case "Aus": "power"
        case "Sommerbetrieb": "sun.max.fill"
        case "Winterbetrieb": "snowflake"
        case "Ofenbetrieb": "flame.fill"
        default: "leaf.fill"
        }
    }
}

@MainActor
extension AppStore {
    func setRoomTemp(_ room: HeatingConfig.Room, _ temp: Double) async {
        do {
            _ = try await client.call("climate", "set_temperature", ["entity_id": room.climate, "temperature": temp])
            try? await Task.sleep(for: .milliseconds(600))
            await refreshStates()
        } catch { report(error) }
    }

    func setRoomHvac(_ room: HeatingConfig.Room, _ mode: String) async {
        do {
            _ = try await client.call("climate", "set_hvac_mode", ["entity_id": room.climate, "hvac_mode": mode])
            try? await Task.sleep(for: .milliseconds(600))
            await refreshStates()
        } catch { report(error) }
    }

    func selectOption(_ entity: String, _ option: String) async {
        let domain = entity.components(separatedBy: ".").first ?? "input_select"
        do {
            _ = try await client.call(domain, "select_option", ["entity_id": entity, "option": option])
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStates()
        } catch { report(error) }
    }

    func setNumber(_ entity: String, _ value: Double) async {
        let domain = entity.components(separatedBy: ".").first ?? "input_number"
        do {
            _ = try await client.call(domain, "set_value", ["entity_id": entity, "value": value])
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStates()
        } catch { report(error) }
    }

    func canAdjust(_ room: HeatingConfig.Room) -> Bool {
        if let kid = activeKid { return room.kid == kid }
        return isParent
    }
}

struct HeatingView: View {
    @Environment(AppStore.self) private var store
    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                statusCard
                roomsCard
                waterCard
                if isParent {
                    LoadpointList(title: "Elektro-Heizkörper über EVCC", symbol: "heater.vertical.fill",
                                  items: EnergyConfig.heaters, editable: true)
                }
                airCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heizung")
        .refreshable { await store.refreshStates() }
    }

    // MARK: Status

    private var statusCard: some View {
        let mode = store.states[HeatingConfig.mode]?.state ?? "–"
        let options = store.states[HeatingConfig.mode]?.attr("options")?.array?.compactMap(\.string) ?? []
        let compressor = store.states[HeatingConfig.compressor]?.state == "on"
        let outside = store.num(HeatingConfig.freshAir)
        return Card(title: "Proxon", symbol: "heat.waves") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: HeatingConfig.modeSymbol(mode))
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode).font(.headline)
                        Label(compressor ? "Wärmepumpe läuft" : "Wärmepumpe in Pause",
                              systemImage: compressor ? "fan.fill" : "pause.circle")
                            .font(.caption).foregroundStyle(compressor ? Color.green : Color.secondary)
                    }
                    Spacer()
                    if let outside {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(String(format: "%.1f°", outside)).font(.title3.weight(.bold))
                            Text("draußen").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if isParent && !options.isEmpty {
                    Text("Betriebsart").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(options, id: \.self) { o in
                            let on = o == mode
                            Button { if !on { Task { await store.selectOption(HeatingConfig.mode, o) } } } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: HeatingConfig.modeSymbol(o)).font(.title3)
                                    Text(HeatingConfig.modeShort(o)).font(.caption2.weight(.semibold)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Toggle(isOn: Binding(get: { store.states[HeatingConfig.elementsGlobal]?.state == "on" },
                                             set: { v in Task { await store.setSwitch(HeatingConfig.elementsGlobal, v) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Label("Wärmeelemente (alle)", systemImage: "flame")
                                Text("Hauptschalter – einzelne Räume unten bei „Räume“")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(isOn: Binding(get: { store.states[HeatingConfig.cooling]?.state == "on" },
                                         set: { v in Task { await store.setSwitch(HeatingConfig.cooling, v) } })) {
                        Label("Kühlung", systemImage: "snowflake")
                    }
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: Räume

    private var roomsCard: some View {
        Card(title: "Räume", symbol: "thermometer.medium") {
            VStack(spacing: 0) {
                ForEach(HeatingConfig.rooms) { room in
                    RoomRow(room: room, editable: store.canAdjust(room), parent: isParent)
                    if room.id != HeatingConfig.rooms.last?.id { Divider().padding(.vertical, 8) }
                }
            }
        }
    }

    // MARK: Warmwasser

    private var waterCard: some View {
        let top = store.num(HeatingConfig.waterTop)
        let bottom = store.num(HeatingConfig.waterBottom)
        let target = store.num(HeatingConfig.waterTarget) ?? 50
        let release = store.num(HeatingConfig.heaterRelease) ?? 70
        let heaterOn = store.states[HeatingConfig.heaterRunning]?.state == "on"
        let heaterEnabled = store.states[HeatingConfig.heaterSwitch]?.state == "on"
        return Card(title: "Warmwasser", symbol: "shower.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(top.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("°C").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Soll \(Int(target)) °C").font(.caption.weight(.semibold))
                        if let bottom { Text(String(format: "unten %.0f °C", bottom)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let top {
                    ProgressView(value: min(max(top - 30, 0), 30), total: 30)
                        .tint(top >= target - 3 ? .red : .orange)
                    Text(top >= target - 3 ? "Warm genug zum Duschen und Baden." : (top >= 40 ? "Reicht zum Duschen, wird gerade nachgeheizt." : "Eher knapp – lieber etwas warten."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Label(heaterOn ? "Heizstab heizt" : (heaterEnabled ? "Heizstab bereit" : "Heizstab aus"),
                          systemImage: heaterOn ? "bolt.fill" : "bolt.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(heaterOn ? Color.red : Color.secondary)
                    Spacer()
                }
                if isParent {
                    Toggle(isOn: Binding(get: { heaterEnabled },
                                         set: { v in Task { await store.setSwitch(HeatingConfig.heaterSwitch, v) } })) {
                        Label("Heizstab freigeben", systemImage: "bolt.fill")
                    }
                    Stepper(value: Binding(get: { target }, set: { v in Task { await store.setNumber(HeatingConfig.waterTarget, v) } }),
                            in: 40...55, step: 1) {
                        Text("Wunsch-Temperatur: \(Int(target)) °C")
                    }
                    Stepper(value: Binding(get: { release }, set: { v in Task { await store.setNumber(HeatingConfig.heaterRelease, v) } }),
                            in: 40...70, step: 1) {
                        Text("Heizstab bis: \(Int(release)) °C")
                    }
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: Lüftung

    private var airCard: some View {
        let fresh = store.num(HeatingConfig.freshAir)
        let supply = store.num(HeatingConfig.supplyAir)
        let extract = store.num(HeatingConfig.extractAir)
        let exhaust = store.num(HeatingConfig.exhaustAir)
        let recovery: Double? = {
            guard let f = fresh, let s = supply, let e = extract, e - f > 2 else { return nil }
            return max(0, min(1, (s - f) / (e - f)))
        }()
        let stage = store.states[HeatingConfig.fan]?.state ?? "–"
        let filter = store.num(HeatingConfig.filterDays)
        return Card(title: "Lüftung", symbol: "wind") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        AirTemp(label: "Außenluft", value: fresh, symbol: "arrow.down.right", color: .blue)
                        AirTemp(label: "Zuluft (in die Räume)", value: supply, symbol: "arrow.right", color: .green)
                    }
                    GridRow {
                        AirTemp(label: "Abluft (aus den Räumen)", value: extract, symbol: "arrow.left", color: .orange)
                        AirTemp(label: "Fortluft (nach draußen)", value: exhaust, symbol: "arrow.up.left", color: .gray)
                    }
                }
                if let recovery {
                    InfoRow("Wärmerückgewinnung", "\(Int((recovery * 100).rounded())) %")
                }
                InfoRow("Luftfeuchte Wohnzimmer", store.num(HeatingConfig.humidity).map { "\(Int($0)) %" })
                if let f = filter {
                    HStack {
                        Text("Filterwechsel in").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(f)) Tagen").foregroundStyle(f < 14 ? Color.red : Color.primary)
                    }
                    .font(.subheadline)
                }
                if let left = store.num(HeatingConfig.intensiveLeft), left > 0 {
                    InfoRow("Intensivlüftung noch", "\(Int(left)) min")
                }
                if isParent {
                    HStack {
                        Text("Lüfterstufe").font(.subheadline)
                        Spacer()
                        Picker("Stufe", selection: Binding(get: { stage }, set: { v in Task { await store.selectOption(HeatingConfig.fan, v) } })) {
                            ForEach(["1", "2", "3", "4"], id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                } else {
                    InfoRow("Lüfterstufe", stage)
                }
            }
        }
    }
}

// MARK: - Bausteine

struct RoomRow: View {
    @Environment(AppStore.self) private var store
    let room: HeatingConfig.Room
    let editable: Bool
    let parent: Bool

    var body: some View {
        let c = store.states[room.climate]
        let current = c?.attr("current_temperature")?.double ?? store.num(room.current)
        let target = c?.attr("temperature")?.double
        let minT = c?.attr("min_temp")?.double ?? 16
        let maxT = c?.attr("max_temp")?.double ?? 26
        let step = c?.attr("target_temp_step")?.double ?? 1
        let hvac = c?.state ?? "off"
        let heating = store.states[room.elementOn]?.state.lowercased() == "true"
        let locked = store.states[room.keyLock]?.state == "on"
        let color: Color = {
            guard let cur = current, let t = target, hvac != "off" else { return .secondary }
            if cur < t - 0.5 { return .blue }
            if cur > t + 1.5 { return .orange }
            return .green
        }()

        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(room.name).font(.subheadline.weight(.semibold))
                    if heating { Image(systemName: "flame.fill").font(.caption).foregroundStyle(.orange) }
                    if parent && locked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(hvac == "off" ? "aus" : (target.map { "Ziel \(Int($0)) °C" } ?? "–"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(current.map { String(format: "%.1f°", $0) } ?? "–")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            if editable, hvac != "off", let t = target {
                HStack(spacing: 0) {
                    Button { Task { await store.setRoomTemp(room, max(minT, t - step)) } } label: {
                        Image(systemName: "minus").frame(width: 34, height: 32)
                    }
                    .disabled(t <= minT)
                    Divider().frame(height: 18)
                    Button { Task { await store.setRoomTemp(room, min(maxT, t + step)) } } label: {
                        Image(systemName: "plus").frame(width: 34, height: 32)
                    }
                    .disabled(t >= maxT)
                }
                .buttonStyle(.plain)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
            if parent, store.states[room.elementSwitch] != nil {
                let elementOn = store.states[room.elementSwitch]?.state == "on"
                Button {
                    Task { await store.setSwitch(room.elementSwitch, !elementOn) }
                } label: {
                    Label(elementOn ? "Wärmeelement an" : "Wärmeelement aus", systemImage: elementOn ? "flame.fill" : "flame")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(elementOn ? Color.white : Color.secondary)
                        .background(elementOn ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(store.states[HeatingConfig.elementsGlobal]?.state == "off")
            }
        }
        .contextMenu {
            if parent {
                ForEach(c?.attr("hvac_modes")?.array?.compactMap(\.string) ?? [], id: \.self) { m in
                    Button { Task { await store.setRoomHvac(room, m) } } label: {
                        Label(["auto": "Wärmeelement aus (nur Wärmepumpe)", "heat": "Wärmeelement an", "off": "Raum aus", "cool": "Kühlen"][m] ?? m,
                              systemImage: m == hvac ? "checkmark" : "thermometer")
                    }
                }
                Button { Task { await store.setSwitch(room.keyLock, !locked) } } label: {
                    Label(locked ? "Tastensperre aus" : "Tastensperre an", systemImage: locked ? "lock.open" : "lock")
                }
            }
        }
    }
}

struct AirTemp: View {
    let label: String
    let value: Double?
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol).font(.caption2).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            Text(value.map { String(format: "%.1f °C", $0) } ?? "–").font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
