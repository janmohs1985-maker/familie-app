import SwiftUI

// MARK: - Haushaltsgeräte: Wäsche (Shelly-Messung) + Miele-Küchengeräte
//
// Miele kommt über die Miele-Integration: sensor.<gerät>_status, _programm, _programmabschnitt,
// _verbleibende_zeit, _ende_um, _temperatur, _zieltemperatur, _kerntemperatur_lebensmittel,
// binary_sensor.<gerät>_tur, light.<gerät>_licht, switch.<gerät>_eingeschaltet, button.<gerät>_start/_stop.

enum MieleConfig {
    enum Kind { case oven, steam, dishwasher, drawer }

    struct Appliance: Identifiable {
        let key: String
        let name: String
        let symbol: String
        let color: Color
        let kind: Kind
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
        var coreTarget: String { "sensor.\(key)_ziel_kerntemperatur_lebensmittel" }
        var elapsed: String { "sensor.\(key)_verstrichene_zeit" }
        var startedAt: String { "sensor.\(key)_gestartet_um" }
        var startsAt: String { "sensor.\(key)_starte_um" }
        var remote: String { "binary_sensor.\(key)_fernsteuerung" }
        var failure: String { "binary_sensor.\(key)_fehler" }
        var info: String { "binary_sensor.\(key)_info" }
        var water: [String] { ["sensor.\(key)_wasserverbrauch_2", "sensor.\(key)_wasserverbrauch"] }
        var energy: [String] { ["sensor.\(key)_stromverbrauch_2", "sensor.\(key)_stromverbrauch"] }
    }

    static let appliances: [Appliance] = [
        Appliance(key: "geschirrspuler", name: "Geschirrspüler", symbol: "dishwasher.fill", color: .teal, kind: .dishwasher),
        Appliance(key: "backofen", name: "Backofen", symbol: "oven.fill", color: .orange, kind: .oven),
        Appliance(key: "combi_dampfgarer", name: "Dampfgarer", symbol: "cloud.fill", color: .blue, kind: .steam),
        Appliance(key: "warmeschublade", name: "Wärmeschublade", symbol: "rectangle.bottomthird.inset.filled", color: .red, kind: .drawer),
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

    /// Zeitpunkt aus einem Miele-Sensor (ISO-Zeit), sonst nil
    func mieleTime(_ entity: String) -> Date? {
        guard let s = states[entity]?.state, s != "unknown", s != "unavailable" else { return nil }
        return HADate.isoFrac.date(from: s) ?? HADate.iso.date(from: s)
    }

    /// erster Sensor aus der Liste mit einer Zahl > 0
    func mieleNumber(_ entities: [String]) -> Double? {
        for e in entities { if let v = Double(states[e]?.state ?? ""), v > 0 { return v } }
        return nil
    }

    func mieleProgress(_ a: MieleConfig.Appliance) -> Double? {
        if mieleFinished(a) { return 1 }
        guard let left = mieleRemaining(a), let done = Double(states[a.elapsed]?.state ?? ""), done + Double(left) > 0 else { return nil }
        return done / (done + Double(left))
    }

    /// Kurzer Text fürs „Display“ auf der Gerätefront
    func mieleDisplay(_ a: MieleConfig.Appliance) -> String {
        if mieleOffline(a) { return "– –" }
        let st = mieleStatus(a)
        if st == "programmed_waiting_to_start", let t = mieleTime(a.startsAt) {
            return "Start " + t.formatted(date: .omitted, time: .shortened)
        }
        if mieleFinished(a) { return "Fertig" }
        if mieleRunning(a) {
            if let m = mieleRemaining(a) { return String(format: "%d:%02d", m / 60, m % 60) }
            return MieleConfig.statusText(st)
        }
        return MieleConfig.statusText(st)
    }

    func available(_ entity: String) -> Bool {
        guard let s = states[entity]?.state else { return false }
        return s != "unavailable"
    }
}

struct AppliancesView: View {
    @Environment(AppStore.self) private var store
    @State private var detail: MieleConfig.Appliance?

