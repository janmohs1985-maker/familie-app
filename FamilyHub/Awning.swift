import SwiftUI

// MARK: - Markise (ESPHome esp-home02)
//
// Position 0–100 % kommt von sensor.esp_home02_markise_markisenposition.
// Fahren über die ESPHome-Knöpfe, feste Positionen über script.familie_markise_position (fährt und hält an).
// Bei Wind über 30 km/h oder Regen fährt sie automatisch ein (Automation „Markise Steuerung“).

enum AwningConfig {
    static let position = "sensor.esp_home02_markise_markisenposition"
    static let extend = "button.esp_home02_markise_esphome_markise_ausfahren"
    static let retract = "button.esp_home02_markise_esphome_markise_einfahren"
    static let stop = "button.esp_home02_markise_esphome_markise_stop"
    static let positionScript = "familie_markise_position"
    static let weather = "weather.wetterstation_2"
}

@MainActor
extension AppStore {
    var awningPosition: Double? { Double(states[AwningConfig.position]?.state ?? "") }
    var awningOnline: Bool {
        let s = states[AwningConfig.extend]?.state
        return s != nil && s != "unavailable"
    }

    func awningPress(_ button: String) async {
        do {
            try await client.call("button", "press", ["entity_id": button])
            try? await Task.sleep(for: .milliseconds(600))
            await refreshStates()
        } catch { report(error) }
    }

    func awningGoTo(_ percent: Int) async {
        do {
            try await client.call("script", "turn_on", ["entity_id": "script." + AwningConfig.positionScript,
                                                       "variables": ["ziel": percent]])
        } catch { report(error) }
    }
}

struct AwningCard: View {
    @Environment(AppStore.self) private var store
    @State private var lastPos: Double?
    @State private var direction = 0      // 1 = fährt aus, -1 = fährt ein

    private var pos: Double { store.awningPosition ?? 0 }
    private var wind: Double? { store.states[AwningConfig.weather]?.attr("wind_speed")?.double }
    private var raining: Bool { store.states[AwningConfig.weather]?.state == "rainy" }

