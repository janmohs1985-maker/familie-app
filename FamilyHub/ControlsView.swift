import SwiftUI

// MARK: - Kacheln für „Zuhause“

struct HubTile: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 9))
            Text(title)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .multilineTextAlignment(.leading).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
    }
}

// MARK: - Tab „Zuhause“ (Schalter + Familie + Verwaltung)

struct ControlsView: View {
    @Environment(AppStore.self) private var store
    @State private var pending: AppControl?
    @State private var coverSheet: AppControl?
    @State private var lightSheet: AppControl?
    @State private var showSettings = false
    @State private var showMap = false
    @State private var linkTarget: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let controlColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    @State private var showReorder = false
    @AppStorage("zuhauseMode") private var mode = "uebersicht"

    var body: some View {
        NavigationStack {
            ScrollView {
                ErrorBanner().padding(.horizontal)
                if store.allows(.raeume) {
                    Picker("Ansicht", selection: $mode) {
                        Text("Übersicht").tag("uebersicht")
                        Text("Räume").tag("raeume")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
                if mode == "raeume" && store.allows(.raeume) {
                    RoomsOverview().padding(.top, 8)
                } else {
                    overview
                }
                Spacer(minLength: 24)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await store.refreshStates(); await store.refreshControls() }
            .navigationTitle("Zuhause")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                if store.isParent && store.activeKid == nil {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink("Schalter") { ControlsManageView() }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showMap) { FamilyMapView() }
            .navigationDestination(item: $linkTarget) { t in DeepLinkDestination(target: t) }
            .onChange(of: store.route) { _, r in takeRoute(r) }
            .onAppear { takeRoute(store.route) }
            .task { await store.refreshControls() }
            .confirmationDialog(pending.map { "\($0.name) wirklich schalten?" } ?? "",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible) {
                if let c = pending {
                    Button(actionTitle(c)) { Task { await store.toggle(c) } }
                    Button("Abbrechen", role: .cancel) { }
                }
            }
            .sheet(item: $coverSheet) { c in CoverSheet(control: c).presentationDetents([.medium]) }
            .sheet(item: $lightSheet) { c in LightSheet(control: c).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showReorder) { ControlsReorderView() }
        }
    }

    @ViewBuilder
    private var overview: some View {
                if store.visibleControls.isEmpty {
                    ContentUnavailableView("Keine Schalter", systemImage: "switch.2",
                        description: Text(store.isParent && store.activeKid == nil
                                          ? "Über „Schalter“ oben rechts kannst du Geräte hinzufügen."
                                          : "Mama oder Papa haben noch nichts für dich freigegeben."))
                        .padding(.top, 12)
                }
                if !store.visibleControls.isEmpty {
                    HStack(alignment: .lastTextBaseline) {
                        SectionTitle("Schalten")
                        if store.isParent && store.activeKid == nil && store.appControls.count > 1 {
                            Button { showReorder = true } label: {
                                Label("Anordnen", systemImage: "arrow.up.arrow.down").font(.subheadline)
                            }
                            .padding(.trailing)
                        }
                    }
                }
                LazyVGrid(columns: controlColumns, spacing: 10) {
                    ForEach(store.visibleControls) { c in
                        ControlTile(control: c) { tap(c) } more: {
                            if c.domain == "cover" { coverSheet = c } else if store.isDimmable(c) { lightSheet = c }
                        }
                    }
                }
                .padding(.horizontal)

                if [KidFeature.strom, .heizung, .beschattung, .rauchmelder, .internet, .waesche, .pool, .bewaesserung, .saugroboter].contains(where: { store.allows($0) }) {
                    SectionTitle("Haus")
                    LazyVGrid(columns: columns, spacing: 12) {
                        if store.allows(.strom) {
                            NavigationLink { EnergyView() } label: {
                                HubTile(title: "Haus & Strom", symbol: "bolt.fill", color: .yellow)
                            }
                        }
                        if store.allows(.heizung) {
                            NavigationLink { HeatingView() } label: {
                                HubTile(title: "Heizung", symbol: "heat.waves", color: .red)
                            }
                        }
                        if store.allows(.beschattung) {
                            NavigationLink { ShadingView() } label: {
                                HubTile(title: "Beschattung", symbol: "blinds.horizontal.closed", color: .orange)
                            }
                        }
                        if store.allows(.rauchmelder) {
                            NavigationLink { SmokeView() } label: {
                                HubTile(title: store.smokeAlarm.isEmpty ? (store.smokeProblems.isEmpty ? "Rauchmelder" : "Rauchmelder ⚠︎") : "RAUCH!",
                                        symbol: "smoke.fill", color: store.smokeAlarm.isEmpty ? .gray : .red)
                            }
                        }
                        if store.isParent && store.activeKid == nil {
                            NavigationLink { DevicesView() } label: {
                                HubTile(title: "Zigbee-Geräte", symbol: "dot.radiowaves.left.and.right", color: .purple)
                            }
                        }
                        if store.allows(.internet) {
                            NavigationLink { NetworkView() } label: {
                                HubTile(title: "Internet", symbol: "globe.europe.africa.fill", color: .indigo)
                            }
                        }
                        if store.allows(.waesche) {
                            NavigationLink { LaundryView() } label: {
                                HubTile(title: "Wäsche", symbol: "washer.fill", color: .teal)
                            }
                        }
                        if store.allows(.pool) {
                            NavigationLink { PoolView() } label: {
                                HubTile(title: "Pool", symbol: "figure.pool.swim", color: .blue)
                            }
                        }
                        if store.allows(.bewaesserung) {
                            NavigationLink { IrrigationView() } label: {
                                HubTile(title: "Bewässerung", symbol: "sprinkler.and.droplets.fill", color: .cyan)
                            }
                        }
                        if store.allows(.saugroboter) {
                            NavigationLink { VacuumsView() } label: {
                                HubTile(title: "Saugroboter", symbol: "fan.fill", color: .mint)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .buttonStyle(.plain)
                }

                SectionTitle("Familie")
                LazyVGrid(columns: columns, spacing: 12) {
                    if store.allows(.stundenplan) {
                        NavigationLink { TimetableView(kid: store.activeKid) } label: {
                            HubTile(title: "Stundenplan & Freizeit", symbol: "graduationcap.fill", color: .teal)
                        }
                    }
                    if store.allows(.schulmappe) {
                        NavigationLink { SchoolDocsView(kid: store.activeKid) } label: {
                            HubTile(title: "Schulmappe", symbol: "folder.fill", color: .cyan)
                        }
                    }
                    if store.allows(.essensplan) {
                        NavigationLink { MealPlanView() } label: {
                            HubTile(title: "Essensplan", symbol: "fork.knife", color: .orange)
                        }
                    }
                    if store.allows(.musik) {
                        NavigationLink { MusicView() } label: {
                            HubTile(title: "Musik", symbol: "hifispeaker.2.fill", color: .pink)
                        }
                    }
                    if store.allows(.haustuer) {
                        NavigationLink { DoorbellView() } label: {
                            HubTile(title: "Haustür", symbol: "bell.fill", color: .yellow)
                        }
                    }
                }
                .padding(.horizontal)
                .buttonStyle(.plain)

                if store.isParent && store.activeKid == nil {
                    SectionTitle("Verwaltung")
                    LazyVGrid(columns: columns, spacing: 12) {
                        NavigationLink { DocumentsView() } label: {
                            HubTile(title: "Dokumente scannen", symbol: "scanner.fill", color: .indigo)
                        }
                        Button { showMap = true } label: {
                            HubTile(title: "Wo sind alle?", symbol: "map.fill", color: .green)
                        }
                        Button { showSettings = true } label: {
                            HubTile(title: "Einstellungen", symbol: "gearshape.fill", color: .gray)
                        }
                    }
                    .padding(.horizontal)
                    .buttonStyle(.plain)
                }
    }

    private func takeRoute(_ r: String?) {
        guard let r, DeepLink.zuhausePages[r] != nil else { return }
        store.route = nil
        linkTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { linkTarget = r }
    }

    private func tap(_ c: AppControl) {
        if c.domain == "cover" && c.script == nil { coverSheet = c; return }
        if c.confirm { pending = c } else { Task { await store.toggle(c) } }
    }

    private func actionTitle(_ c: AppControl) -> String {
        let on = store.isOn(c)
        switch c.domain {
        case "lock": return on ? "Verriegeln" : "Entriegeln"
        case "scene", "script", "button", "input_button": return "Ausführen"
        default: return c.script != nil ? (on ? "Schließen" : "Öffnen") : (on ? "Ausschalten" : "Einschalten")
        }
    }
}

// MARK: - Kachel

struct ControlTile: View {
    @Environment(AppStore.self) private var store
    let control: AppControl
    let tap: () -> Void
    let more: () -> Void

    private var state: HAState? { store.states[control.entity] }
    private var on: Bool { store.isOn(control) }
    private var unavailable: Bool { state == nil || state?.state == "unavailable" }
    private var allowed: Bool { store.allowedNow(control) }
    private var busy: Bool { store.busy.contains(control.uid) }
    private var hasMore: Bool { control.domain == "cover" || store.isDimmable(control) }

    /// Farbe der Kachel: Lampen in ihrer Lichtfarbe, sonst Akzentfarbe
    private var tint: Color {
        guard on else { return .accentColor }
        if control.domain == "light" {
            if let rgb = state?.attr("rgb_color")?.array?.compactMap(\.double), rgb.count == 3 {
                return Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
            }
            return Color(red: 1.0, green: 0.78, blue: 0.3)
        }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: ControlIcons.symbol(control, on: on))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(on ? Color.white : tint)
                    .frame(width: 34, height: 34)
                    .background(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.12)), in: Circle())
                    .shadow(color: on ? tint.opacity(0.5) : .clear, radius: 6)
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.small)
                } else if hasMore {
                    Button(action: more) {
                        Image(systemName: "ellipsis").font(.caption.weight(.bold))
                            .frame(width: 24, height: 24)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!allowed || unavailable)
                }
            }
            Spacer(minLength: 0)
            Text(control.name).font(.footnote.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.85)
            Text(stateText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if let level = levelFraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(tint.gradient).frame(width: max(g.size.width * level, 4))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? tint.opacity(0.6) : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { if allowed && !unavailable && !busy { tap() } }
        .onLongPressGesture { if hasMore && allowed && !unavailable { more() } }
        .opacity(unavailable || !allowed ? 0.5 : 1)
        .sensoryFeedback(.impact, trigger: state?.state)
    }

