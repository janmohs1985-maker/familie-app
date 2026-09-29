import SwiftUI
import UIKit

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

// MARK: - Aufbau der Schränke (gerade von vorne, Maße aus dem Plan)

struct VitrineDoor: Identifiable, Hashable {
    enum Kind { case glass, decor, noLight, open }
    /// Fächer ohne Licht (Deko-Tür, offenes Fach) – nicht antippbar
    var inactive: Bool { kind == .decor || kind == .open }
    let id: String
    let kind: Kind
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
}

enum VitrineLayout {
    /// Schrank rechts, schematisch von vorne: gleiche Fächer sind gleich groß
    /// (Spalten B–E gleich breit, alle unteren Türen gleich hoch, Böden auf einer Linie).
    static let rightSize = CGSize(width: 688, height: 480)
    static let right: [VitrineDoor] = [
        VitrineDoor(id: "A1", kind: .noLight, x: 0, y: 0, w: 120, h: 160),
        VitrineDoor(id: "A2", kind: .glass, x: 0, y: 160, w: 120, h: 160),
        VitrineDoor(id: "A3", kind: .glass, x: 0, y: 320, w: 120, h: 160),
        VitrineDoor(id: "B1", kind: .glass, x: 122, y: 220, w: 140, h: 100),
        VitrineDoor(id: "B2", kind: .decor, x: 122, y: 320, w: 140, h: 160),
        VitrineDoor(id: "C1", kind: .glass, x: 264, y: 220, w: 140, h: 100),
        VitrineDoor(id: "C2", kind: .glass, x: 264, y: 320, w: 140, h: 160),
        VitrineDoor(id: "D1", kind: .glass, x: 406, y: 220, w: 140, h: 100),
        VitrineDoor(id: "D2", kind: .decor, x: 406, y: 320, w: 140, h: 160),
        VitrineDoor(id: "E1", kind: .glass, x: 548, y: 120, w: 140, h: 200),
        VitrineDoor(id: "E2", kind: .glass, x: 548, y: 320, w: 140, h: 160),
    ]
    /// Korpus-Spalten (für die schmale Kante oben/rechts)
    static let rightColumns: [CGRect] = [
        CGRect(x: 0, y: 0, width: 120, height: 480), CGRect(x: 122, y: 220, width: 140, height: 260),
        CGRect(x: 264, y: 220, width: 140, height: 260), CGRect(x: 406, y: 220, width: 140, height: 260),
        CGRect(x: 548, y: 120, width: 140, height: 360),
    ]
    /// Regal links: Treppe aus gleich großen Würfeln (Spalte 1–4 hat 1–4 Fächer).
    /// Glastüren mit Licht: Spalte 3 unten + oben, Spalte 4 zweites + oberstes Fach.
    static let leftSize = CGSize(width: 406, height: 406)
    private static func cube(_ id: String, _ kind: VitrineDoor.Kind, col: Int, row: Int) -> VitrineDoor {
        VitrineDoor(id: id, kind: kind, x: CGFloat(col - 1) * 102, y: CGFloat(4 - row) * 102, w: 100, h: 100)
    }
    static let left: [VitrineDoor] = [
        cube("O1", .open, col: 1, row: 1),
        cube("O2", .open, col: 2, row: 1),
        cube("O3", .open, col: 2, row: 2),
        cube("L4", .glass, col: 3, row: 1),
        cube("O4", .open, col: 3, row: 2),
        cube("L2", .glass, col: 3, row: 3),
        cube("O5", .open, col: 4, row: 1),
        cube("L3", .glass, col: 4, row: 2),
        cube("O6", .open, col: 4, row: 3),
        cube("L1", .glass, col: 4, row: 4),
    ]
    static let leftColumns: [CGRect] = (1...4).map { c in
        CGRect(x: CGFloat(c - 1) * 102, y: CGFloat(4 - c) * 102, width: 100, height: CGFloat(c) * 102 - 2)
    }

    static let mappingEntity = "input_text.vitrine_zuordnung"

