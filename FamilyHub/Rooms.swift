import SwiftUI

// MARK: - Räume
//
// Stockwerke, Räume und Geräte kommen aus Home Assistant (Datei /homeassistant/familie_raeume.json,
// ausgeliefert vom Family-Hub-Add-on über das Skript „familie_raeume“). So lässt sich die
// Einteilung ändern, ohne die App neu zu bauen.

struct RoomItem: Codable, Hashable {
    var e: String              // Entität
    var n: String              // Anzeigename im Raum
    var kind: String?          // "light" (Schalter, der eine Lampe ist) | "button" (nur auslösen)
    var status: String?        // Entität, die den Zustand zeigt (z. B. Garagentor)
    var confirm: Bool?

    var domain: String { String(e.split(separator: ".").first ?? "") }
    var isLight: Bool { domain == "light" || kind == "light" }
    var isCover: Bool { domain == "cover" }
    var isPlug: Bool { !isLight && kind == nil && (domain == "switch" || domain == "input_boolean") }

    var control: AppControl {
        if domain == "script", let status {
            return AppControl(uid: "room:" + e, name: n, entity: status, script: e, kids: [],
                              confirm: confirm ?? false, from: nil, to: nil, sort: 0)
        }
        return AppControl(uid: "room:" + e, name: n, entity: e, script: nil, kids: [],
                          confirm: confirm ?? false, from: nil, to: nil, sort: 0)
    }
}

struct Room: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var climate: String?
    var items: [RoomItem]?
    var page: String?          // statt Geräten: bestehende Seite öffnen (pool, strom, …)

    var list: [RoomItem] { items ?? [] }
}

struct Floor: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var title: String?
    var rooms: [Room]
}

struct RoomsFile: Codable { var floors: [Floor] }

/// Gemeinsamer Stand der Räume (alle Ansichten sehen dieselben Daten)
@MainActor @Observable
final class RoomsModel {
    static let shared = RoomsModel()
    static let loadScript = "familie_raeume"
    static let saveCommand = "familie_raeume_set"

    var floors: [Floor] = []
    var saving = false

    func load(_ store: AppStore) async {
        do {
            let r = try await store.client.callWithResponse("script", Self.loadScript, [:], timeout: 30)
            let content = r["content"] ?? r
            let data = try JSONEncoder().encode(content)
            floors = try JSONDecoder().decode(RoomsFile.self, from: data).floors
        } catch { store.report(error) }
    }

    /// Speichert die ganze Einteilung in Home Assistant (Family Hub legt vorher eine Sicherung an)
    @discardableResult
    func save(_ new: [Floor], _ store: AppStore) async -> Bool {
        saving = true
        defer { saving = false }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let text = String(decoding: try enc.encode(RoomsFile(floors: new)), as: UTF8.self)
            let r = try await store.client.callWithResponse("rest_command", Self.saveCommand, ["daten": text], timeout: 30)
            let c = r["content"] ?? r
            guard c["ok"]?.string == "true" else {
                store.lastError = "Räume nicht gespeichert: " + (c["error"]?.string ?? "unbekannter Fehler")
                return false
            }
            floors = new
            return true
        } catch {
            store.report(error)
            return false
        }
    }

    func room(_ id: String) -> Room? { floors.flatMap(\.rooms).first { $0.id == id } }
    func floorOf(room id: String) -> Floor? { floors.first { f in f.rooms.contains { $0.id == id } } }

    /// In welchem Raum steckt die Entität schon?
    func roomName(containing entity: String) -> String? {
        for f in floors { for r in f.rooms where r.list.contains(where: { $0.e == entity }) { return r.name } }
        return nil
    }

    static func newID(_ name: String, existing: Set<String>) -> String {
        let map: [Character: String] = ["ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"]
        var base = ""
        for ch in name.lowercased() {
            if let m = map[ch] { base += m } else if ch.isLetter || ch.isNumber { base.append(ch) } else { base += "_" }
        }
        base = base.split(separator: "_").joined(separator: "_")
        if base.isEmpty { base = "raum" }
        var id = base, n = 2
        while existing.contains(id) { id = "\(base)_\(n)"; n += 1 }
        return id
    }
}

