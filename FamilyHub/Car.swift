import SwiftUI
import MapKit

// MARK: - Auto: Tesla (Daten aus TeslaLogger per MQTT) + Laden über evcc (Ladepunkt openWB)

enum CarConfig {
    // Tesla (von Family Hub als MQTT-Gerät „Tesla“ angelegt)
    static let soc = "sensor.tesla_akku"
    static let range = "sensor.tesla_reichweite"
    static let status = "sensor.tesla_status"
    static let chargePower = "sensor.tesla_ladeleistung"
    static let chargeLimit = "sensor.tesla_ladelimit"
    static let timeToFull = "sensor.tesla_zeit_bis_voll"
    static let added = "sensor.tesla_geladen"
    static let odometer = "sensor.tesla_kilometerstand"
    static let inside = "sensor.tesla_innentemperatur"
    static let outside = "sensor.tesla_aussentemperatur"
    static let charging = "binary_sensor.tesla_ladt"
    static let plugged = "binary_sensor.tesla_eingesteckt"
    static let unlocked = "binary_sensor.tesla_nicht_abgeschlossen"
    static let windows = "binary_sensor.tesla_fenster_offen"
    static let doors = "binary_sensor.tesla_turen_offen"
    static let sentry = "binary_sensor.tesla_wachtermodus"
    static let tracker = "device_tracker.tesla_standort"

    // evcc-Ladepunkt
    static let mode = "select.evcc_openwb_mode"                 // off / smart / now
    static let costLimit = "number.evcc_openwb_smart_cost_limit" // ≤ dieser Preis → aus dem Netz laden
    static let limitSoc = "select.evcc_openwb_limit_soc"
    static let minSoc = "select.evcc_openwb_min_soc"
    static let lpCharging = "binary_sensor.evcc_openwb_charging"
    static let lpConnected = "binary_sensor.evcc_openwb_connected"
    static let lpPower = "sensor.evcc_openwb_charge_power"
    static let lpSession = "sensor.evcc_openwb_session_energy"
    static let lpSolar = "sensor.evcc_openwb_session_solar_percentage"
    static let lpRemaining = "sensor.evcc_openwb_charge_remaining_duration"
    static let pvAction = "sensor.evcc_openwb_pv_action_value"
    static let planSoc = "sensor.evcc_openwb_vehicle_plans_soc"
    static let planTime = "sensor.evcc_openwb_vehicle_plans_time"
    static let planScript = "script.familie_tesla_plan"

    /// Nachtstrom-Grenze: knapp über eurem Nachttarif (17,35 ct)
    static let nightLimit = 0.18
}

enum ChargeMode: String, CaseIterable, Identifiable {
    case sunNight, sun, now, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunNight: "Sonne + Nachtstrom"
        case .sun: "Nur Sonne"
        case .now: "Sofort"
        case .off: "Aus"
        }
    }
    var symbol: String {
        switch self {
        case .sunNight: "sun.and.horizon.fill"
        case .sun: "sun.max.fill"
        case .now: "bolt.fill"
        case .off: "pause.fill"
        }
    }
    var hint: String {
        switch self {
        case .sunNight: "Tagsüber mit Solar-Überschuss, nachts 0–5 Uhr mit günstigem Nachtstrom."
        case .sun: "Nur mit Solar-Überschuss – kostet fast nichts, dauert aber."
        case .now: "Lädt sofort mit voller Leistung (Netzstrom zum aktuellen Preis)."
        case .off: "Lädt gar nicht."
        }
    }
    var color: Color {
        switch self {
        case .sunNight: .indigo
        case .sun: .yellow
        case .now: .red
        case .off: .gray
        }
    }
}

@MainActor
extension AppStore {
    var hasCar: Bool { states[CarConfig.soc] != nil }

    var chargeMode: ChargeMode {
        switch states[CarConfig.mode]?.state {
        case "now": return .now
        case "off": return .off
        default: return (num(CarConfig.costLimit) ?? 0) >= 0.17 ? .sunNight : .sun
        }
    }

    func setChargeMode(_ m: ChargeMode) async {
        do {
            switch m {
            case .sunNight:
                try await client.call("select", "select_option", ["entity_id": CarConfig.mode, "option": "smart"])
                try await client.call("number", "set_value", ["entity_id": CarConfig.costLimit, "value": CarConfig.nightLimit])
            case .sun:
                try await client.call("select", "select_option", ["entity_id": CarConfig.mode, "option": "smart"])
                try await client.call("number", "set_value", ["entity_id": CarConfig.costLimit, "value": 0])
            case .now:
                try await client.call("select", "select_option", ["entity_id": CarConfig.mode, "option": "now"])
            case .off:
                try await client.call("select", "select_option", ["entity_id": CarConfig.mode, "option": "off"])
            }
            try? await Task.sleep(for: .seconds(1))
            await refreshStates()
        } catch { report(error) }
    }