    private func appliance(_ key: String) -> MieleConfig.Appliance? { MieleConfig.appliances.first { $0.key == key } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ErrorBanner()
                Text("WÄSCHE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                NavigationLink { LaundryView() } label: { laundryCard }
                    .buttonStyle(.plain)

                Text("KÜCHE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4).padding(.top, 8)
                kitchen
                Text("Gerät antippen für Details und Steuerung").font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Haushaltsgeräte")
        .refreshable { await store.refreshStates() }
        .sheet(item: $detail) { a in
            MieleDetailView(appliance: a).presentationDetents([.large])
        }
    }

    /// Küche wie eingebaut: Dampfgarer und Backofen nebeneinander, darunter die Wärmeschublade, daneben die Spülmaschine
    @ViewBuilder private var kitchen: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if let a = appliance("combi_dampfgarer") { tile(a, height: 170) }
                if let a = appliance("backofen") { tile(a, height: 170) }
            }
            if let a = appliance("warmeschublade") { tile(a, height: 84) }
            if let a = appliance("geschirrspuler") { tile(a, height: 150) }
        }
    }

    private func tile(_ a: MieleConfig.Appliance, height: CGFloat) -> some View {
        Button { detail = a } label: {
            VStack(alignment: .leading, spacing: 8) {
                MieleFront(appliance: a, height: height)
                MieleCaption(appliance: a)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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

/// Name und Status unter der Gerätefront
struct MieleCaption: View {
    @Environment(AppStore.self) private var store
    let appliance: MieleConfig.Appliance

    var body: some View {
        let a = appliance
        let finished = store.mieleFinished(a)
        let running = store.mieleRunning(a)
        HStack(spacing: 6) {
            Circle()
                .fill(running ? a.color : finished ? Color.green : Color(.systemGray4))
                .frame(width: 7, height: 7)
            Text(a.name).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Text(sub).font(.caption).foregroundStyle(finished ? Color.green : .secondary).lineLimit(1)
        }
        .padding(.horizontal, 4)
    }

    private var sub: String {
        let a = appliance
        if store.mieleRunning(a) {
            let prog = store.mieleText(a.program)
            if let end = store.mieleEnd(a), end > Date() { return "bis " + end.formatted(date: .omitted, time: .shortened) }
            return prog.isEmpty ? "läuft" : prog
        }
        return MieleConfig.statusText(store.mieleStatus(a))
    }
}

// MARK: - Gerätefront (Miele-Look: dunkles Glas, Edelstahlgriff, Display)

struct MieleFront: View {
    @Environment(AppStore.self) private var store
    let appliance: MieleConfig.Appliance
    let height: CGFloat

    private var a: MieleConfig.Appliance { appliance }

    var body: some View {
        let offline = store.mieleOffline(a)
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                content.padding(9)
            }
            .frame(height: height)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            if a.kind == .dishwasher { FloorLight(appliance: a) }
        }
        .opacity(offline ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(a.name): \(store.mieleDisplay(a))")
    }

    @ViewBuilder private var content: some View {
        switch a.kind {
        case .oven, .steam:
            VStack(spacing: 7) {
                MieleDisplay(appliance: a)
                Handle()
                MieleWindow(appliance: a)
            }
        case .drawer:
            VStack(spacing: 6) {
                Handle().padding(.horizontal, 30)
                HStack {
                    Image(systemName: a.symbol).font(.caption).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text(drawerText).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 6)
                Spacer(minLength: 0)
            }
        case .dishwasher:
            VStack(spacing: 8) {
                Handle().padding(.horizontal, 40)
                MieleDisplay(appliance: a).padding(.horizontal, 40)
                Spacer(minLength: 0)
                Image(systemName: "m.circle")
                    .font(.caption).foregroundStyle(.white.opacity(0.18))
            }
        }
    }

    private var drawerText: String {
        if store.mieleOffline(a) { return "nicht verbunden" }
        if let t = store.mieleTemp(a.temp), store.mieleRunning(a) { return "\(t) °C" }
        return MieleConfig.statusText(store.mieleStatus(a))
    }
}

/// Griffleiste aus Edelstahl
private struct Handle: View {
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62), Color(white: 0.85)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: 5)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }
}

/// Kleines Display oben auf dem Gerät
struct MieleDisplay: View {
    @Environment(AppStore.self) private var store
    let appliance: MieleConfig.Appliance

    var body: some View {
        let a = appliance
        let running = store.mieleRunning(a)
        let finished = store.mieleFinished(a)
        let glow: Color = running ? a.color : finished ? .green : Color.white.opacity(0.45)
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: a.symbol).font(.system(size: 10, weight: .semibold))
                Text(store.mieleDisplay(a))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                if store.states[a.door]?.state == "on" {
                    Image(systemName: "door.left.hand.open").font(.system(size: 10)).foregroundStyle(.orange)
                }
                if store.states[a.light]?.state == "on" {
                    Image(systemName: "lightbulb.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                }
                if store.states[a.failure]?.state == "on" {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            .foregroundStyle(glow)
            if running, let p = store.mieleProgress(a) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(a.color).frame(width: max(3, g.size.width * p))
                    }
                }
                .frame(height: 2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: running ? a.color.opacity(0.35) : .clear, radius: 5)
    }
}