    private var statusText: String {
        guard store.awningOnline else { return "Steuerung offline" }
        if direction > 0 { return "Fährt aus …" }
        if direction < 0 { return "Fährt ein …" }
        if pos <= 1 { return "Eingefahren" }
        if pos >= 99 { return "Ganz ausgefahren" }
        return "\(Int(pos)) % ausgefahren"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Markise").font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(direction != 0 ? Color.orange : .secondary)
                }
                Spacer()
                weatherBadge
            }

            AwningDrawing(position: pos, sunny: !raining)
                .frame(height: 170)

            HStack(spacing: 10) {
                bigButton("Einfahren", "arrow.down.right.and.arrow.up.left") { await store.awningPress(AwningConfig.retract) }
                bigButton("Stopp", "stop.fill") { await store.awningPress(AwningConfig.stop) }
                bigButton("Ausfahren", "arrow.up.left.and.arrow.down.right") { await store.awningPress(AwningConfig.extend) }
            }

            HStack(spacing: 8) {
                ForEach([25, 50, 75, 100], id: \.self) { p in
                    Button { Task { await store.awningGoTo(p) } } label: {
                        Text("\(p) %")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(abs(pos - Double(p)) < 4 ? Color.white : Color.primary)
                            .background(abs(pos - Double(p)) < 4 ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Fährt bei Wind über 30 km/h oder Regen automatisch ein.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .disabled(!store.awningOnline)
        .opacity(store.awningOnline ? 1 : 0.55)
        .onChange(of: store.awningPosition) { old, new in
            guard let old, let new else { direction = 0; return }
            direction = new > old + 0.5 ? 1 : (new < old - 0.5 ? -1 : 0)
        }
    }

    @ViewBuilder
    private var weatherBadge: some View {
        if raining {
            Label("Regen", systemImage: "cloud.rain.fill").font(.caption.weight(.semibold)).foregroundStyle(.blue)
        } else if let wind {
            Label("\(Int(wind)) km/h", systemImage: "wind")
                .font(.caption.weight(.semibold))
                .foregroundStyle(wind > 25 ? Color.orange : .secondary)
        }
    }

    private func bigButton(_ title: String, _ symbol: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.bordered)
    }
}

/// Seitenansicht: Hauswand, ausfahrender Stoff mit Streifen, Schatten auf der Terrasse
struct AwningDrawing: View {
    let position: Double      // 0–100
    let sunny: Bool

    var body: some View {
        GeometryReader { g in
            scene(AwningGeometry(size: g.size, position: position))
        }
        .animation(.easeInOut(duration: 1.0), value: position)
    }

    private func scene(_ m: AwningGeometry) -> some View {
        ZStack {
            // Himmel und Sonne
            if sunny {
                Circle().fill(Color.yellow.gradient)
                    .frame(width: 30, height: 30)
                    .position(x: m.w - 36, y: 28)
                    .shadow(color: .yellow.opacity(0.6), radius: 10)
            }
            // Schatten auf dem Boden
            Capsule()
                .fill(Color.black.opacity(0.12))
                .frame(width: max(6, m.reach * 0.95), height: 10)
                .position(x: m.wallX + m.reach * 0.55, y: m.groundY + 2)
            // Boden
            Rectangle().fill(Color.secondary.opacity(0.25))
                .frame(width: m.w, height: 3)
                .position(x: m.w / 2, y: m.groundY + 8)
            // Hauswand
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray4))
                .frame(width: 16, height: m.groundY - 6)
                .position(x: m.wallX - 8, y: (m.groundY + 6) / 2 + 2)
            // Kassette
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray2))
                .frame(width: 22, height: 14)
                .position(x: m.wallX + 6, y: m.topY)
            fabric(m)
            // Fallstange
            Capsule()
                .fill(Color(.systemGray))
                .frame(width: 8, height: 14)
                .position(x: m.tipX, y: m.tipY + 4)
                .opacity(m.reach > 4 ? 1 : 0)
        }
    }

    private func fabric(_ m: AwningGeometry) -> some View {
        let path = Path { p in
            p.move(to: CGPoint(x: m.wallX + 6, y: m.topY - 3))
            p.addLine(to: CGPoint(x: m.tipX, y: m.tipY - 3))
            p.addLine(to: CGPoint(x: m.tipX, y: m.tipY + 3))
            p.addLine(to: CGPoint(x: m.wallX + 6, y: m.topY + 3))
            p.closeSubpath()
        }
        let stripes = LinearGradient(
            stops: (0..<12).flatMap { i -> [Gradient.Stop] in
                let a = Double(i) / 12, b = Double(i + 1) / 12
                let c: Color = i % 2 == 0 ? .orange : Color(red: 1, green: 0.93, blue: 0.82)
                return [Gradient.Stop(color: c, location: a), Gradient.Stop(color: c, location: b)]
            },
            startPoint: .leading, endPoint: .trailing)
        return path.fill(stripes).overlay(path.stroke(Color.orange.opacity(0.6), lineWidth: 0.8))
    }
}

struct AwningGeometry {
    let w: CGFloat
    let h: CGFloat
    let wallX: CGFloat
    let topY: CGFloat
    let groundY: CGFloat
    let reach: CGFloat
    let tipX: CGFloat
    let tipY: CGFloat

    init(size: CGSize, position: Double) {
        w = size.width
        h = size.height
        wallX = 26
        topY = 34
        groundY = size.height - 14
        let maxReach: CGFloat = max(40, size.width - 80)
        let frac = CGFloat(min(max(position, 0), 100) / 100)
        reach = maxReach * frac
        tipX = 32 + reach
        tipY = 34 + reach * 0.22          // leicht geneigt
    }
}
