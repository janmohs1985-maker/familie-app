import SwiftUI

// MARK: - Vitrinen-Licht im Keller-Flur (DMX über ESPHome)
//
// Links 4 LED-Streifen (esp-home05), rechts 8 (esp-home03). Effekte laufen in Home Assistant
// (script.kallax_effekt), damit sie auch beim Bewegungsmelder ohne App funktionieren.
// Welcher Effekt bei Bewegung kommt: input_select.kallax_bewegung_effekt.

enum VitrineConfig {
    struct Zone: Identifiable, Hashable {
        let entity: String
        let name: String
        var id: String { entity }
    }
    static let left: [Zone] = (1...4).map { Zone(entity: "light.esp_home05_dmx_dmx_zone_\($0)", name: "Fach \($0)") }
    static let right: [Zone] = (1...8).map { Zone(entity: "light.esp_home03_dmx_dmx_zone_\($0)", name: "Fach \($0)") }
    static var all: [Zone] { left + right }

    static let effectScript = "script.kallax_effekt"
    static let stopScript = "kallax_stopp"
    static let running = "input_text.kallax_laufender_effekt"
    static let motionEffect = "input_select.kallax_bewegung_effekt"
    static let brightness = "input_number.legoschrank_helligkeit"
    static let speed = "input_number.legoschrank_speed"

    struct Effect: Identifiable, Hashable {
        let key: String
        let name: String
        let symbol: String
        let colors: [Color]
        let info: String
        var id: String { key }
    }

    static let effects: [Effect] = [
        Effect(key: "normal", name: "Normal", symbol: "lightbulb.fill",
               colors: [Color(red: 1, green: 0.85, blue: 0.6)], info: "Warmweiß, einfach an"),
        Effect(key: "eigene", name: "Meine Farben", symbol: "paintpalette.fill",
               colors: [.pink, .teal, .orange, .purple], info: "So wie du die Fächer eingestellt hast"),
        Effect(key: "regenbogen", name: "Regenbogen", symbol: "rainbow",
               colors: [.red, .orange, .yellow, .green, .blue, .purple], info: "Alle Farben wandern langsam weiter"),
        Effect(key: "welle", name: "Farbwelle", symbol: "water.waves",
               colors: [.blue, .teal, .green, .blue], info: "Helligkeit läuft als Welle durch die Fächer"),
        Effect(key: "atmen", name: "Atmen", symbol: "lungs.fill",
               colors: [.indigo, .purple.opacity(0.4), .indigo], info: "Alle pulsieren ruhig in einer Farbe"),
        Effect(key: "lauflicht", name: "Lauflicht", symbol: "arrow.right.circle.fill",
               colors: [.blue.opacity(0.2), .cyan, .blue.opacity(0.2)], info: "Ein helles Fach wandert von Fach zu Fach"),
        Effect(key: "funkeln", name: "Funkeln", symbol: "sparkles",
               colors: [.indigo.opacity(0.3), .yellow, .pink, .indigo.opacity(0.3)], info: "Zufällige Fächer blitzen bunt auf"),
        Effect(key: "kamin", name: "Kaminfeuer", symbol: "flame.fill",
               colors: [.red, .orange, .yellow, .orange], info: "Warmes Flackern in Rot und Orange"),
        Effect(key: "polarlicht", name: "Polarlicht", symbol: "moon.stars.fill",
               colors: [.green, .teal, .purple, .green], info: "Grün, Türkis und Lila ziehen langsam"),
        Effect(key: "party", name: "Party", symbol: "party.popper.fill",
               colors: [.pink, .yellow, .cyan, .green, .red], info: "Schnelle bunte Wechsel"),
        Effect(key: "ambient", name: "Ambient (alt)", symbol: "wand.and.stars",
               colors: [.white, .blue, .pink], info: "Der bisherige Effekt mit Blitz-Intro"),
    ]

    static func effect(_ key: String) -> Effect? { effects.first { $0.key == key } }
}

@MainActor
extension AppStore {
    var vitrineEffectRunning: String? {
        let s = states[VitrineConfig.running]?.state ?? ""
        guard states[VitrineConfig.effectScript]?.state == "on" || s == "normal" || s == "eigene",
              VitrineConfig.effect(s) != nil else { return nil }
        return s
    }
    var vitrineAnyOn: Bool { VitrineConfig.all.contains { states[$0.entity]?.state == "on" } }