    func setCarSelect(_ entity: String, _ value: Int) async {
        do {
            try await client.call("select", "select_option", ["entity_id": entity, "option": String(value)])
            try? await Task.sleep(for: .milliseconds(800))
            await refreshStates()
        } catch { report(error) }
    }

    var carStatusText: String {
        let s = states[CarConfig.status]?.state ?? ""
        if states[CarConfig.charging]?.state == "on" || states[CarConfig.lpCharging]?.state == "on" { return "lädt" }
        return s.isEmpty || s == "unknown" ? "–" : s
    }
}

// MARK: Karte auf „Zuhause“

struct CarCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let soc = store.num(CarConfig.soc)
        let charging = store.carStatusText == "lädt"
        NavigationLink { CarPage() } label: {
            HStack(spacing: 14) {
                ProgressRing(progress: soc.map { $0 / 100 }, color: socColor(soc), label: soc.map { "\(Int($0))" } ?? "–",
                             size: 52, lineWidth: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tesla").font(.headline)
                    Text(subtitle(charging)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
    }

    private func subtitle(_ charging: Bool) -> String {
        var p: [String] = []
        if let r = store.num(CarConfig.range) { p.append("\(Int(r)) km") }
        p.append(charging ? "lädt" : store.carStatusText)
        if store.states[CarConfig.tracker]?.state == "home" { p.append("zu Hause") }
        p.append(store.chargeMode.title)
        return p.joined(separator: " · ")
    }
}

func socColor(_ soc: Double?) -> Color {
    guard let soc else { return .gray }
    return soc < 20 ? .red : (soc < 40 ? .orange : .green)
}

// MARK: Seite

struct CarPage: View {
    @Environment(AppStore.self) private var store
    @State private var busy = false
    @State private var planOn = false
    @State private var planSoc = 80
    @State private var planTime = CarPage.defaultPlanTime()
    @State private var carCamera: MapCameraPosition = .automatic

    static func defaultPlanTime() -> Date {
        let cal = Calendar.current
        let t = cal.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
        return t > Date() ? t : cal.date(byAdding: .day, value: 1, to: t) ?? t
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                chargeCard
                if store.states[CarConfig.lpConnected]?.state == "on" || store.states[CarConfig.lpCharging]?.state == "on" {
                    wallboxCard
                }
                CarHistoryLink()
                planCard
                infoCard
                mapCard
            }
            .padding()
        }
        .background(AppBackground())
        .navigationTitle("Auto")
        .refreshable { await store.refreshStates() }
        .onAppear {
            planSoc = Int(store.num(CarConfig.planSoc) ?? 80)
            if let t = HADate.parse(store.states[CarConfig.planTime]?.state) { planTime = t; planOn = true }
        }
    }

    private var header: some View {
        let soc = store.num(CarConfig.soc)
        return VStack(spacing: 14) {
            HStack(spacing: 18) {
                ProgressRing(progress: soc.map { $0 / 100 }, color: socColor(soc),
                             label: soc.map { "\(Int($0)) %" } ?? "–", size: 96, lineWidth: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tesla").font(.title2.weight(.bold))
                    if let r = store.num(CarConfig.range) {
                        Label("\(Int(r)) km Reichweite", systemImage: "road.lanes").font(.subheadline)
                    }
                    Label(store.carStatusText.capitalized, systemImage: store.carStatusText == "lädt" ? "bolt.fill" : "car.fill")
                        .font(.subheadline).foregroundStyle(store.carStatusText == "lädt" ? .green : .secondary)
                    if store.carStatusText == "lädt", let p = store.num(CarConfig.chargePower) ?? store.num(CarConfig.lpPower).map({ $0 / 1000 }), p > 0 {
                        Text(String(format: "%.1f kW", p).replacingOccurrences(of: ".", with: ",")
                             + (store.num(CarConfig.timeToFull).map { $0 > 0 ? " · noch \(Int($0)) Min." : "" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                chip(store.states[CarConfig.unlocked]?.state == "on" ? "offen" : "abgeschlossen",
                     store.states[CarConfig.unlocked]?.state == "on" ? "lock.open.fill" : "lock.fill",
                     store.states[CarConfig.unlocked]?.state == "on" ? .red : .green)
                if store.states[CarConfig.plugged]?.state == "on" || store.states[CarConfig.lpConnected]?.state == "on" {
                    chip("eingesteckt", "powerplug.fill", .blue)
                }
                if store.states[CarConfig.windows]?.state == "on" { chip("Fenster offen", "window.vertical.open", .orange) }
                if store.states[CarConfig.doors]?.state == "on" { chip("Tür offen", "car.side.rear.open.fill", .orange) }
                if store.states[CarConfig.sentry]?.state == "on" { chip("Wächter", "eye.fill", .purple) }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .glassSurface()
    }

    private func chip(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    // Laden
    private var chargeCard: some View {
        Card(title: "Laden", symbol: "ev.charger.fill") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(ChargeMode.allCases) { m in
                        let on = store.chargeMode == m
                        Button {
                            Task { busy = true; await store.setChargeMode(m); busy = false }
                        } label: {
                            Label(m.title, systemImage: m.symbol)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(on ? m.color.opacity(0.9) : Color(.tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                Text(store.chargeMode.hint).font(.caption).foregroundStyle(.secondary)
                Divider()
                socStepper("Laden bis", CarConfig.limitSoc, range: 50...100,
                           note: "Ziel-Ladestand")
                socStepper("Mindestens", CarConfig.minSoc, range: 0...80,
                           note: "Bis hierher lädt er immer sofort – egal ob Sonne")
                if let a = store.states[CarConfig.pvAction]?.state, !a.isEmpty, a != "unknown", store.chargeMode != .now, store.chargeMode != .off {
                    Label(a, systemImage: "sun.max").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func socStepper(_ title: String, _ entity: String, range: ClosedRange<Int>, note: String) -> some View {
        let v = Int(store.states[entity]?.state ?? "") ?? 0
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.setCarSelect(entity, max(range.lowerBound, v - 5)) } } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless).disabled(v <= range.lowerBound)
            Text("\(v) %").font(.headline.monospacedDigit()).frame(minWidth: 54)
            Button { Task { await store.setCarSelect(entity, min(range.upperBound, v + 5)) } } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless).disabled(v >= range.upperBound)
        }
    }

    private var wallboxCard: some View {
        Card(title: "Wallbox", symbol: "bolt.car.fill") {
            HStack {
                StatBlock(value: store.num(CarConfig.lpPower).map { Fmt.watts($0) } ?? "–", label: "Leistung", color: .green)
                StatBlock(value: Fmt.kwh(store.num(CarConfig.lpSession)), label: "geladen", color: .blue)
                StatBlock(value: store.num(CarConfig.lpSolar).map { "\(Int($0)) %" } ?? "–", label: "Sonne", color: .yellow)
            }
        }
    }

    // Plan: bis … auf … %
    private var planCard: some View {
        Card(title: "Fertig bis …", symbol: "alarm.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Ladeplan", isOn: $planOn.animation())
                if planOn {
                    DatePicker("Fertig um", selection: $planTime, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Stepper("Auf \(planSoc) %", value: $planSoc, in: 20...100, step: 5)
                    Button {
                        Task {
                            busy = true
                            _ = try? await store.client.call("script", "turn_on", ["entity_id": CarConfig.planScript,
                                "variables": ["soc": planSoc, "zeit": HADate.iso.string(from: planTime)]])
                            try? await Task.sleep(for: .seconds(1)); await store.refreshStates(); busy = false
                        }
                    } label: { Label("Plan speichern", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    Text("evcc lädt dann möglichst mit Sonne und Nachtstrom und sorgt dafür, dass er rechtzeitig voll ist.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.num(CarConfig.planSoc) != nil {
                    Button(role: .destructive) {
                        Task {
                            _ = try? await store.client.call("script", "turn_on", ["entity_id": CarConfig.planScript, "variables": ["loeschen": true]])
                            try? await Task.sleep(for: .seconds(1)); await store.refreshStates()
                        }
                    } label: { Label("Plan löschen", systemImage: "trash") }
                }
            }
        }
    }

    private var infoCard: some View {
        Card(title: "Fahrzeug", symbol: "car.fill") {
            VStack(spacing: 8) {
                InfoRow("Kilometerstand", store.num(CarConfig.odometer).map { "\(Int($0).formatted()) km" })
                InfoRow("Innen", store.num(CarConfig.inside).map { String(format: "%.0f °C", $0) })
                InfoRow("Außen", store.num(CarConfig.outside).map { String(format: "%.0f °C", $0) })
                InfoRow("Zuletzt geladen", store.num(CarConfig.added).flatMap { $0 > 0 ? String(format: "%.1f kWh", $0) : nil })
            }
        }
    }

    @ViewBuilder private var mapCard: some View {
        if let c = carCoord {
            Map(position: $carCamera) {
                Marker("Tesla", systemImage: "car.fill", coordinate: c).tint(.red)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            .onAppear { follow(c, animated: false) }
            .onChange(of: "\(c.latitude),\(c.longitude)") { _, _ in follow(c, animated: true) }
        }
    }

    private var carCoord: CLLocationCoordinate2D? {
        guard let s = store.states[CarConfig.tracker], let lat = s.attr("latitude")?.double,
              let lon = s.attr("longitude")?.double else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Karte läuft mit dem Auto mit
    private func follow(_ c: CLLocationCoordinate2D, animated: Bool) {
        let r = MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800)
        if animated { withAnimation(.easeInOut(duration: 0.8)) { carCamera = .region(r) } } else { carCamera = .region(r) }
    }
}
