import SwiftUI

// MARK: - Beschattung (Adaptive Cover Pro)
//
// Pausieren = „manuelle Übersteuerung“ aktivieren: die Beschattung bleibt stehen, wie sie ist,
// und die Automatik übernimmt nach Ablauf der Zeit wieder. Nichts fährt dabei.

enum ShadingConfig {
    struct Blind: Identifiable {
        let prefix: String
        let name: String
        let floor: String      // "EG" / "OG"
        let venetian: Bool     // Raffstore (mit Lamellen) oder Rollo
        var id: String { prefix }
        var auto: String { "switch.\(prefix)_automatic_control" }
        var override: String { "binary_sensor.\(prefix)_manual_override" }
        var overrideEnd: String { "sensor.\(prefix)_manual_override_end_time" }
        var reset: String { "button.\(prefix)_reset_manual_override" }
        var status: String { "sensor.\(prefix)_control_status" }
        var sun: String { "binary_sensor.\(prefix)_sun_infront" }
        var target: String { "sensor.\(prefix)_target_position" }
        var tilt: String { "sensor.\(prefix)_target_tilt" }
        var sunStart: String { "sensor.\(prefix)_start_sun" }
        var sunEnd: String { "sensor.\(prefix)_end_sun" }
    }
    static let blinds: [Blind] = [
        Blind(prefix: "eg_sud", name: "Süd – Schiebetür", floor: "EG", venetian: true),
        Blind(prefix: "eg_sud_festverglasung", name: "Süd – Festverglasung", floor: "EG", venetian: true),
        Blind(prefix: "eg_ost_ture", name: "Ost – Tür", floor: "EG", venetian: true),
        Blind(prefix: "eg_west_schiebeture", name: "West – Schiebetür", floor: "EG", venetian: true),
        Blind(prefix: "og_sud_schlafzimmer", name: "Schlafzimmer Süd", floor: "OG", venetian: false),
        Blind(prefix: "og_ost_schlafzimmer", name: "Schlafzimmer Ost", floor: "OG", venetian: false),
        Blind(prefix: "og_ost_elternbad", name: "Elternbad", floor: "OG", venetian: false),
        Blind(prefix: "og_sud_emma", name: "Emma Süd", floor: "OG", venetian: false),
        Blind(prefix: "og_west_emma", name: "Emma West", floor: "OG", venetian: false),
        Blind(prefix: "og_west_leoni", name: "Leoni West", floor: "OG", venetian: false),
        Blind(prefix: "og_nord_leoni", name: "Leoni Nord", floor: "OG", venetian: false),
        Blind(prefix: "og_nord_flur", name: "Flur OG", floor: "OG", venetian: false),
        Blind(prefix: "og_nord_kinderbad", name: "Kinderbad", floor: "OG", venetian: false),
    ]

    /// Beschattungen, deren Zielposition den Rollladen nicht in den Attributen nennt
    static let coverFallback: [String: String] = ["cover.kinderbad": "og_nord_kinderbad"]