    /// Füllstand für Helligkeit / Rollladen (nil = kein Balken)
    private var levelFraction: Double? {
        if control.domain == "cover", control.script == nil, let p = store.coverPosition(control) { return Double(p) / 100 }
        if store.isDimmable(control) { return on ? Double(store.brightnessPercent(control) ?? 100) / 100 : 0 }
        return nil
    }

    private func coverButton(_ symbol: String, _ action: String) -> some View {
        Button {
            Task { await store.cover(control, action) }
        } label: {
            Image(systemName: symbol).font(.subheadline.bold())
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.borderless)
    }

    private var stateText: String {
        if !allowed, let from = control.from, let to = control.to { return "Nur \(from)–\(to) Uhr" }
        guard let s = state?.state else { return "Nicht gefunden" }
        if control.domain == "cover", let p = store.coverPosition(control) {
            return p == 0 ? "Zu" : p == 100 ? "Offen" : "\(p) % offen"
        }
        if s == "on", let b = store.brightnessPercent(control), store.isDimmable(control) { return "An · \(b) %" }
        switch s {
        case "on": return "An"
        case "off": return "Aus"
        case "locked": return "Verriegelt"
        case "unlocked": return "Entriegelt"
        case "locking": return "Verriegelt …"
        case "unlocking": return "Entriegelt …"
        case "open": return "Offen"
        case "closed": return "Geschlossen"
        case "opening": return "Öffnet …"
        case "closing": return "Schließt …"
        case "unavailable": return "Nicht erreichbar"
        case "unknown": return "Unbekannt"
        case "scening", "scene": return "Szene"
        default:
            if ["scene", "script", "button", "input_button"].contains(control.domain) { return "Antippen zum Ausführen" }
            return s
        }
    }
}