/// Garraum-Fenster: glüht beim Backen orange, beim Dampfgaren dampft es
struct MieleWindow: View {
    @Environment(AppStore.self) private var store
    let appliance: MieleConfig.Appliance
    @State private var pulse = false

    var body: some View {
        let a = appliance
        let running = store.mieleRunning(a)
        let lit = store.states[a.light]?.state == "on"
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.9))
            if running {
                RoundedRectangle(cornerRadius: 7)
                    .fill(RadialGradient(colors: [heat.opacity(pulse ? 0.75 : 0.5), heat.opacity(0.08)],
                                         center: .bottom, startRadius: 4, endRadius: 110))
            } else if lit {
                RoundedRectangle(cornerRadius: 7)
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.9, blue: 0.7).opacity(0.55), .clear],
                                         center: .top, startRadius: 4, endRadius: 110))
            }
            // Rost / Einschub
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1).padding(.horizontal, 8)
                Spacer()
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1).padding(.horizontal, 8)
                Spacer()
            }
            if running && a.kind == .steam {
                Image(systemName: "cloud.fill")
                    .font(.title2).foregroundStyle(.white.opacity(pulse ? 0.55 : 0.25))
                    .offset(y: pulse ? -8 : 4)
            }
            if running, let t = store.mieleTemp(a.temp) {
                Text("\(t)°")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: heat, radius: 6)
            }
            // Spiegelung auf dem Glas
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center))
            RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .onAppear { startPulse(running) }
        .onChange(of: running) { _, r in startPulse(r) }
    }

    private var heat: Color { appliance.kind == .steam ? Color(red: 0.55, green: 0.8, blue: 1) : Color(red: 1, green: 0.45, blue: 0.1) }

    private func startPulse(_ on: Bool) {
        if on { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true } }
        else { withAnimation(.default) { pulse = false } }
    }
}

/// Miele-Spülmaschinen werfen die Restzeit als Lichtpunkt auf den Boden – hier nachgebaut
private struct FloorLight: View {
    @Environment(AppStore.self) private var store
    let appliance: MieleConfig.Appliance

    var body: some View {
        let a = appliance
        let running = store.mieleRunning(a)
        let finished = store.mieleFinished(a)
        ZStack {
            if running || finished {
                Ellipse()
                    .fill(RadialGradient(colors: [(finished ? Color.green : a.color).opacity(0.45), .clear],
                                         center: .center, startRadius: 2, endRadius: 70))
                    .frame(width: 160, height: 26)
                Text(finished ? "Fertig" : store.mieleDisplay(a))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(finished ? Color.green : a.color)
            }
        }
        .frame(height: running || finished ? 28 : 0)
        .padding(.top, running || finished ? 4 : 0)
    }
}

// MARK: - Detail

