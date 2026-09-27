import SwiftUI

// MARK: - Saugroboter (Roborock über Home Assistant)
//
// Meldungen (Wasser leer, Fehler, Wartung) verschickt die HA-Automation
// automation.familie_saugroboter_meldungen an Jan & Vanessa.

struct VacuumWarning: Identifiable, Hashable {
    let text: String
    let symbol: String
    let severe: Bool
    var id: String { text }
}

@MainActor
extension AppStore {

    func vacState(_ v: FamilyConfig.Vacuum) -> HAState? { states[v.id] }
    func vacSensor(_ v: FamilyConfig.Vacuum, _ key: String) -> HAState? { states["sensor.\(v.prefix)_\(key)"] }
    func vacBinary(_ v: FamilyConfig.Vacuum, _ key: String) -> Bool { states["binary_sensor.\(v.prefix)_\(key)"]?.state == "on" }

    func vacIsCleaning(_ v: FamilyConfig.Vacuum) -> Bool {
        ["cleaning", "returning"].contains(vacState(v)?.state ?? "")
    }

    /// Restlaufzeit der Verschleißteile in Stunden
    func vacMaintenance(_ v: FamilyConfig.Vacuum) -> [(String, Double)] {
        [("Filter", "verbleibende_filterzeit"), ("Hauptbürste", "verbleibende_zeit_der_hauptburste"),
         ("Seitenbürste", "verbleibende_zeit_der_seitenburste"), ("Sensoren", "verbleibende_sensorzeit")]
            .compactMap { label, key in
                guard let h = vacSensor(v, key).flatMap({ Double($0.state) }) else { return nil }
                return (label, h)
            }
    }

    func vacWarnings(_ v: FamilyConfig.Vacuum) -> [VacuumWarning] {
        var w: [VacuumWarning] = []
        if vacBinary(v, "wasserknappheit") { w.append(.init(text: "Wasser leer", symbol: "drop.triangle.fill", severe: true)) }
        if let err = vacSensor(v, "staubsauger_fehler")?.state, !["none", "unknown", "unavailable", ""].contains(err) {
            w.append(.init(text: "Fehler: " + err.replacingOccurrences(of: "_", with: " "), symbol: "exclamationmark.triangle.fill", severe: true))
        }
        if vacState(v)?.state == "unavailable" {
            w.append(.init(text: "Offline", symbol: "wifi.slash", severe: false))
        }
        for (label, h) in vacMaintenance(v) where h <= 0 {
            let action = label == "Sensoren" ? "Sensoren reinigen" : "\(label) wechseln"
            w.append(.init(text: action, symbol: "wrench.and.screwdriver.fill", severe: false))
        }
        return w
    }

    func vacAction(_ v: FamilyConfig.Vacuum, _ service: String, _ extra: [String: Any] = [:]) async {
        var data = extra
        data["entity_id"] = v.id
        do {
            try await client.call("vacuum", service, data)
            try? await Task.sleep(for: .seconds(1.5))
            await refreshStates()
        } catch { report(error) }
    }

    func vacProgram(_ button: String) async {
        do {
            try await client.call("button", "press", ["entity_id": button])
            try? await Task.sleep(for: .seconds(1.5))
            await refreshStates()
        } catch { report(error) }
    }

    func vacMode(_ v: FamilyConfig.Vacuum, _ option: String) async {
        do {
            try await client.call("select", "select_option", ["entity_id": v.modeSelect, "option": option])
            await refreshStates()
        } catch { report(error) }
    }
}