    static func statusText(_ s: String) -> String {
        [
            "active": "Automatik aktiv", "sun_not_visible": "Keine Sonne auf dem Fenster",
            "automatic_control_off": "Automatik aus", "manual_override": "Pausiert",
            "outside_time_window": "Außerhalb der Zeit", "sunset": "Nach Sonnenuntergang",
            "climate": "Klimamodus", "weather_safety": "Wetterschutz", "motion": "Bewegung erkannt",
        ][s] ?? s.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

@MainActor
extension AppStore {
    func blindPausedUntil(_ b: ShadingConfig.Blind) -> Date? {
        guard states[b.override]?.state == "on" else { return nil }
        return HADate.parse(states[b.overrideEnd]?.state) ?? .distantFuture
    }
    func blindAutoOn(_ b: ShadingConfig.Blind) -> Bool { states[b.auto]?.state == "on" }
    func blindShading(_ b: ShadingConfig.Blind) -> Bool {
        blindAutoOn(b) && blindPausedUntil(b) == nil && states[b.sun]?.state == "on" && states[b.status]?.state == "active"
    }

    /// Automatik für die Beschattungen pausieren, ohne dass etwas fährt.
    /// Endzeit mit Zeitzone schicken (UTC „Z“) – ohne liest Adaptive Cover die Zeit als UTC.
    func pauseBlinds(_ blinds: [ShadingConfig.Blind], until end: Date) async {
        let ids = blinds.map(\.auto)
        do {
            _ = try await client.call("adaptive_cover_pro", "engage_manual_override",
                                      ["entity_id": ids, "end_time": HADate.iso.string(from: end)])
            try? await Task.sleep(for: .seconds(1))
            await refreshStates()
        } catch { report(error) }
    }

    /// Pause beenden – Automatik fährt beim nächsten Durchlauf wieder auf ihre Position
    func resumeBlinds(_ blinds: [ShadingConfig.Blind]) async {
        for b in blinds where states[b.reset] != nil {
            _ = try? await client.call("button", "press", ["entity_id": b.reset])
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshStates()
    }

    func setBlindAuto(_ b: ShadingConfig.Blind, _ on: Bool) async {
        await setSwitch(b.auto, on)
    }

    /// Welche Beschattungs-Automatik steuert diesen Rollladen? (steht in den Attributen der Zielposition)
    func blind(for cover: String) -> ShadingConfig.Blind? {
        if let p = ShadingConfig.coverFallback[cover] { return ShadingConfig.blinds.first { $0.prefix == p } }
        return ShadingConfig.blinds.first { b in
            guard let attrs = states[b.target]?.attributes else { return false }
            return attrs.values.contains { v in Self.jsonMentions(v, cover) }
        }
    }

    private static func jsonMentions(_ v: JSONValue, _ text: String) -> Bool {
        switch v {
        case .string(let s): return s == text || s.contains(text)
        case .array(let a): return a.contains { jsonMentions($0, text) }
        // Adaptive Cover nennt den Rollladen als Schlüssel, z. B. actual_positions = {"cover.wohnzimmer_sud": 18}
        case .object(let o): return o.keys.contains(text) || o.values.contains { jsonMentions($0, text) }
        default: return false
        }
    }

    // Lamellen
    func coverHasTilt(_ c: AppControl) -> Bool {
        guard c.domain == "cover", let sf = states[c.entity]?.attr("supported_features")?.int else { return false }
        return sf & 128 != 0
    }
    func coverTilt(_ c: AppControl) -> Int? { states[c.entity]?.attr("current_tilt_position")?.int }
    func coverTiltSet(_ c: AppControl, _ value: Int) async {
        do {
            _ = try await client.call("cover", "set_cover_tilt_position", ["entity_id": c.entity, "tilt_position": value])
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStates()
        } catch { report(error) }
    }
}

/// Automatik (Adaptive Cover Pro) direkt beim Rollladen: Status, an/aus, pausieren
struct ShadingControlSection: View {
    @Environment(AppStore.self) private var store
    let blind: ShadingConfig.Blind

    private var paused: Date? { store.blindPausedUntil(blind) }
    private var canEdit: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Beschattungs-Automatik", systemImage: "sun.max.trianglebadge.exclamationmark").font(.headline)
                Spacer()
            }
            Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            if canEdit {
                Toggle("Automatik", isOn: Binding(get: { store.blindAutoOn(blind) },
                                                  set: { on in Task { await store.setBlindAuto(blind, on) } }))
                if store.blindAutoOn(blind) {
                    if paused != nil {
                        Button { Task { await store.resumeBlinds([blind]) } } label: {
                            Label("Automatik jetzt fortsetzen", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        HStack(spacing: 8) {
                            pauseButton("1 Std.", hours: 1)
                            pauseButton("3 Std.", hours: 3)
                            pauseButton("Bis morgen", hours: nil)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusText: String {
        if !store.blindAutoOn(blind) { return "Automatik aus – der Rollladen bleibt, wie du ihn stellst." }
        if let p = paused {
            return p == .distantFuture ? "Pausiert" : "Pausiert bis \(p.formatted(date: .omitted, time: .shortened))"
        }
        let s = ShadingConfig.statusText(store.states[blind.status]?.state ?? "")
        return store.blindShading(blind) ? "Beschattet gerade · \(s)" : s
    }

    private func pauseButton(_ title: String, hours: Int?) -> some View {
        Button {
            let end: Date
            if let hours { end = Date().addingTimeInterval(Double(hours) * 3600) }
            else {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                end = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            }
            Task { await store.pauseBlinds([blind], until: end) }
        } label: {
            Text(title).font(.subheadline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Seite

struct ShadingView: View {
    @Environment(AppStore.self) private var store
    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                summaryCard
                ForEach(["EG", "OG"], id: \.self) { floor in
                    Card(title: floor == "EG" ? "Erdgeschoss (Raffstores)" : "Obergeschoss (Rollos)",
                         symbol: floor == "EG" ? "blinds.horizontal.closed" : "roller.shade.closed") {
                        VStack(spacing: 0) {
                            let list = ShadingConfig.blinds.filter { $0.floor == floor }
                            ForEach(list) { b in
                                BlindRow(blind: b, editable: isParent)
                                if b.id != list.last?.id { Divider().padding(.vertical, 8) }
                            }
                        }
                    }
                }
                Text("„Pausieren“ lässt die Beschattung, wo sie ist – nichts fährt. Danach übernimmt die Automatik wieder.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Beschattung")
        .refreshable { await store.refreshStates() }
    }

    private var summaryCard: some View {
        let all = ShadingConfig.blinds
        let shading = all.filter { store.blindShading($0) }.count
        let paused = all.filter { store.blindPausedUntil($0) != nil }
        let autoOn = all.filter { store.blindAutoOn($0) }
        return Card(title: "Übersicht", symbol: "sun.max.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: shading > 0 ? "sun.max.trianglebadge.exclamationmark.fill" : "sun.max")
                        .font(.system(size: 30)).foregroundStyle(shading > 0 ? Color.orange : Color.secondary)
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shading > 0 ? "\(shading) von \(all.count) beschatten gerade" : "Gerade wird nichts beschattet")
                            .font(.headline)
                        Text("\(autoOn.count) mit Automatik · \(paused.count) pausiert").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isParent {
                    HStack(spacing: 8) {
                        Menu {
                            Section("Alle Beschattungen pausieren") {
                                pauseButtons(autoOn)
                            }
                        } label: {
                            Label("Alle pausieren", systemImage: "pause.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(autoOn.isEmpty)
                        Button {
                            Task { await store.resumeBlinds(paused) }
                        } label: {
                            Label("Alle fortsetzen", systemImage: "play.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(paused.isEmpty)
                    }
                    Menu {
                        Section("Nur Erdgeschoss pausieren") { pauseButtons(autoOn.filter { $0.floor == "EG" }) }
                        Section("Nur Obergeschoss pausieren") { pauseButtons(autoOn.filter { $0.floor == "OG" }) }
                    } label: {
                        Label("Nur ein Stockwerk pausieren …", systemImage: "building.2").font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder private func pauseButtons(_ blinds: [ShadingConfig.Blind]) -> some View {
        ForEach(ShadingPause.options, id: \.title) { o in
            Button(o.title) { Task { await store.pauseBlinds(blinds, until: o.end()) } }
        }
    }
}

enum ShadingPause {
    struct Option { let title: String; let end: () -> Date }
    static let options: [Option] = [
        Option(title: "1 Stunde") { Date().addingTimeInterval(3600) },
        Option(title: "2 Stunden") { Date().addingTimeInterval(7200) },
        Option(title: "4 Stunden") { Date().addingTimeInterval(4 * 3600) },
        Option(title: "Bis heute Abend (20 Uhr)") {
            let d = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
            return d > Date() ? d : Date().addingTimeInterval(3600)
        },
        Option(title: "Bis morgen früh (7 Uhr)") {
            let t = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            return Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: t) ?? t
        },
    ]
}

struct BlindRow: View {
    @Environment(AppStore.self) private var store
    let blind: ShadingConfig.Blind
    let editable: Bool

    var body: some View {
        let autoOn = store.blindAutoOn(blind)
        let paused = store.blindPausedUntil(blind)
        let shading = store.blindShading(blind)
        let sunOn = store.states[blind.sun]?.state == "on"
        let status = store.states[blind.status]?.state ?? "unknown"
        let target = store.num(blind.target)
        let from = HADate.parse(store.states[blind.sunStart]?.state)
        let to = HADate.parse(store.states[blind.sunEnd]?.state)
        HStack(spacing: 12) {
            Image(systemName: blind.venetian ? (shading ? "blinds.horizontal.closed" : "blinds.horizontal.open")
                                             : (shading ? "roller.shade.closed" : "roller.shade.open"))
                .font(.title3)
                .foregroundStyle(shading ? Color.orange : (paused != nil ? Color.blue : Color.secondary))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(blind.name).font(.subheadline.weight(.semibold))
                    if sunOn { Image(systemName: "sun.max.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                Group {
                    if let paused {
                        Text(paused == .distantFuture ? "Pausiert (von Hand bedient)"
                                                      : "Pausiert bis \(paused.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.blue)
                    } else if !autoOn {
                        Text("Automatik aus").foregroundStyle(.secondary)
                    } else if shading, let target {
                        Text("Beschattet · Ziel \(Int(target)) %").foregroundStyle(.orange)
                    } else {
                        Text(ShadingConfig.statusText(status)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if let from, let to {
                    Text("Sonne heute \(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if editable {
                if paused != nil && store.states[blind.reset] != nil {
                    Button { Task { await store.resumeBlinds([blind]) } } label: {
                        Image(systemName: "play.fill").frame(width: 32, height: 30)
                    }
                    .buttonStyle(.bordered).tint(.blue)
                } else if autoOn {
                    Menu {
                        ForEach(ShadingPause.options, id: \.title) { o in
                            Button(o.title) { Task { await store.pauseBlinds([blind], until: o.end()) } }
                        }
                    } label: {
                        Image(systemName: "pause.fill").frame(width: 32, height: 30)
                    }
                    .buttonStyle(.bordered).tint(.orange)
                }
                Toggle("", isOn: Binding(get: { autoOn }, set: { v in Task { await store.setBlindAuto(blind, v) } }))
                    .labelsHidden()
            }
        }
    }
}

/// Kleines Abzeichen: Steuert gerade die Automatik diesen Rollladen?
struct ShadingBadge: View {
    @Environment(AppStore.self) private var store
    let blind: ShadingConfig.Blind
    /// nur das Symbol (für kleine Kacheln)
    var compact = false

    var body: some View {
        let i = info
        HStack(spacing: 3) {
            Image(systemName: i.0).font(.system(size: 9, weight: .bold))
            if !compact { Text(i.1).font(.caption2.weight(.semibold)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(i.1)
        .foregroundStyle(i.2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(i.2.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    private var info: (String, String, Color) {
        if !store.blindAutoOn(blind) { return ("hand.raised.fill", "Manuell", .secondary) }
        if let until = store.blindPausedUntil(blind) {
            let t = until == .distantFuture ? "Pause" : "Pause bis " + until.formatted(date: .omitted, time: .shortened)
            return ("pause.fill", t, .orange)
        }
        if store.blindShading(blind) { return ("sun.max.fill", "Auto · beschattet", .orange) }
        return ("a.circle.fill", "Auto", .green)
    }
}