struct MieleDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let appliance: MieleConfig.Appliance
    @State private var confirmOff = false

    private var a: MieleConfig.Appliance { appliance }
    private var running: Bool { store.mieleRunning(a) }
    private var canControl: Bool { store.isParent && store.activeKid == nil && !store.mieleOffline(a) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    MieleFront(appliance: a, height: a.kind == .drawer ? 110 : 220)
                        .frame(maxWidth: a.kind == .dishwasher ? .infinity : 260)
                        .padding(.top, 6)
                    if running || store.mieleFinished(a) { timerCard }
                    factsGrid
                    flags
                    if canControl { controls }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(a.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .confirmationDialog("\(a.name) ausschalten?", isPresented: $confirmOff, titleVisibility: .visible) {
                Button("Ausschalten", role: .destructive) { Task { await store.mieleCall("switch", "turn_off", a.power) } }
            } message: { Text("Ein laufendes Programm wird dabei beendet.") }
        }
    }

    // großer Ring mit Restzeit
    private var timerCard: some View {
        let p = store.mieleProgress(a) ?? 0
        let finished = store.mieleFinished(a)
        return HStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 10)
                Circle().trim(from: 0, to: p)
                    .stroke(finished ? Color.green : a.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: p)
                VStack(spacing: 0) {
                    if finished {
                        Image(systemName: "checkmark").font(.title2.weight(.bold)).foregroundStyle(.green)
                    } else if let m = store.mieleRemaining(a) {
                        Text(DurationText.minutes(m)).font(.headline.monospacedDigit()).minimumScaleFactor(0.7)
                        Text("übrig").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("\(Int(p * 100)) %").font(.headline.monospacedDigit())
                    }
                }
                .padding(8)
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(finished ? "Fertig" : MieleConfig.statusText(store.mieleStatus(a))).font(.title3.weight(.bold))
                let prog = store.mieleText(a.program)
                if !prog.isEmpty { Text(prog).font(.subheadline) }
                let phase = store.mieleText(a.phase)
                if running, !phase.isEmpty, phase != prog { Text(phase).font(.subheadline).foregroundStyle(.secondary) }
                if let end = store.mieleEnd(a), end > Date() {
                    Label("fertig um \(end.formatted(date: .omitted, time: .shortened))", systemImage: "flag.checkered")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private struct Fact: Identifiable {
        let symbol: String
        let title: String
        let value: String
        var id: String { title }
    }

    private var facts: [Fact] {
        var f: [Fact] = []
        let t = store.mieleTemp(a.temp)
        let z = store.mieleTemp(a.target)
        if let t, t > 0 {
            let v = (z ?? 0) > 0 ? "\(t) → \(z!) °C" : "\(t) °C"
            f.append(Fact(symbol: "thermometer.medium", title: "Temperatur", value: v))
        }
        if let c = store.mieleTemp(a.core), c > 0 {
            let cz = store.mieleTemp(a.coreTarget) ?? 0
            f.append(Fact(symbol: "thermometer.variable.and.figure", title: "Kerntemperatur",
                          value: cz > 0 ? "\(c) → \(cz) °C" : "\(c) °C"))
        }
        if let s = store.mieleTime(a.startedAt), running {
            f.append(Fact(symbol: "play.circle", title: "Gestartet", value: s.formatted(date: .omitted, time: .shortened)))
        }
        if store.mieleStatus(a) == "programmed_waiting_to_start", let s = store.mieleTime(a.startsAt) {
            f.append(Fact(symbol: "clock.arrow.circlepath", title: "Startet um", value: s.formatted(date: .omitted, time: .shortened)))
        }
        if let w = store.mieleNumber(a.water) {
            f.append(Fact(symbol: "drop.fill", title: "Wasser", value: String(format: "%.0f l", w)))
        }
        if let e = store.mieleNumber(a.energy) {
            f.append(Fact(symbol: "bolt.fill", title: "Strom", value: String(format: "%.2f kWh", e).replacingOccurrences(of: ".", with: ",")))
        }
        if f.isEmpty && !running {
            f.append(Fact(symbol: "power", title: "Status", value: MieleConfig.statusText(store.mieleStatus(a))))
        }
        return f
    }

    private var factsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(facts) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Label(f.title, systemImage: f.symbol).font(.caption).foregroundStyle(.secondary)
                    Text(f.value).font(.headline.monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder private var flags: some View {
        let door = store.states[a.door]?.state == "on"
        let fail = store.states[a.failure]?.state == "on"
        let info = store.states[a.info]?.state == "on"
        let remote = store.states[a.remote]?.state == "on"
        VStack(alignment: .leading, spacing: 8) {
            if fail { Label("Das Gerät meldet eine Störung", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if info { Label("Hinweis am Gerät – bitte aufs Display schauen", systemImage: "info.circle.fill").foregroundStyle(.orange) }
            if door { Label("Tür ist offen", systemImage: "door.left.hand.open").foregroundStyle(.orange) }
            Label(remote ? "Fernsteuerung am Gerät erlaubt" : "Fernsteuerung am Gerät aus – Start nur direkt am Gerät",
                  systemImage: remote ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if store.available(a.light) {
                    let lit = store.states[a.light]?.state == "on"
                    Button { Task { await store.mieleCall("light", lit ? "turn_off" : "turn_on", a.light) } } label: {
                        Label(lit ? "Licht aus" : "Licht an", systemImage: lit ? "lightbulb.fill" : "lightbulb")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(lit ? .yellow : .gray)
                }
                if store.available(a.start) && !running {
                    Button { Task { await store.mieleCall("button", "press", a.start) } } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(a.color)
                }
                if store.available(a.stop) && running {
                    Button { Task { await store.mieleCall("button", "press", a.stop) } } label: {
                        Label("Stopp", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.red)
                }
            }
            if store.states[a.power]?.state == "on" {
                Button(role: .destructive) { confirmOff = true } label: {
                    Label("Ausschalten", systemImage: "power").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
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