    func vitrineStart(_ key: String) async {
        do {
            try await client.call("script", "turn_on", ["entity_id": VitrineConfig.effectScript, "variables": ["effekt": key]])
            try? await Task.sleep(for: .milliseconds(900))
            await refreshStates()
        } catch { report(error) }
    }

    /// Effekt anhalten (Lichter bleiben, wie sie sind – oder aus)
    func vitrineStop(off: Bool) async {
        do {
            try await client.call("script", VitrineConfig.stopScript, ["ausschalten": off])
            try? await Task.sleep(for: .milliseconds(off ? 2200 : 500))
            await refreshStates()
        } catch { report(error) }
    }

    func vitrineToggle(_ z: VitrineConfig.Zone) async {
        do {
            if vitrineEffectRunning != nil { await vitrineStop(off: false) }
            try await client.call("light", "toggle", ["entity_id": z.entity])
            try? await Task.sleep(for: .milliseconds(500))
            await refreshStates()
        } catch { report(error) }
    }

    func vitrineFind(_ z: VitrineConfig.Zone) async {
        if vitrineEffectRunning != nil { await vitrineStop(off: false) }
        do { try await client.call("light", "turn_on", ["entity_id": z.entity, "flash": "short"]) } catch { report(error) }
    }

    func vitrineSetNumber(_ entity: String, _ value: Double) async {
        do {
            try await client.call("input_number", "set_value", ["entity_id": entity, "value": value])
            await refreshStates()
        } catch { report(error) }
    }

    func vitrineMotionEffect(_ key: String) async {
        do {
            try await client.call("input_select", "select_option", ["entity_id": VitrineConfig.motionEffect, "option": key])
            await refreshStates()
        } catch { report(error) }
    }
}

struct VitrinesView: View {
    @Environment(AppStore.self) private var store
    @State private var lightSheet: AppControl?
    @State private var brightness: Double = 80
    @State private var speed: Double = 20