enum ControlIcons {
    static func symbol(_ c: AppControl, on: Bool) -> String {
        if c.script != nil || c.entity.contains("garagentor") { return on ? "door.garage.open" : "door.garage.closed" }
        switch c.domain {
        case "light": return on ? "lightbulb.fill" : "lightbulb"
        case "cover": return on ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "lock": return on ? "lock.open.fill" : "lock.fill"
        case "fan": return on ? "fan.fill" : "fan"
        case "scene": return "sparkles"
        case "script": return "play.fill"
        case "button", "input_button": return "hand.tap.fill"
        case "input_boolean": return on ? "checkmark.circle.fill" : "circle"
        default: return on ? "power.circle.fill" : "power.circle"
        }
    }
    static func symbol(domain: String) -> String {
        symbol(AppControl(uid: "", name: "", entity: domain + ".x", script: nil, kids: [], confirm: false, from: nil, to: nil, sort: 0), on: true)
    }
}

// MARK: - Rollladen und Dimmen

struct CoverSheet: View {
    @Environment(AppStore.self) private var store
    let control: AppControl
    @State private var position: Double = 0
    @State private var editing = false

    var body: some View {
        VStack(spacing: 22) {
            Text(control.name).font(.title3.bold()).padding(.top, 24)
            Text(Int(position) == 0 ? "Geschlossen" : Int(position) == 100 ? "Ganz offen" : "\(Int(position)) % offen")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Slider(value: $position, in: 0...100, step: 5, onEditingChanged: { e in
                editing = e
                if !e { Task { await store.cover(control, "", position: Int(position)) } }
            })
            .padding(.horizontal)
            HStack(spacing: 12) {
                big("Auf", "chevron.up") { await store.cover(control, "open_cover") }
                big("Stopp", "stop.fill") { await store.cover(control, "stop_cover") }
                big("Zu", "chevron.down") { await store.cover(control, "close_cover") }
            }
            .padding(.horizontal)
            Spacer()
        }
        .onAppear { position = Double(store.coverPosition(control) ?? 0) }
        .onChange(of: store.coverPosition(control)) { _, new in if !editing, let new { position = Double(new) } }
    }