enum VacText {
    static func status(_ s: String) -> String {
        [
            "charging": "Lädt", "charging_complete": "Voll geladen", "charger_disconnected": "Nicht in der Station",
            "idle": "Bereit", "cleaning": "Saugt", "segment_cleaning": "Reinigt Räume", "zoned_cleaning": "Reinigt Zone",
            "spot_cleaning": "Punktreinigung", "returning_home": "Fährt zur Station", "docking": "Dockt an",
            "paused": "Pausiert", "error": "Fehler", "emptying_the_bin": "Leert Behälter",
            "washing_the_mop": "Wäscht Mopp", "going_to_wash_the_mop": "Fährt zum Mopp-Waschen",
            "drying_the_mop": "Trocknet Mopp", "mapping": "Erstellt Karte", "remote_control_active": "Fernsteuerung",
            "updating": "Update", "sleeping": "Schläft", "manual_mode": "Manuell", "locked": "Gesperrt",
        ][s] ?? s.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func fan(_ s: String) -> String {
        ["quiet": "Leise", "balanced": "Normal", "turbo": "Turbo", "max": "Max", "max_plus": "Max+",
         "off": "Aus (nur wischen)", "smart_mode": "Smart", "custom": "Eigene"][s] ?? s
    }
    static func mode(_ s: String) -> String {
        ["vacuum": "Nur saugen", "vac_and_mop": "Saugen & wischen", "mop": "Nur wischen",
         "custom": "Eigene", "smart_mode": "Smart"][s] ?? s
    }
    static func hours(_ h: Double) -> String {
        if h <= 0 { return "fällig" }
        if h < 1 { return "\(Int(h * 60)) Min." }
        return "\(Int(h.rounded())) Std."
    }
}

// MARK: - Übersicht

struct VacuumsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                ForEach(FamilyConfig.vacuums) { v in
                    VacuumCard(vacuum: v)
                }
                Text("Bei leerem Wassertank, Fehlern und fälliger Wartung bekommt ihr eine Mitteilung.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Saugroboter")
        .refreshable { await store.refreshStates() }
    }
}

struct VacuumCard: View {
    @Environment(AppStore.self) private var store
    let vacuum: FamilyConfig.Vacuum
    @State private var showMap = false
    @State private var showService = false

    private var v: FamilyConfig.Vacuum { vacuum }
    private var canControl: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        let s = store.vacState(v)
        let state = s?.state ?? "unavailable"
        let status = store.vacSensor(v, "status")?.state ?? state
        let battery = store.vacSensor(v, "batterie").flatMap { Int(Double($0.state) ?? -1) } ?? -1
        let cleaning = store.vacIsCleaning(v)
        let warnings = store.vacWarnings(v)