    private let effectColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var running: String? { store.vitrineEffectRunning }
    private var motionKey: String { store.states[VitrineConfig.motionEffect]?.state ?? "normal" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ErrorBanner()
                header
                cabinets
                effectsSection
                settingsSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Vitrinen-Licht")
        .refreshable { await store.refreshStates() }
        .sheet(item: $lightSheet) { c in LightSheet(control: c).presentationDetents([.medium, .large]) }
        .onAppear {
            brightness = Double(store.states[VitrineConfig.brightness]?.state ?? "") ?? 80
            speed = Double(store.states[VitrineConfig.speed]?.state ?? "") ?? 20
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.vitrineAnyOn ? "An" : "Aus").font(.title3.weight(.bold))
                if let r = running, let e = VitrineConfig.effect(r) {
                    Label(e.name, systemImage: e.symbol).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Kein Effekt").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if running != nil && running != "normal" && running != "eigene" {
                Button { Task { await store.vitrineStop(off: false) } } label: {
                    Label("Effekt stoppen", systemImage: "pause.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            Button {
                Task {
                    if store.vitrineAnyOn { await store.vitrineStop(off: true) } else { await store.vitrineStart("normal") }
                }
            } label: {
                Image(systemName: "power")
                    .font(.headline)
                    .foregroundStyle(store.vitrineAnyOn ? Color.black.opacity(0.75) : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(store.vitrineAnyOn ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.vitrineAnyOn ? "Alles aus" : "Einschalten")
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Schränke

    private var cabinets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FÄCHER").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            HStack(alignment: .top, spacing: 12) {
                cabinet("Links", VitrineConfig.left, columns: 2)
                cabinet("Rechts", VitrineConfig.right, columns: 4)
            }
            Text("Antippen = an/aus · lange drücken = Farbe, Helligkeit oder „Finden“ (das Fach blinkt kurz). Beim Einstellen einzelner Fächer stoppt ein laufender Effekt. Rechts ganz links oben hat noch kein Licht.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func cabinet(_ title: String, _ zones: [VitrineConfig.Zone], columns: Int) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: columns)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(zones) { z in ZoneTile(zone: z) }
            }
            .padding(6)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: columns == 2 ? 120 : .infinity)
    }

    // MARK: Effekte

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EFFEKTE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            LazyVGrid(columns: effectColumns, spacing: 10) {
                ForEach(VitrineConfig.effects) { e in
                    Button { Task { await store.vitrineStart(e.key) } } label: {
                        EffectCard(effect: e, active: running == e.key, motion: motionKey == e.key)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Einstellungen

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EINSTELLUNGEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 14) {
                Picker(selection: Binding(get: { motionKey }, set: { k in Task { await store.vitrineMotionEffect(k) } })) {
                    ForEach(VitrineConfig.effects) { e in Label(e.name, systemImage: e.symbol).tag(e.key) }
                } label: {
                    Label("Bei Bewegung", systemImage: "figure.walk.motion")
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Helligkeit", systemImage: "sun.max")
                        Spacer()
                        Text("\(Int(brightness)) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $brightness, in: 1...100, step: 1, onEditingChanged: { editing in
                        if !editing { Task { await store.vitrineSetNumber(VitrineConfig.brightness, brightness) } }
                    })
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Tempo der Effekte", systemImage: "hare")
                        Spacer()
                        Text(speed < 20 ? "langsam" : speed < 40 ? "mittel" : "schnell").foregroundStyle(.secondary)
                    }
                    Slider(value: $speed, in: 5...60, step: 1, onEditingChanged: { editing in
                        if !editing { Task { await store.vitrineSetNumber(VitrineConfig.speed, speed) } }
                    })
                }
                Text("Helligkeit und Tempo gelten beim nächsten Start eines Effekts.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

/// Ein Fach: leuchtet in seiner aktuellen Farbe
struct ZoneTile: View {
    @Environment(AppStore.self) private var store
    let zone: VitrineConfig.Zone
    @State private var sheet: AppControl?

    private var state: HAState? { store.states[zone.entity] }
    private var on: Bool { state?.state == "on" }
    private var offline: Bool { state == nil || state?.state == "unavailable" }
    private var color: Color {
        guard on, let rgb = state?.attr("rgb_color")?.array?.compactMap(\.double), rgb.count == 3 else { return Color(.systemGray3) }
        return Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
    }
    private var level: Double {
        guard on, let b = state?.attr("brightness")?.double else { return 0 }
        return 0.35 + 0.65 * b / 255
    }
    private var control: AppControl {
        AppControl(uid: "vitrine:" + zone.entity, name: zone.name, entity: zone.entity, script: nil, kids: [],
                   confirm: false, from: nil, to: nil, sort: 0)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(on ? AnyShapeStyle(color.opacity(level).gradient) : AnyShapeStyle(Color(.systemGray4)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .shadow(color: on ? color.opacity(0.7) : .clear, radius: 6)
            .aspectRatio(0.8, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Text(zone.name.replacingOccurrences(of: "Fach ", with: ""))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .shadow(radius: on ? 2 : 0)
                    .padding(4)
            }
            .opacity(offline ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture { Task { await store.vitrineToggle(zone) } }
            .contextMenu {
                Button { sheet = control } label: { Label("Farbe & Helligkeit", systemImage: "paintpalette") }
                Button { Task { await store.vitrineFind(zone) } } label: { Label("Finden (blinkt)", systemImage: "light.beacon.max") }
            }
            .sheet(item: $sheet) { c in
                LightSheet(control: c)
                    .presentationDetents([.medium, .large])
                    .task { if store.vitrineEffectRunning != nil { await store.vitrineStop(off: false) } }
            }
            .animation(.easeInOut(duration: 0.6), value: state?.attr("rgb_color"))
            .accessibilityLabel("\(zone.name), \(on ? "an" : "aus")")
    }
}

/// Effekt-Kachel mit kleiner Farbvorschau (bewegt sich, wenn der Effekt läuft)
struct EffectCard: View {
    let effect: VitrineConfig.Effect
    let active: Bool
    let motion: Bool
    @State private var shift = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: effect.colors.count > 1 ? effect.colors : effect.colors + effect.colors,
                                     startPoint: shift ? .trailing : .leading, endPoint: shift ? .leading : .trailing))
                .frame(height: 30)
                .overlay(Image(systemName: effect.symbol).font(.subheadline.weight(.bold)).foregroundStyle(.white).shadow(radius: 2))
            HStack(spacing: 4) {
                Text(effect.name).font(.subheadline.weight(.semibold))
                if motion {
                    Image(systemName: "figure.walk.motion").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("bei Bewegung")
                }
            }
            Text(effect.info).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? Color.accentColor : .clear, lineWidth: 2))
        .onAppear { if active { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { shift = true } } }
        .onChange(of: active) { _, a in
            if a { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { shift = true } }
            else { withAnimation(.default) { shift = false } }
        }
    }
}