    private func big(_ title: String, _ symbol: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2.bold())
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
    }
}

struct LightSheet: View {
    @Environment(AppStore.self) private var store
    let control: AppControl
    @State private var level: Double = 0
    @State private var kelvin: Double = 3000
    @State private var pickColor: Color = .orange

    private var state: HAState? { store.states[control.entity] }
    private var modes: [String] { state?.attr("supported_color_modes")?.array?.compactMap(\.string) ?? [] }
    private var hasColor: Bool { modes.contains { ["hs", "rgb", "rgbw", "rgbww", "xy"].contains($0) } }
    private var hasTemp: Bool { modes.contains("color_temp") }
    private var minK: Double { state?.attr("min_color_temp_kelvin")?.double ?? 2200 }
    private var maxK: Double { state?.attr("max_color_temp_kelvin")?.double ?? 6500 }

    private let swatches: [(String, [Int])] = [
        ("Warm", [255, 180, 107]), ("Rot", [255, 40, 40]), ("Orange", [255, 140, 0]), ("Gelb", [255, 220, 40]),
        ("Grün", [40, 220, 90]), ("Türkis", [40, 210, 210]), ("Blau", [40, 90, 255]), ("Lila", [160, 60, 255]), ("Pink", [255, 60, 170]),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(control.name).font(.title3.bold()).padding(.top, 24)
                // Helligkeit
                VStack(spacing: 10) {
                    Text(Int(level) == 0 ? "Aus" : "\(Int(level)) %")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    HStack {
                        Image(systemName: "sun.min")
                        Slider(value: $level, in: 0...100, step: 5, onEditingChanged: { e in
                            if !e { Task { await store.setBrightness(control, percent: Int(level)) } }
                        })
                        .tint(.yellow)
                        Image(systemName: "sun.max.fill")
                    }
                }
                .padding(.horizontal)

                if hasTemp {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Weißton").font(.subheadline.weight(.semibold))
                        Slider(value: $kelvin, in: minK...maxK, step: 100, onEditingChanged: { e in
                            if !e { Task { await store.setLight(control, ["color_temp_kelvin": Int(kelvin)]) } }
                        })
                        .tint(Color(red: 1, green: 0.85, blue: 0.6))
                        HStack {
                            Text("warm").font(.caption2)
                            Spacer()
                            Text("\(Int(kelvin)) K").font(.caption2.monospacedDigit())
                            Spacer()
                            Text("kalt").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                if hasColor {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Farbe").font(.subheadline.weight(.semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(swatches.indices, id: \.self) { i in
                                let name = swatches[i].0
                                let rgb = swatches[i].1
                                Button {
                                    Task { await store.setLight(control, ["rgb_color": rgb]) }
                                } label: {
                                    Circle()
                                        .fill(Color(red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255).gradient)
                                        .frame(width: 40, height: 40)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(name)
                            }
                            ColorPicker("", selection: $pickColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 40, height: 40)
                        }
                    }
                    .padding(.horizontal)
                    .onChange(of: pickColor) { _, c in
                        let u = UIColor(c)
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        u.getRed(&r, green: &g, blue: &b, alpha: &a)
                        let rgb = [Int(r * 255), Int(g * 255), Int(b * 255)].map { max(0, min(255, $0)) }
                        Task { await store.setLight(control, ["rgb_color": rgb]) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            level = Double(store.isOn(control) ? (store.brightnessPercent(control) ?? 100) : 0)
            if let k = state?.attr("color_temp_kelvin")?.double { kelvin = k } else { kelvin = (minK + maxK) / 2 }
        }
    }
}

/// Reihenfolge der Schalter (gilt für alle, weil in Home Assistant gespeichert)
struct ControlsReorderView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.appControls) { c in
                        HStack(spacing: 12) {
                            Image(systemName: ControlIcons.symbol(c, on: true)).foregroundStyle(Color.accentColor).frame(width: 26)
                            Text(c.name)
                        }
                    }
                    .onMove { from, to in Task { await store.moveControls(from: from, to: to) } }
                } footer: {
                    Text("Mit ≡ ziehen. Die Reihenfolge gilt auf allen Handys.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Schalter anordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
        }
    }
}