@MainActor
extension AppStore {
    func isItemOn(_ i: RoomItem) -> Bool { isOn(i.control) }

    func roomLightsOn(_ r: Room) -> Int { r.list.filter { $0.isLight && isItemOn($0) }.count }

    func roomTemp(_ r: Room) -> Double? {
        guard let c = r.climate else { return nil }
        return states[c]?.attr("current_temperature")?.double
    }

    /// Mittlere Öffnung der Rollläden (nil = keine)
    func roomCoverAverage(_ items: [RoomItem]) -> Int? {
        let pos = items.filter(\.isCover).compactMap { states[$0.e]?.attr("current_position")?.int }
        guard !pos.isEmpty else { return nil }
        return pos.reduce(0, +) / pos.count
    }

    /// Nur auslösen (z. B. Markise über KNX-Taster)
    func pressItem(_ i: RoomItem) async {
        busy.insert("room:" + i.e)
        defer { busy.remove("room:" + i.e) }
        do {
            switch i.domain {
            case "script": try await client.call("script", "turn_on", ["entity_id": i.e])
            case "button", "input_button": try await client.call(i.domain, "press", ["entity_id": i.e])
            default: try await client.call(i.domain, "turn_on", ["entity_id": i.e])
            }
            try? await Task.sleep(for: .milliseconds(700))
            await refreshStates()
        } catch { report(error) }
    }

    /// Alle Lampen (und Lampen-Schalter) aus
    func lightsOff(_ items: [RoomItem]) async {
        let on = items.filter { $0.isLight && isItemOn($0) }
        guard !on.isEmpty else { return }
        let lights = on.filter { $0.domain == "light" }.map(\.e)
        let others = on.filter { $0.domain != "light" }.map(\.e)
        do {
            if !lights.isEmpty { try await client.call("light", "turn_off", ["entity_id": lights]) }
            if !others.isEmpty { try await client.call("homeassistant", "turn_off", ["entity_id": others]) }
            try? await Task.sleep(for: .milliseconds(800))
            await refreshStates()
        } catch { report(error) }
    }

    func covers(_ items: [RoomItem], _ action: String) async {
        let ids = items.filter(\.isCover).map(\.e)
        guard !ids.isEmpty else { return }
        do {
            try await client.call("cover", action, ["entity_id": ids])
            try? await Task.sleep(for: .milliseconds(800))
            await refreshStates()
        } catch { report(error) }
    }

    func isFavorite(_ i: RoomItem) -> Bool {
        appControls.contains { $0.entity == i.control.entity }
    }
}

enum RoomText {
    static func temp(_ t: Double?) -> String {
        guard let t else { return "" }
        return t.formatted(.number.precision(.fractionLength(1))) + "°"
    }

    static func symbol(_ r: Room) -> String {
        switch r.page {
        case "pool": return "figure.pool.swim"
        case "strom": return "ev.charger.fill"
        case "waesche": return "washer.fill"
        case "bewaesserung": return "sprinkler.and.droplets.fill"
        default: break
        }
        let n = r.name.lowercased()
        if n.contains("bad") || n == "wc" { return "shower.fill" }
        if n.contains("küche") { return "fork.knife" }
        if n.contains("schlaf") { return "bed.double.fill" }
        if n.contains("flur") { return "door.left.hand.open" }
        if n.contains("garage") { return "door.garage.closed" }
        if n.contains("einfahrt") || n.contains("fassade") { return "lightbulb.2.fill" }
        if n.contains("garten") || n.contains("terrasse") { return "tree.fill" }
        if n.contains("wohn") { return "sofa.fill" }
        if n.contains("ess") { return "chair.lounge.fill" }
        return "square.split.bottomrightquarter"
    }
}

// MARK: - Übersicht nach Stockwerken

struct RoomsOverview: View {
    @Environment(AppStore.self) private var store
    @State private var model = RoomsModel.shared
    @State private var editFloor: Floor?
    @AppStorage("roomsFloor") private var floorID = "eg"

    private var floors: [Floor] { model.floors }
    private var canEdit: Bool { store.isParent && store.activeKid == nil }