    /// Zuordnung Tür → Licht laut Jans Plan (Zahl = DMX-Zone von esp-home03).
    /// Lässt sich in der App unter „Licht zuordnen“ ändern.
    static let defaultMapping: [String: String] = {
        let right: [String: Int] = ["C2": 1, "C1": 2, "D1": 3, "B1": 4, "E2": 5, "E1": 6, "A2": 7, "A3": 8]
        var m: [String: String] = [:]
        for (door, zone) in right { m[door] = "light.esp_home03_dmx_dmx_zone_\(zone)" }
        for (i, id) in ["L1", "L2", "L3", "L4"].enumerated() { m[id] = VitrineConfig.left[i].entity }
        return m
    }()
}

@MainActor
extension AppStore {
    /// Tür → Licht-Entität. Gespeichert als "A2=light.xyz;A3=light.abc" in input_text.vitrine_zuordnung.
    var vitrineMapping: [String: String] {
        var m = VitrineLayout.defaultMapping
        let raw = states[VitrineLayout.mappingEntity]?.state ?? ""
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                let short = kv[1]
                m[kv[0]] = short.hasPrefix("light.") ? short : "light.esp_" + short
            }
        }
        return m
    }

    func vitrineAssign(door: String, entity: String) async {
        var m = vitrineMapping
        // ein Licht gehört nur zu einer Tür
        for (k, v) in m where v == entity && k != door { m[k] = nil }
        m[door] = entity
        let value = m.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "light.esp_", with: ""))" }
            .joined(separator: ";")
        do {
            try await client.call("input_text", "set_value", ["entity_id": VitrineLayout.mappingEntity, "value": value])
            await refreshStates()
        } catch { report(error) }
    }

    func vitrineColor(_ entity: String) -> Color? {
        guard states[entity]?.state == "on" else { return nil }
        if let rgb = states[entity]?.attr("rgb_color")?.array?.compactMap(\.double), rgb.count == 3 {
            return Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
        }
        return Color(red: 1, green: 0.8, blue: 0.5)
    }

    func vitrineSet(_ entity: String, _ data: [String: Any]) async {
        if vitrineEffectRunning != nil { await vitrineStop(off: false) }
        var d = data
        d["entity_id"] = entity
        do {
            try await client.call("light", "turn_on", d)
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }

    func vitrineOff(_ entity: String) async {
        if vitrineEffectRunning != nil { await vitrineStop(off: false) }
        do {
            try await client.call("light", "turn_off", ["entity_id": entity])
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }
}

/// Schrank gerade von vorne: klare Linien, LED-Streifen oben in der Tür, Glas nur zart eingefärbt
struct CabinetDrawing: View {
    @Environment(AppStore.self) private var store
    let doors: [VitrineDoor]
    let columns: [CGRect]
    let size: CGSize
    @Binding var selected: String?

    var body: some View {
        GeometryReader { g in
            let k = min(g.size.width / size.width, g.size.height / size.height)
            ZStack(alignment: .topLeading) {
                ForEach(columns.indices, id: \.self) { i in
                    let c = columns[i]
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(.systemGray6))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(.systemGray3), lineWidth: 1))
                        .frame(width: c.width * k, height: c.height * k)
                        .offset(x: c.minX * k + 4, y: c.minY * k - 4)
                }
                ForEach(doors) { d in
                    DoorView(door: d, selected: selected == d.id)
                        .frame(width: d.w * k - 2, height: d.h * k - 2)
                        .offset(x: d.x * k, y: d.y * k)
                        .onTapGesture { if !d.inactive { withAnimation(.snappy) { selected = d.id } } }
                        .contextMenu { if d.kind == .glass { quickMenu(d) } }
                }
            }
            .frame(width: size.width * k, height: size.height * k, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
    }

    /// Lang drücken auf ein Fach: schnell schalten, Farbe und Helligkeit wählen
    @ViewBuilder
    private func quickMenu(_ d: VitrineDoor) -> some View {
        if let e = store.vitrineMapping[d.id] {
            let on = store.states[e]?.state == "on"
            Section("Fach \(d.id) · \(on ? "an" : "aus")") {
                Button {
                    selected = d.id
                    Task { if on { await store.vitrineOff(e) } else { await store.vitrineSet(e, [:]) } }
                } label: {
                    Label(on ? "Ausschalten" : "Einschalten", systemImage: on ? "lightbulb.slash" : "lightbulb.fill")
                }
            }
            Menu {
                ForEach(VitrineSwatches.all.indices, id: \.self) { i in
                    let sw = VitrineSwatches.all[i]
                    Button {
                        selected = d.id
                        Task { await store.vitrineSet(e, sw.2) }
                    } label: {
                        Label { Text(sw.0) } icon: { Image(uiImage: VitrineSwatches.dot(sw.1)) }
                    }
                }
            } label: {
                Label("Farbe", systemImage: "paintpalette")
            }
            Menu {
                ForEach([100, 75, 50, 25, 10], id: \.self) { pct in
                    Button("\(pct) %") {
                        selected = d.id
                        Task { await store.vitrineSet(e, ["brightness_pct": pct]) }
                    }
                }
            } label: {
                Label("Helligkeit", systemImage: "sun.max")
            }
            Button {
                Task { await store.vitrineFind(VitrineConfig.Zone(entity: e, name: d.id)) }
            } label: {
                Label("Finden (blinken)", systemImage: "light.beacon.max")
            }
        } else {
            Text("Fach \(d.id): noch kein Licht zugeordnet")
        }
    }
}

