import SwiftUI

// MARK: - Haushaltsgeräte: Wäsche (Shelly-Messung) + Miele-Küchengeräte
//
// Miele kommt über die Miele-Integration: sensor.<gerät>_status, _programm, _programmabschnitt,
// _verbleibende_zeit, _ende_um, _temperatur, _zieltemperatur, _kerntemperatur_lebensmittel,
// binary_sensor.<gerät>_tur, light.<gerät>_licht, switch.<gerät>_eingeschaltet, button.<gerät>_start/_stop.

enum MieleConfig {
    struct Appliance: Identifiable {
        let key: String
        let name: String
        let symbol: String
        let color: Color
        var id: String { key }

        var status: String { "sensor.\(key)_status" }
        var program: String { "sensor.\(key)_programm" }
        var phase: String { "sensor.\(key)_programmabschnitt" }
        var remaining: String { "sensor.\(key)_verbleibende_zeit" }
        var endsAt: String { "sensor.\(key)_ende_um" }
        var temp: String { "sensor.\(key)_temperatur" }
        var target: String { "sensor.\(key)_zieltemperatur" }
        var core: String { "sensor.\(key)_kerntemperatur_lebensmittel" }
        var door: String { "binary_sensor.\(key)_tur" }
        var light: String { "light.\(key)_licht" }
        var power: String { "switch.\(key)_eingeschaltet" }
        var start: String { "button.\(key)_start" }
        var stop: String { "button.\(key)_stop" }
    }

    static let appliances: [Appliance] = [
        Appliance(key: "geschirrspuler", name: "Geschirrspüler", symbol: "dishwasher.fill", color: .teal),
        Appliance(key: "backofen", name: "Backofen", symbol: "oven.fill", color: .orange),
        Appliance(key: "combi_dampfgarer", name: "Dampfgarer", symbol: "cloud.fill", color: .blue),
        Appliance(key: "warmeschublade", name: "Wärmeschublade", symbol: "rectangle.bottomthird.inset.filled", color: .red),
    ]

    static let runningStates: Set<String> = ["in_use", "running", "pause", "programmed_waiting_to_start", "programmed",
                                             "rinse_hold", "autocleaning", "superheating"]

    static func statusText(_ s: String?) -> String {
        switch s {
        case nil, "unavailable": return "Nicht verbunden"
        case "unknown": return "Unbekannt"
        case "off": return "Aus"
        case "on": return "An"
        case "programmed": return "Programm gewählt"
        case "programmed_waiting_to_start": return "Startet später"
        case "in_use", "running": return "Läuft"
        case "pause": return "Pausiert"
        case "program_ended": return "Fertig"
        case "failure": return "Störung"
        case "program_interrupted": return "Abgebrochen"
        case "idle": return "Bereit"
        case "rinse_hold": return "Spülstopp"
        case "service": return "Service"
        case "autocleaning": return "Selbstreinigung"
        case "superheating": return "Schnellaufheizen"
        case "not_connected": return "Nicht verbunden"
        default: return MieleConfig.humanize(s ?? "")
        }
    }

