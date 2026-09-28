import SwiftUI

// MARK: - Esstischlampe (ESP32 über MQTT)
//
// An/Aus, heller/dunkler, warm/kalt, hoch/runter und seitlich aus-/einfahren.
// Die Fahr- und Dimm-Schalter laufen, solange sie „an“ sind – nochmal tippen (oder Stopp) hält an.
// Position kommt von sensor.esstischlampe_hohe / _auszug (0–100 %).

enum DiningLamp {
    static let power = "switch.esstischlampe"
    static let up = "switch.esstischlampe_hochfahren"
    static let down = "switch.esstischlampe_runterfahren"
    static let extend = "switch.esstischlampe_ausfahren"
    static let retract = "switch.esstischlampe_einfahren"
    static let brighter = "switch.esstischlampe_dimmen_nach_oben"
    static let darker = "switch.esstischlampe_dimmen_nach_unten"
    static let warm = "switch.esstischlampe_warmweiss"
    static let cold = "switch.esstischlampe_kaltweiss"
    static let height = "sensor.esstischlampe_hohe"
    static let width = "sensor.esstischlampe_auszug"
    static let dinner = "input_button.esstischlampe_position_dinner"

    static let movers = [up, down, extend, retract, brighter, darker]
    static let pairs: [String: String] = [up: down, down: up, extend: retract, retract: extend, brighter: darker, darker: brighter]
}

@MainActor
extension AppStore {
    func lampOn(_ e: String) -> Bool { states[e]?.state == "on" }