// MARK: - Bearbeiten (nur Eltern)

struct ControlsManageView: View {
    @Environment(AppStore.self) private var store
    @State private var showPicker = false

    var body: some View {
        List {
            Section {
                ForEach(store.appControls) { c in
                    NavigationLink {
                        ControlEditView(control: c)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: ControlIcons.symbol(c, on: true)).foregroundStyle(Color.accentColor).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                Text(permissionText(c)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    let list = store.appControls
                    Task { for i in idx { await store.deleteControl(list[i]) } }
                }
                .onMove { from, to in Task { await store.moveControls(from: from, to: to) } }
            } footer: {
                Text("Eltern dürfen alles schalten. Für Kinder gilt nur, was hier freigegeben ist. Hinweis: Das gilt in dieser App – direkt in Home Assistant gibt es keine Rechte pro Gerät.")
            }
        }
        .navigationTitle("Schalter")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { showPicker = true } label: { Image(systemName: "plus") } }
            ToolbarItem(placement: .secondaryAction) { EditButton() }
        }
        .sheet(isPresented: $showPicker) { EntityPickerView() }
    }

    private func permissionText(_ c: AppControl) -> String {
        let names = c.kids.compactMap { FamilyConfig.kid($0)?.name }
        var t = names.isEmpty ? "Nur Eltern" : "Eltern, " + names.joined(separator: ", ")
        if let f = c.from, let to = c.to, !names.isEmpty { t += " · \(f)–\(to)" }
        if c.confirm { t += " · mit Nachfrage" }
        return t
    }
}