    static func humanize(_ key: String) -> String {
        guard !key.isEmpty, key != "no_program", key != "not_running" else { return "" }
        let t = key.replacingOccurrences(of: "_", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

@MainActor
extension AppStore {
    func mieleStatus(_ a: MieleConfig.Appliance) -> String? { states[a.status]?.state }
    func mieleRunning(_ a: MieleConfig.Appliance) -> Bool { MieleConfig.runningStates.contains(mieleStatus(a) ?? "") }
    func mieleFinished(_ a: MieleConfig.Appliance) -> Bool { mieleStatus(a) == "program_ended" }
    func mieleOffline(_ a: MieleConfig.Appliance) -> Bool {
        let s = mieleStatus(a)
        return s == nil || s == "unavailable" || s == "not_connected"
    }

    /// Programmname bzw. Abschnitt – lokalisiert von Miele, sonst aus dem Schlüssel
    func mieleText(_ entity: String) -> String {
        guard let s = states[entity], s.state != "unavailable", s.state != "unknown" else { return "" }
        if let loc = s.attr("Localized")?.string, !loc.isEmpty { return loc }
        return MieleConfig.humanize(s.state)
    }

    func mieleRemaining(_ a: MieleConfig.Appliance) -> Int? {
        guard let m = Double(states[a.remaining]?.state ?? ""), m > 0 else { return nil }
        return Int(m)
    }

    func mieleEnd(_ a: MieleConfig.Appliance) -> Date? {
        guard let s = states[a.endsAt]?.state else { return nil }
        return HADate.isoFrac.date(from: s) ?? HADate.iso.date(from: s)
    }

    func mieleTemp(_ entity: String) -> Int? {
        guard let t = Double(states[entity]?.state ?? ""), t > -100 else { return nil }
        return Int(t.rounded())
    }

    func mieleCall(_ domain: String, _ service: String, _ entity: String) async {
        do {
            try await client.call(domain, service, ["entity_id": entity])
            try? await Task.sleep(for: .milliseconds(800))
            await refreshStates()
        } catch { report(error) }
    }

    func available(_ entity: String) -> Bool {
        guard let s = states[entity]?.state else { return false }
        return s != "unavailable"
    }
}

struct AppliancesView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmOff: MieleConfig.Appliance?

    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ErrorBanner()
                Text("WÄSCHE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                NavigationLink { LaundryView() } label: { laundryCard }
                    .buttonStyle(.plain)

                Text("KÜCHE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4).padding(.top, 8)
                ForEach(MieleConfig.appliances) { a in
                    MieleCard(appliance: a, canControl: isParent) { confirmOff = a }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Haushaltsgeräte")
        .refreshable { await store.refreshStates() }
        .confirmationDialog(confirmOff.map { "\($0.name) ausschalten?" } ?? "",
                            isPresented: Binding(get: { confirmOff != nil }, set: { if !$0 { confirmOff = nil } }),
                            titleVisibility: .visible) {
            if let a = confirmOff {
                Button("Ausschalten", role: .destructive) { Task { await store.mieleCall("switch", "turn_off", a.power) } }
            }
        } message: {
            Text("Ein laufendes Programm wird dabei beendet.")
        }
    }

    private var laundryCard: some View {
        HStack(spacing: 12) {
            ForEach(LaundryConfig.devices) { d in
                let running = store.laundryIsRunning(d)
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: d.symbol)
                        .font(.title3).foregroundStyle(running ? Color.white : d.color)
                        .frame(width: 40, height: 40)
                        .background(running ? AnyShapeStyle(d.color.gradient) : AnyShapeStyle(d.color.opacity(0.14)), in: Circle())
                        .symbolEffect(.pulse, isActive: running)
                    Text(d.name).font(.subheadline.weight(.semibold))
                    Text(running ? "Läuft" : "Aus").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MieleCard: View {
    @Environment(AppStore.self) private var store
    let appliance: MieleConfig.Appliance
    let canControl: Bool
    let askOff: () -> Void

    private var a: MieleConfig.Appliance { appliance }
    private var running: Bool { store.mieleRunning(a) }
    private var finished: Bool { store.mieleFinished(a) }
    private var offline: Bool { store.mieleOffline(a) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: a.symbol)
                    .font(.title3)
                    .foregroundStyle(running || finished ? Color.white : a.color)
                    .frame(width: 44, height: 44)
                    .background(running || finished ? AnyShapeStyle(a.color.gradient) : AnyShapeStyle(a.color.opacity(0.14)),
                                in: RoundedRectangle(cornerRadius: 12))
                    .symbolEffect(.pulse, isActive: running)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.headline)
                    Text(headline).font(.subheadline).foregroundStyle(finished ? Color.green : .secondary)
                }
                Spacer()
                if store.states[a.door]?.state == "on" {
                    Label("Tür offen", systemImage: "door.left.hand.open")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }

            if running || finished, let progress {
                ProgressView(value: progress).tint(a.color)
            }

            let facts = details
            if !facts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(facts, id: \.self) { f in
                        Text(f)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }

            if canControl && !offline {
                HStack(spacing: 8) {
                    if store.available(a.light) {
                        let lit = store.states[a.light]?.state == "on"
                        Button { Task { await store.mieleCall("light", lit ? "turn_off" : "turn_on", a.light) } } label: {
                            Label(lit ? "Licht aus" : "Licht an", systemImage: lit ? "lightbulb.fill" : "lightbulb")
                        }
                        .buttonStyle(.bordered).tint(lit ? .yellow : .gray)
                    }
                    if store.available(a.start) && !running {
                        Button { Task { await store.mieleCall("button", "press", a.start) } } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(a.color)
                    }
                    if store.available(a.stop) && running {
                        Button { Task { await store.mieleCall("button", "press", a.stop) } } label: {
                            Label("Stopp", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered).tint(.red)
                    }
                    Spacer()
                    if store.states[a.power]?.state == "on" {
                        Button("Ausschalten", action: askOff)
                            .buttonStyle(.bordered).tint(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .opacity(offline ? 0.55 : 1)
    }

    private var headline: String {
        let status = MieleConfig.statusText(store.mieleStatus(a))
        guard running else { return status }
        if let end = store.mieleEnd(a), end > Date() { return "\(status) · fertig um \(end.formatted(date: .omitted, time: .shortened))" }
        if let m = store.mieleRemaining(a) { return "\(status) · noch \(DurationText.minutes(m))" }
        return status
    }

    private var details: [String] {
        var out: [String] = []
        let prog = store.mieleText(a.program)
        if !prog.isEmpty { out.append(prog) }
        let phase = store.mieleText(a.phase)
        if running, !phase.isEmpty, phase != prog { out.append(phase) }
        if let t = store.mieleTemp(a.temp) {
            if let z = store.mieleTemp(a.target), z > 0, running { out.append("\(t) → \(z) °C") } else if running { out.append("\(t) °C") }
        }
        if running, let c = store.mieleTemp(a.core), c > 0 { out.append("Kern \(c) °C") }
        return out
    }

    /// Fortschritt aus verstrichener und verbleibender Zeit
    private var progress: Double? {
        if finished { return 1 }
        guard let left = store.mieleRemaining(a),
              let done = Double(store.states["sensor.\(a.key)_verstrichene_zeit"]?.state ?? ""), done + Double(left) > 0
        else { return nil }
        return done / (done + Double(left))
    }
}

enum DurationText {
    static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

/// Heute-Karte: nur sichtbar, wenn ein Küchengerät läuft oder gerade fertig ist
struct KitchenTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let active = MieleConfig.appliances.filter { store.mieleRunning($0) || store.mieleFinished($0) }
        if !active.isEmpty {
            NavigationLink { AppliancesView() } label: {
                Card(title: "Küche", symbol: "oven.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(active) { a in
                            HStack(spacing: 10) {
                                Image(systemName: a.symbol).foregroundStyle(a.color)
                                    .symbolEffect(.pulse, isActive: store.mieleRunning(a))
                                Text(a.name).font(.body.weight(.medium))
                                Spacer()
                                Text(rightText(a)).font(.subheadline)
                                    .foregroundStyle(store.mieleFinished(a) ? Color.green : .secondary)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func rightText(_ a: MieleConfig.Appliance) -> String {
        if store.mieleFinished(a) { return "fertig" }
        if let end = store.mieleEnd(a), end > Date() { return "bis \(end.formatted(date: .omitted, time: .shortened))" }
        if let m = store.mieleRemaining(a) { return "noch \(DurationText.minutes(m))" }
        return MieleConfig.statusText(store.mieleStatus(a))
    }
}