/// Farben für die Fächer (Kurzmenü und Fach-Karte)
enum VitrineSwatches {
    static let all: [(String, Color, [String: Any])] = [
        ("Warmweiß", Color(red: 0.96, green: 0.78, blue: 0.48), ["color_temp_kelvin": 2700]),
        ("Rot", Color(red: 0.9, green: 0.28, blue: 0.3), ["rgb_color": [255, 40, 50]]),
        ("Orange", Color(red: 0.94, green: 0.54, blue: 0.14), ["rgb_color": [255, 120, 20]]),
        ("Grün", Color(red: 0.17, green: 0.71, blue: 0.35), ["rgb_color": [30, 220, 70]]),
        ("Türkis", Color(red: 0.13, green: 0.72, blue: 0.78), ["rgb_color": [20, 210, 230]]),
        ("Blau", Color(red: 0.29, green: 0.39, blue: 1.0), ["rgb_color": [40, 60, 255]]),
        ("Lila", Color(red: 0.56, green: 0.36, blue: 0.94), ["rgb_color": [150, 60, 255]]),
        ("Pink", Color(red: 0.88, green: 0.27, blue: 0.48), ["rgb_color": [255, 40, 140]]),
    ]

    /// farbiger Punkt fürs Menü (Menüs zeigen SF-Symbole sonst nur einfarbig)
    static func dot(_ color: Color) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)).fill()
        }
        return img.withRenderingMode(.alwaysOriginal)
    }
}

struct DoorView: View {
    @Environment(AppStore.self) private var store
    let door: VitrineDoor
    let selected: Bool

    private var entity: String? { store.vitrineMapping[door.id] }
    private var color: Color? { entity.flatMap { store.vitrineColor($0) } }

    var body: some View {
        VStack(spacing: 3) {
            if door.kind == .glass {
                Capsule()
                    .fill(color ?? Color.clear)
                    .frame(height: 4)
                    .shadow(color: color ?? .clear, radius: 4)
                    .padding(.horizontal, 3)
            }
            glass
        }
        .padding(4)
        .background(door.inactive ? Color(.systemGray5) : Color(.systemBackground))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(.label).opacity(door.inactive ? 0.25 : 0.8), lineWidth: door.inactive ? 1 : 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0)
                .padding(-3)
        )
        .animation(.easeInOut(duration: 0.4), value: color)
        .accessibilityElement()
        .accessibilityLabel(door.kind == .decor ? "Dekortür" : door.kind == .open ? "offenes Fach" : "Fach \(door.id), \(color == nil ? "aus" : "an")")
        .accessibilityAddTraits(door.inactive ? [] : .isButton)
    }

    @ViewBuilder
    private var glass: some View {
        switch door.kind {
        case .decor, .open:
            Color(.systemGray6)
                .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(.systemGray4), lineWidth: 1))
        case .noLight:
            RoundedRectangle(cornerRadius: 1)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color(.systemGray3))
                .background(Color(.systemGray6))
        case .glass:
            if let color {
                LinearGradient(colors: [color.opacity(0.35), color.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(color.opacity(0.6), lineWidth: 1))
            } else {
                Color(.systemGray6)
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(.systemGray4), lineWidth: 1))
            }
        }
    }
}