struct ControlEditView: View {
    @Environment(AppStore.self) private var store
    @State var control: AppControl
    @State private var useWindow = false
    @State private var fromDate = Date()
    @State private var toDate = Date()

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $control.name)
                LabeledContent("Gerät", value: control.entity).font(.caption)
            }
            Section {
                ForEach(FamilyConfig.kids) { k in
                    Toggle(isOn: Binding(get: { control.kids.contains(k.id) },
                                         set: { on in
                                             if on { if !control.kids.contains(k.id) { control.kids.append(k.id) } }
                                             else { control.kids.removeAll { $0 == k.id } }
                                         })) {
                        Label { Text(k.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(k.color) }
                    }
                }
            } header: { Text("Wer darf schalten?") } footer: { Text("Eltern dürfen immer.") }
            Section {
                Toggle("Zeitfenster für Kinder", isOn: $useWindow.animation())
                if useWindow {
                    DatePicker("Von", selection: $fromDate, displayedComponents: .hourAndMinute)
                    DatePicker("Bis", selection: $toDate, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Außerhalb des Zeitfensters ist der Schalter für die Kinder ausgegraut.")
            }
            Section {
                Toggle("Vor dem Schalten nachfragen", isOn: $control.confirm)
            }
        }
        .navigationTitle(control.name)
        .onAppear {
            useWindow = control.hasTimeWindow
            fromDate = Self.date(control.from ?? "07:00")
            toDate = Self.date(control.to ?? "20:00")
        }
        .onDisappear {
            var c = control
            c.from = useWindow ? Self.text(fromDate) : nil
            c.to = useWindow ? Self.text(toDate) : nil
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = control.entity }
            Task { await store.updateControl(c) }
        }
    }

    static func date(_ hhmm: String) -> Date {
        let m = Timetables.minutes(hhmm)
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    static func text(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

struct EntityPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var candidates: [HAState] {
        let taken = Set(store.appControls.map(\.entity))
        return store.states.values
            .filter { s in
                let domain = String(s.entity_id.split(separator: ".").first ?? "")
                return FamilyConfig.controllableDomains.contains(domain) && !taken.contains(s.entity_id) && s.state != "unavailable"
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.entity_id.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { s in
                Button {
                    Task { await store.addControl(entity: s.entity_id, name: s.name); dismiss() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ControlIcons.symbol(domain: String(s.entity_id.split(separator: ".").first ?? "")))
                            .foregroundStyle(Color.accentColor).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).foregroundStyle(.primary)
                            Text(s.entity_id).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Gerät suchen")
            .navigationTitle("Gerät hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var serverStatus: String?
    @AppStorage("startAnimation") private var startAnimation = true
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("Verbindung") {
                    LabeledContent("Server", value: store.credentials?.server ?? "–")
                    LabeledContent("Anmeldung", value: store.credentials?.longLivedToken != nil ? "Token" : "Benutzer")
                    LabeledContent("Status", value: serverStatus ?? "prüfe …")
                    if let t = store.lastUpdate {
                        LabeledContent("Letztes Update", value: t.formatted(date: .omitted, time: .standard))
                    }
                }
                Section {
                    LabeledContent("Rolle", value: store.isParent ? "Eltern" : (FamilyConfig.kid(store.detectedKid ?? "")?.name ?? "–"))
                    if store.isParent {
                        Picker("Aufgaben ansehen als", selection: Bindable(store).viewAs) {
                            Text("Eltern").tag("auto")
                            ForEach(FamilyConfig.kids) { k in Text(k.name).tag(k.id) }
                        }
                    }
                } header: { Text("Benutzer") } footer: {
                    if store.isParent { Text("Zum Ausprobieren: So sieht die App für die Kinder aus.") }
                }
                if store.canManageNetwork {
                    Section("Kinder") {
                        NavigationLink { KidPermissionsView() } label: {
                            Label("Was die Kinder sehen dürfen", systemImage: "person.2.badge.gearshape.fill")
                        }
                    }
                    Section("Netzwerk") {
                        NavigationLink { GuestWifiView() } label: {
                            Label("Gäste-WLAN", systemImage: "wifi")
                        }
                    }
                }
                AppVersionSection()
                Section {
                    Picker("Erscheinungsbild", selection: $appearance) {
                        Text("Wie iPhone").tag("system")
                        Text("Hell").tag("light")
                        Text("Dunkel").tag("dark")
                    }
                    Toggle("Startanimation", isOn: $startAnimation)
                } header: { Text("Darstellung") } footer: {
                    Text("„Wie iPhone“ wechselt automatisch mit dem Dunkelmodus des Handys.")
                }
                Section("Gefunden") {
                    LabeledContent("Kalender", value: "\(store.calendars.count)")
                    LabeledContent("Listen", value: "\(store.todoLists.count)")
                }
                Section {
                    Button("Abmelden", role: .destructive) {
                        Task { await store.logout(); dismiss() }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .task {
                do { serverStatus = try await store.client.ping() == "API running." ? "Verbunden" : "OK" }
                catch { serverStatus = error.localizedDescription }
            }
        }
    }
}