    private var floor: Floor? { floors.first { $0.id == floorID } ?? floors.first }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if floors.isEmpty {
                ProgressView("Räume werden geladen …").frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(floors) { f in
                            Button { withAnimation(.snappy) { floorID = f.id } } label: {
                                Text(f.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .foregroundStyle(f.id == floor?.id ? Color(.systemBackground) : Color.primary)
                                    .background(f.id == floor?.id ? Color.primary : Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                if let floor {
                    FloorHeader(floor: floor).padding(.horizontal)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(floor.rooms) { r in
                            NavigationLink {
                                if let page = r.page { DeepLinkDestination(target: page) } else { RoomView(roomID: r.id) }
                            } label: { RoomCard(room: r) }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    if canEdit {
                        Button { editFloor = floor } label: {
                            Label("Räume von \(floor.name) bearbeiten", systemImage: "square.and.pencil")
                                .font(.footnote)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .task { await model.load(store) }
        .sheet(item: $editFloor) { f in FloorEditView(floorID: f.id) }
    }
}

struct FloorHeader: View {
    @Environment(AppStore.self) private var store
    let floor: Floor

    private var items: [RoomItem] { floor.rooms.flatMap(\.list) }
    private var lightsOn: Int { items.filter { $0.isLight && store.isItemOn($0) }.count }

    private var info: String {
        var parts: [String] = []
        parts.append(lightsOn == 0 ? "Alle Lichter aus" : "\(lightsOn) \(lightsOn == 1 ? "Licht" : "Lichter") an")
        if let avg = store.roomCoverAverage(items) { parts.append("Rollläden \(avg) %") }
        let temps = floor.rooms.compactMap { store.roomTemp($0) }
        if !temps.isEmpty {
            let mean = temps.reduce(0, +) / Double(temps.count)
            parts.append(mean.formatted(.number.precision(.fractionLength(1))) + " °C")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(floor.title ?? floor.name).font(.headline)
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if lightsOn > 0 {
                Button { Task { await store.lightsOff(items) } } label: {
                    Label("Alle aus", systemImage: "lightbulb.slash").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.orange)
            }
            if items.contains(where: \.isCover) {
                Menu {
                    Button { Task { await store.covers(items, "open_cover") } } label: { Label("Alle hoch", systemImage: "arrow.up") }
                    Button { Task { await store.covers(items, "stop_cover") } } label: { Label("Stopp", systemImage: "stop.fill") }
                    Button { Task { await store.covers(items, "close_cover") } } label: { Label("Alle runter", systemImage: "arrow.down") }
                } label: {
                    Image(systemName: "blinds.horizontal.closed")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Rollläden im Stockwerk")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct RoomCard: View {
    @Environment(AppStore.self) private var store
    let room: Room

    private var lit: Int { store.roomLightsOn(room) }

    private var info: String {
        if let page = room.page {
            switch page {
            case "pool": return "Wasser, Pumpe, Wärmepumpe"
            case "strom": return "Laden & Strom"
            case "waesche": return "Waschmaschine & Trockner"
            case "bewaesserung": return "OpenSprinkler"
            default: return "Öffnen"
            }
        }
        var parts: [String] = []
        let lights = room.list.filter(\.isLight).count
        if lights > 0 { parts.append(lit > 0 ? "\(lit) von \(lights) an" : (lights == 1 ? "Licht aus" : "\(lights) Lichter aus")) }
        if let avg = store.roomCoverAverage(room.list) {
            parts.append(avg == 0 ? "Rollläden zu" : avg == 100 ? "Rollläden offen" : "Rollläden \(avg) %")
        }
        let plugsOn = room.list.filter { $0.isPlug && store.isItemOn($0) }.count
        if plugsOn > 0 { parts.append("\(plugsOn) Steckdose\(plugsOn == 1 ? "" : "n") an") }
        if let g = room.list.first(where: { $0.status != nil }), let s = g.status, let st = store.states[s]?.state {
            parts.append("\(g.n): \(st)")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: lit > 0 ? "lightbulb.fill" : RoomText.symbol(room))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(lit > 0 ? Color.black.opacity(0.75) : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background(lit > 0 ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                Spacer(minLength: 0)
                if room.page != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                } else {
                    Text(RoomText.temp(store.roomTemp(room))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(room.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Text(info).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(lit > 0 ? AnyShapeStyle(Color.yellow.opacity(0.14)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                    in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Ein Raum

struct RoomView: View {
    @Environment(AppStore.self) private var store
    let roomID: String
    @State private var model = RoomsModel.shared
    @State private var editing = false

    private var room: Room { model.room(roomID) ?? Room(id: roomID, name: "Raum", climate: nil, items: [], page: nil) }

    @State private var pending: AppControl?
    @State private var coverSheet: AppControl?
    @State private var lightSheet: AppControl?
    @State private var toast: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var lights: [RoomItem] { room.list.filter(\.isLight) }
    private var plugs: [RoomItem] { room.list.filter(\.isPlug) }
    private var covers: [RoomItem] { room.list.filter(\.isCover) }
    private var others: [RoomItem] { room.list.filter { !$0.isLight && !$0.isPlug && !$0.isCover } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ErrorBanner()
                if let c = room.climate, let s = store.states[c] {
                    climateCard(s)
                }
                section("Licht", lights)
                section("Steckdosen", plugs)
                section("Rollläden", covers)
                section("Weitere", others)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(room.name)
        .toolbar {
            if lights.contains(where: { store.isItemOn($0) }) {
                Button("Alles aus") { Task { await store.lightsOff(lights) } }
            }
            if store.isParent && store.activeKid == nil {
                Button("Bearbeiten") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { RoomEditView(roomID: roomID) }
        .overlay {
            if room.list.isEmpty {
                ContentUnavailableView("Noch keine Geräte", systemImage: "lightbulb.slash",
                                       description: Text("Über „Bearbeiten“ kannst du Geräte hinzufügen."))
            }
        }
        .refreshable { await store.refreshStates() }
        .confirmationDialog(pending.map { "\($0.name) wirklich schalten?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let c = pending {
                Button("Ja, schalten") { Task { await store.toggle(c) } }
                Button("Abbrechen", role: .cancel) { }
            }
        }
        .sheet(item: $coverSheet) { c in CoverSheet(control: c).presentationDetents([.medium]) }
        .sheet(item: $lightSheet) { c in LightSheet(control: c).presentationDetents([.medium, .large]) }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [RoomItem]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 12).padding(.leading, 4)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items, id: \.e) { i in tile(i) }
            }
        }
    }

    private func tile(_ i: RoomItem) -> some View {
        let c = i.control
        return ControlTile(control: c) { tap(i) } more: {
            if c.domain == "cover" { coverSheet = c } else if store.isDimmable(c) { lightSheet = c }
        }
        .contextMenu {
            if store.isDimmable(c) {
                Button { lightSheet = c } label: { Label("Helligkeit & Farbe", systemImage: "slider.horizontal.3") }
            }
            if c.domain == "cover" {
                Button { coverSheet = c } label: { Label("Position", systemImage: "slider.horizontal.3") }
            }
            if store.isParent && store.activeKid == nil {
                if store.isFavorite(i) {
                    Label("Schon in den Favoriten", systemImage: "star.fill")
                } else {
                    Button {
                        Task {
                            await store.addControl(entity: c.entity, name: room.name + " " + i.n)
                            show("Zu Favoriten hinzugefügt")
                        }
                    } label: { Label("Zu Favoriten", systemImage: "star") }
                }
            }
        }
    }

    private func tap(_ i: RoomItem) {
        let c = i.control
        if i.kind == "button" && c.script == nil { Task { await store.pressItem(i) }; return }
        if c.domain == "cover" { coverSheet = c; return }
        if c.confirm { pending = c } else { Task { await store.toggle(c) } }
    }

    private func climateCard(_ s: HAState) -> some View {
        let cur = s.attr("current_temperature")?.double
        let target = s.attr("temperature")?.double
        return NavigationLink { HeatingView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "thermometer.medium")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.orange.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(cur.map { $0.formatted(.number.precision(.fractionLength(1))) + " °C" } ?? "–")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(target.map { "Soll " + $0.formatted(.number.precision(.fractionLength(1))) + " °C · Heizung" } ?? "Heizung")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { toast = nil } }
    }
}