struct VitrinesView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String? = "C2"
    @State private var brightness: Double = 80
    @State private var speed: Double = 20
    @State private var doorBrightness: Double = 80
    @State private var assigning = false

    private var running: String? { store.vitrineEffectRunning }
    private var motionKey: String { store.states[VitrineConfig.motionEffect]?.state ?? "normal" }
    private var allDoors: [VitrineDoor] { VitrineLayout.right + VitrineLayout.left }
    private var selectedDoor: VitrineDoor? { allDoors.first { $0.id == selected } }
    private var selectedEntity: String? { selected.flatMap { store.vitrineMapping[$0] } }
    private var onCount: Int { VitrineConfig.all.filter { store.states[$0.entity]?.state == "on" }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ErrorBanner()
                header
                cabinetCard("Schrank", VitrineLayout.right, VitrineLayout.rightColumns, VitrineLayout.rightSize)
                if selectedDoor != nil { doorPanel }
                cabinetCard("Regal", VitrineLayout.left, VitrineLayout.leftColumns, VitrineLayout.leftSize, maxWidth: 240)
                effectsSection
                settingsSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Vitrine")
        .refreshable { await store.refreshStates() }
        .sheet(isPresented: $assigning) {
            if let d = selected { VitrineAssignView(door: d) }
        }
        .onAppear {
            brightness = Double(store.states[VitrineConfig.brightness]?.state ?? "") ?? 80
            speed = Double(store.states[VitrineConfig.speed]?.state ?? "") ?? 20
            syncDoorBrightness()
        }
        .onChange(of: selected) { _, _ in syncDoorBrightness() }
    }

    private func syncDoorBrightness() {
        if let e = selectedEntity, let b = store.states[e]?.attr("brightness")?.double { doorBrightness = (b / 255 * 100).rounded() }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(onCount) von \(VitrineConfig.all.count) an").font(.headline)
                if let r = running, let e = VitrineConfig.effect(r) {
                    Label(e.name, systemImage: e.symbol).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Kein Effekt").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { if store.vitrineAnyOn { await store.vitrineStop(off: true) } else { await store.vitrineStart("normal") } }
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

    private func cabinetCard(_ title: String, _ doors: [VitrineDoor], _ cols: [CGRect], _ size: CGSize, maxWidth: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if title == "Schrank" {
                    Text("Fach lange drücken für Schnellmenü").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            CabinetDrawing(doors: doors, columns: cols, size: size, selected: $selected)
                .frame(maxWidth: maxWidth ?? .infinity)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Ausgewählte Tür

    private static let swatches = VitrineSwatches.all

    @ViewBuilder
    private var doorPanel: some View {
        if let d = selectedDoor {
            VStack(alignment: .leading, spacing: 12) {
                if d.kind == .noLight {
                    Text("Oben links").font(.headline)
                    Text("Diese Tür hat noch kein Licht.").font(.subheadline).foregroundStyle(.secondary)
                } else if let e = selectedEntity {
                    let on = store.states[e]?.state == "on"
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fach \(d.id)").font(.headline)
                            Text(on ? "an · \(Int(doorBrightness)) %" : "aus").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("An", isOn: Binding(get: { on }, set: { v in
                            Task { if v { await store.vitrineSet(e, [:]) } else { await store.vitrineOff(e) } }
                        }))
                        .labelsHidden()
                    }
                    HStack(spacing: 10) {
                        ForEach(Self.swatches.indices, id: \.self) { i in
                            let sw = Self.swatches[i]
                            Button { Task { await store.vitrineSet(e, sw.2) } } label: {
                                Circle().fill(sw.1).frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(sw.0)
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: $doorBrightness, in: 1...100, step: 1, onEditingChanged: { editing in
                            if !editing { Task { await store.vitrineSet(e, ["brightness_pct": Int(doorBrightness)]) } }
                        })
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button { Task { await store.vitrineFind(VitrineConfig.Zone(entity: e, name: d.id)) } } label: {
                            Label("Finden", systemImage: "light.beacon.max")
                        }
                        .buttonStyle(.bordered)
                        if store.isAdmin {
                            Button { assigning = true } label: {
                                Label("Licht zuordnen", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Effekte (große Karten zum Wischen)

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EFFEKTE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(VitrineConfig.effects) { e in
                        Button { Task { await store.vitrineStart(e.key) } } label: {
                            EffectCard(effect: e, active: running == e.key, motion: motionKey == e.key)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            VStack(alignment: .leading, spacing: 14) {
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
                        Label("Tempo", systemImage: "hare")
                        Spacer()
                        Text(speed < 20 ? "langsam" : speed < 40 ? "mittel" : "schnell").foregroundStyle(.secondary)
                    }
                    Slider(value: $speed, in: 5...60, step: 1, onEditingChanged: { editing in
                        if !editing { Task { await store.vitrineSetNumber(VitrineConfig.speed, speed) } }
                    })
                }
                Text(running == nil ? "Gilt für den nächsten Effekt und den Bewegungsmelder."
                                    : "Wird sofort übernommen – der laufende Effekt passt sich an.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            if running != nil && running != "normal" && running != "eigene" {
                Button { Task { await store.vitrineStop(off: false) } } label: {
                    Label("Effekt anhalten", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }
        }
    }

    // MARK: Einstellungen

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(selection: Binding(get: { motionKey }, set: { k in Task { await store.vitrineMotionEffect(k) } })) {
                ForEach(VitrineConfig.effects) { e in Label(e.name, systemImage: e.symbol).tag(e.key) }
            } label: {
                Label("Bei Bewegung", systemImage: "figure.walk.motion")
            }
            .pickerStyle(.menu)
            Text("Dieser Effekt startet, wenn der Bewegungsmelder im Keller-Flur auslöst.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Welches Licht steckt in dieser Tür? (Liste mit „Finden“ zum Ausprobieren)
struct VitrineAssignView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let door: String

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(VitrineConfig.all) { z in
                        let current = store.vitrineMapping[door] == z.entity
                        let usedBy = store.vitrineMapping.first { $0.value == z.entity && $0.key != door }?.key
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(z.entity.contains("home05") ? "Regal · \(z.name)" : "Schrank · \(z.name)")
                                if let usedBy { Text("gerade bei \(usedBy)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Finden") { Task { await store.vitrineFind(z) } }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button {
                                Task { await store.vitrineAssign(door: door, entity: z.entity); dismiss() }
                            } label: {
                                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(current ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dieser Tür zuordnen")
                        }
                    }
                } footer: {
                    Text("„Finden“ lässt das Licht kurz blinken. Dann das passende auswählen.")
                }
            }
            .navigationTitle("Licht für \(door)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// Effekt-Karte: große Farbvorschau, Name, kurze Beschreibung
struct EffectCard: View {
    let effect: VitrineConfig.Effect
    let active: Bool
    let motion: Bool
    @State private var shift = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: effect.colors.count > 1 ? effect.colors : effect.colors + effect.colors,
                                     startPoint: shift ? .trailing : .leading, endPoint: shift ? .leading : .trailing))
                .frame(height: 48)
                .overlay(Image(systemName: effect.symbol).font(.headline).foregroundStyle(.white).shadow(radius: 2))
            HStack(spacing: 4) {
                Text(effect.name).font(.subheadline.weight(.bold)).lineLimit(1)
                if motion {
                    Image(systemName: "figure.walk.motion").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("bei Bewegung")
                }
            }
            Text(effect.info).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(width: 140, height: 132, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(active ? Color.accentColor : .clear, lineWidth: 2.5))
        .onAppear { if active { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { shift = true } } }
        .onChange(of: active) { _, a in
            if a { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { shift = true } }
            else { withAnimation(.default) { shift = false } }
        }
    }
}