        VStack(alignment: .leading, spacing: 12) {
            // Kopf
            HStack(spacing: 12) {
                Image(systemName: cleaning ? "fan.fill" : "circle.circle.fill")
                    .font(.title2).foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: cleaning)
                    .frame(width: 44, height: 44)
                    .background((cleaning ? Color.blue : (warnings.contains { $0.severe } ? Color.red : Color.gray)).gradient,
                                in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name).font(.headline)
                    Text(VacText.status(status)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if battery >= 0 {
                    Label("\(battery) %", systemImage: battery > 80 ? "battery.100" : battery > 40 ? "battery.50" : "battery.25")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(battery < 20 ? Color.red : Color.secondary)
                }
            }

            // Hinweise
            if !warnings.isEmpty {
                FlowChips(items: warnings)
            }

            // Läuft gerade
            if cleaning {
                let progress = Double(store.vacSensor(v, "reinigungsfortschritt")?.state ?? "") ?? 0
                let room = store.vacSensor(v, "aktueller_raum")?.state
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(progress, 100), total: 100)
                    HStack {
                        if let room, !["unknown", "unavailable"].contains(room) {
                            Label(room, systemImage: "location.fill")
                        }
                        Spacer()
                        Text("\(Int(progress)) % · \(store.vacSensor(v, "reinigungsbereich")?.state ?? "–") m²")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if let end = HADate.parse(store.vacSensor(v, "letztes_reinigungsende")?.state) {
                Text("Zuletzt: \(DayText.label(end)), \(end.formatted(date: .omitted, time: .shortened)) · \(store.vacSensor(v, "reinigungsbereich")?.state ?? "–") m²")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Bedienung (nur Eltern)
            if canControl && state != "unavailable" {
                HStack(spacing: 10) {
                    if state == "cleaning" {
                        VacButton(title: "Pause", symbol: "pause.fill", tint: .orange) { Task { await store.vacAction(v, "pause") } }
                    } else {
                        VacButton(title: state == "paused" ? "Weiter" : "Start", symbol: "play.fill", tint: .blue) {
                            Task { await store.vacAction(v, "start") }
                        }
                    }
                    VacButton(title: "Station", symbol: "house.fill", tint: .green) { Task { await store.vacAction(v, "return_to_base") } }
                    VacButton(title: "Finden", symbol: "speaker.wave.2.fill", tint: .gray) { Task { await store.vacAction(v, "locate") } }
                }

                if !v.programs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(v.programs, id: \.entity) { p in
                                Button {
                                    Task { await store.vacProgram(p.entity) }
                                } label: {
                                    Label(p.name, systemImage: "sparkles").font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }

                HStack {
                    if let fans = s?.attr("fan_speed_list")?.array?.compactMap(\.string) {
                        Menu {
                            ForEach(fans, id: \.self) { f in
                                Button(VacText.fan(f)) { Task { await store.vacAction(v, "set_fan_speed", ["fan_speed": f]) } }
                            }
                        } label: {
                            Label("Saugkraft: \(VacText.fan(s?.attr("fan_speed")?.string ?? ""))", systemImage: "fan")
                                .font(.caption)
                        }
                    }
                    Spacer()
                    if let modeState = store.states[v.modeSelect],
                       let options = modeState.attr("options")?.array?.compactMap(\.string) {
                        Menu {
                            ForEach(options, id: \.self) { o in
                                Button(VacText.mode(o)) { Task { await store.vacMode(v, o) } }
                            }
                        } label: {
                            Label(VacText.mode(modeState.state), systemImage: "drop")
                                .font(.caption)
                        }
                    }
                }
            }

            // Karte & Wartung
            HStack {
                Button { withAnimation { showMap.toggle() } } label: {
                    Label(showMap ? "Karte ausblenden" : "Karte", systemImage: "map")
                }
                Spacer()
                Button { withAnimation { showService.toggle() } } label: {
                    Label("Wartung", systemImage: "wrench.and.screwdriver")
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)

            if showMap, let pic = store.states["image.\(v.prefix)_map_0"]?.attr("entity_picture")?.string {
                HAImage(path: pic, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if showService {
                VStack(spacing: 6) {
                    ForEach(store.vacMaintenance(v), id: \.0) { label, h in
                        HStack {
                            Text(label)
                            Spacer()
                            Text(VacText.hours(h))
                                .foregroundStyle(h <= 0 ? Color.red : (h < 15 ? Color.orange : Color.secondary))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    if let total = store.vacSensor(v, "gesamtzahl_reinigungen")?.state {
                        HStack {
                            Text("Reinigungen gesamt").foregroundStyle(.secondary)
                            Spacer()
                            Text(total).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Text("Nach dem Tausch/Reinigen den Zähler in der Roborock-App zurücksetzen.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct VacButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.headline)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}

/// Hinweise als kleine farbige Kapseln, die umbrechen
struct FlowChips: View {
    let items: [VacuumWarning]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(items) { w in
            Label(w.text, systemImage: w.symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(w.severe ? Color.red : Color.orange)
                .background((w.severe ? Color.red : Color.orange).opacity(0.14), in: Capsule())
        }
    }
}

// MARK: - Karte auf „Heute“ – nur wenn einer saugt oder etwas zu tun ist

struct VacuumTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let relevant = FamilyConfig.vacuums.filter {
            store.vacIsCleaning($0) || store.vacWarnings($0).contains { w in w.severe || w.symbol == "wrench.and.screwdriver.fill" }
        }
        if !relevant.isEmpty, store.isParent, store.activeKid == nil {
            NavigationLink { VacuumsView() } label: {
                Card(title: "Saugroboter", symbol: "fan.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(relevant) { v in
                            HStack(spacing: 8) {
                                Text(v.name).font(.body.weight(.medium))
                                Spacer()
                                if store.vacIsCleaning(v) {
                                    let p = Int(Double(store.vacSensor(v, "reinigungsfortschritt")?.state ?? "") ?? 0)
                                    Text("saugt · \(p) %").font(.subheadline).foregroundStyle(.blue)
                                } else if let w = store.vacWarnings(v).first {
                                    Label(w.text, systemImage: w.symbol).font(.subheadline)
                                        .foregroundStyle(w.severe ? Color.red : Color.orange)
                                }
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