    /// Fahren/Dimmen starten – läuft es schon, wird angehalten. Die Gegenrichtung wird vorher gestoppt.
    func lampMove(_ e: String) async {
        do {
            if lampOn(e) {
                try await client.call("switch", "turn_off", ["entity_id": e])
            } else {
                if let other = DiningLamp.pairs[e], lampOn(other) {
                    try await client.call("switch", "turn_off", ["entity_id": other])
                }
                try await client.call("switch", "turn_on", ["entity_id": e])
            }
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }

    func lampStop() async {
        let running = DiningLamp.movers.filter { lampOn($0) }
        guard !running.isEmpty else { return }
        do {
            try await client.call("switch", "turn_off", ["entity_id": running])
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }

    func lampPulse(_ e: String) async {
        do {
            let domain = String(e.split(separator: ".").first ?? "switch")
            if domain == "input_button" {
                try await client.call("input_button", "press", ["entity_id": e])
            } else {
                try await client.call("switch", "turn_on", ["entity_id": e])
            }
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }

    func lampToggle() async {
        do {
            try await client.call("switch", lampOn(DiningLamp.power) ? "turn_off" : "turn_on", ["entity_id": DiningLamp.power])
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }
}

struct DiningLampCard: View {
    @Environment(AppStore.self) private var store
    @State private var pulse = false

    private var on: Bool { store.lampOn(DiningLamp.power) }
    private var offline: Bool {
        let p = store.states[DiningLamp.power]?.state
        return p == nil || p == "unavailable" || p == "unknown"
    }
    private var height: Double { Double(store.states[DiningLamp.height]?.state ?? "") ?? 0 }
    private var width: Double { Double(store.states[DiningLamp.width]?.state ?? "") ?? 0 }
    private var warmLight: Bool { !store.lampOn(DiningLamp.cold) }

    private var movingText: String? {
        if store.lampOn(DiningLamp.up) { return "Fährt hoch …" }
        if store.lampOn(DiningLamp.down) { return "Fährt runter …" }
        if store.lampOn(DiningLamp.extend) { return "Fährt aus …" }
        if store.lampOn(DiningLamp.retract) { return "Fährt ein …" }
        if store.lampOn(DiningLamp.brighter) { return "Wird heller …" }
        if store.lampOn(DiningLamp.darker) { return "Wird dunkler …" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Esstischlampe").font(.headline)
                    Text(movingText ?? (offline ? "Steuerung offline" : (on ? "An" : "Aus")))
                        .font(.caption).foregroundStyle(movingText != nil ? Color.orange : .secondary)
                }
                Spacer()
                Button { Task { await store.lampToggle() } } label: {
                    Image(systemName: "power")
                        .font(.headline)
                        .foregroundStyle(on ? Color.black.opacity(0.75) : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(on ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Ausschalten" : "Einschalten")
            }

            DiningLampDrawing(height: height, width: width, on: on, warm: warmLight, moving: movingText != nil)
                .frame(height: 200)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Höhe \(Int(height)) %")
                        Text("Auszug \(Int(width)) %")
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(8)
                }

            // Fahren
            HStack(spacing: 10) {
                controlGroup("Höhe") {
                    moveButton("arrow.up", DiningLamp.up, "Hochfahren")
                    moveButton("arrow.down", DiningLamp.down, "Runterfahren")
                }
                controlGroup("Breite") {
                    moveButton("arrow.left.and.right", DiningLamp.extend, "Ausfahren")
                    moveButton("arrow.right.and.line.vertical.and.arrow.left", DiningLamp.retract, "Einfahren")
                }
            }
            // Licht
            HStack(spacing: 10) {
                controlGroup("Helligkeit") {
                    moveButton("sun.min", DiningLamp.darker, "Dunkler")
                    moveButton("sun.max.fill", DiningLamp.brighter, "Heller")
                }
                controlGroup("Lichtfarbe") {
                    pulseButton("Warm", DiningLamp.warm, tint: .orange)
                    pulseButton("Kalt", DiningLamp.cold, tint: .blue)
                }
            }
            HStack(spacing: 10) {
                Button { Task { await store.lampStop() } } label: {
                    Label("Stopp", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.red)
                .disabled(movingText == nil)
                if store.states[DiningLamp.dinner] != nil {
                    Button { Task { await store.lampPulse(DiningLamp.dinner) } } label: {
                        Label("Essens-Position", systemImage: "fork.knife").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Antippen startet – nochmal antippen oder „Stopp“ hält an.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .disabled(offline)
        .opacity(offline ? 0.55 : 1)
    }

    private func controlGroup<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveButton(_ symbol: String, _ entity: String, _ label: String) -> some View {
        let active = store.lampOn(entity)
        return Button { Task { await store.lampMove(entity) } } label: {
            Image(systemName: active ? "stop.fill" : symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "\(label) anhalten" : label)
    }

    private func pulseButton(_ title: String, _ entity: String, tint: Color) -> some View {
        Button { Task { await store.lampPulse(entity) } } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Gezeichnete Lampe über dem Tisch – bewegt sich mit Höhe und Auszug
struct DiningLampDrawing: View {
    let height: Double      // 0–100, 100 = ganz oben
    let width: Double       // 0–100, 100 = ganz ausgefahren
    let on: Bool
    let warm: Bool
    let moving: Bool

    @State private var blink = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            let tableY = h - 34
            let topY: CGFloat = 10
            let lowest = tableY - 70            // tiefste Position
            let highest = topY + 36             // höchste Position
            let lampY = lowest - (lowest - highest) * CGFloat(min(max(height, 0), 100) / 100)
            let center: CGFloat = 110
            let extra = CGFloat(min(max(width, 0), 100) / 100) * min(90, (w - center - 40) / 2)
            let lampW = center + extra * 2
            let glow = warm ? Color(red: 1.0, green: 0.78, blue: 0.42) : Color(red: 0.82, green: 0.9, blue: 1.0)

            ZStack {
                // Decke
                Capsule().fill(Color.secondary.opacity(0.35))
                    .frame(width: w * 0.7, height: 4)
                    .position(x: w / 2, y: topY)

                // Lichtkegel
                if on {
                    Path { p in
                        p.move(to: CGPoint(x: w / 2 - lampW / 2 + 6, y: lampY + 6))
                        p.addLine(to: CGPoint(x: w / 2 + lampW / 2 - 6, y: lampY + 6))
                        p.addLine(to: CGPoint(x: w / 2 + lampW / 2 + 40, y: tableY))
                        p.addLine(to: CGPoint(x: w / 2 - lampW / 2 - 40, y: tableY))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [glow.opacity(0.55), glow.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    .blur(radius: 6)
                }

                // Seile
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Path { p in
                        p.move(to: CGPoint(x: w / 2 + side * 40, y: topY))
                        p.addLine(to: CGPoint(x: w / 2 + side * 40, y: lampY - 4))
                    }
                    .stroke(Color.secondary.opacity(0.6), lineWidth: 1.2)
                }

                // Lampe: Mittelteil + zwei ausfahrbare Seitenteile
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: lampW, height: 7)
                    .position(x: w / 2, y: lampY)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.9))
                    .frame(width: center, height: 11)
                    .position(x: w / 2, y: lampY)
                Capsule()
                    .fill(on ? AnyShapeStyle(glow) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: lampW - 8, height: 3)
                    .position(x: w / 2, y: lampY + 6)
                    .shadow(color: on ? glow : .clear, radius: 8)

                // Tisch
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.brown.opacity(0.7))
                    .frame(width: min(w * 0.8, 300), height: 8)
                    .position(x: w / 2, y: tableY)
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Rectangle().fill(Color.brown.opacity(0.55))
                        .frame(width: 6, height: 26)
                        .position(x: w / 2 + side * (min(w * 0.8, 300) / 2 - 18), y: tableY + 17)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: height)
            .animation(.easeInOut(duration: 0.8), value: width)
            .animation(.easeInOut(duration: 0.4), value: on)
            .opacity(moving && blink ? 0.85 : 1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { blink = true }
        }
    }
}
