import SwiftUI

// MARK: - Räume bearbeiten (nur Eltern)
//
// Alle Änderungen werden erst mit „Sichern“ an Home Assistant geschickt.
// Family Hub legt vor jedem Speichern eine Sicherung an (familie_raeume_sicherung/).

/// Ein Raum: Name, Stockwerk, Geräte hinzufügen / entfernen / sortieren / verschieben
struct RoomEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let roomID: String

    @State private var model = RoomsModel.shared
    @State private var draft = Room(id: "", name: "", climate: nil, items: [], page: nil)
    @State private var floorID = ""
    @State private var moves: [String: String] = [:]      // Entität → Ziel-Raum
    @State private var loaded = false
    @State private var showPicker = false
    @State private var sorting = false
    @State private var confirmDelete = false
    @State private var showContactPicker = false

    private var allRooms: [Room] { model.floors.flatMap(\.rooms).filter { $0.page == nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Raum") {
                    TextField("Name", text: $draft.name)
                    Picker("Stockwerk", selection: $floorID) {
                        ForEach(model.floors) { f in Text(f.title ?? f.name).tag(f.id) }
                    }
                }
                Section {
                    ForEach($draft.items.orEmpty, id: \.e) { $item in
                        NavigationLink {
                            RoomItemEditView(item: $item, moveTo: moveBinding(item.e), rooms: allRooms, currentRoom: roomID)
                        } label: {
                            itemRow(item)
                        }
                    }
                    .onDelete { draft.items?.remove(atOffsets: $0) }
                    .onMove { draft.items?.move(fromOffsets: $0, toOffset: $1) }
                    Button { showPicker = true } label: {
                        Label("Gerät hinzufügen", systemImage: "plus.circle.fill")
                    }
                } header: {
                    HStack {
                        Text("Geräte")
                        Spacer()
                        if draft.list.count > 1 {
                            Button(sorting ? "Fertig" : "Sortieren") { withAnimation { sorting.toggle() } }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                } footer: {
                    Text("Wischen zum Entfernen. Antippen zum Umbenennen oder Verschieben in einen anderen Raum.")
                }
                Section {
                    ForEach(draft.contactList, id: \.self) { e in
                        HStack {
                            Image(systemName: "window.casement").foregroundStyle(Color.accentColor).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.contactName(e))
                                Text(e).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        var list = draft.contactList
                        list.remove(atOffsets: idx)
                        draft.contacts = list.isEmpty ? nil : list
                    }
                    Button { showContactPicker = true } label: {
                        Label("Fenster- oder Türkontakt hinzufügen", systemImage: "plus.circle.fill")
                    }
                } header: { Text("Fenster & Türen") }
                Section {
                    Button("Raum löschen", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Vor jedem Speichern wird in Home Assistant eine Sicherung angelegt.")
                }
            }
            .environment(\.editMode, .constant(sorting ? .active : .inactive))
            .navigationTitle(draft.name.isEmpty ? "Raum" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }
                            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                RoomEntityPicker(roomName: draft.name, taken: Set(draft.list.map(\.e))) { item in
                    if draft.items == nil { draft.items = [] }
                    draft.items?.append(item)
                }
            }
            .sheet(isPresented: $showContactPicker) {
                ContactPicker(taken: Set(draft.contactList)) { e in
                    var list = draft.contactList
                    list.append(e)
                    draft.contacts = list
                }
            }
            .confirmationDialog("„\(draft.name)“ mit allen Geräten aus der App entfernen?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Raum löschen", role: .destructive) { Task { await deleteRoom() } }
            }
            .onAppear {
                guard !loaded, let r = model.room(roomID) else { return }
                draft = r
                floorID = model.floorOf(room: roomID)?.id ?? ""
                loaded = true
            }
        }
    }

    private func itemRow(_ i: RoomItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ControlIcons.symbol(i.control, on: true))
                .foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.n)
                Text(i.e).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let target = moves[i.e], let r = allRooms.first(where: { $0.id == target }) {
                Text("→ \(r.name)").font(.caption).foregroundStyle(.orange)
            } else if store.states[i.e] == nil {
                Text("fehlt").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func moveBinding(_ entity: String) -> Binding<String> {
        Binding(get: { moves[entity] ?? roomID },
                set: { moves[entity] = $0 == roomID ? nil : $0 })
    }

    private func save() async {
        var floors = model.floors
        var room = draft
        room.name = room.name.trimmingCharacters(in: .whitespaces)

        // Geräte, die in einen anderen Raum wandern
        let moving = room.list.filter { moves[$0.e] != nil }
        room.items = room.list.filter { moves[$0.e] == nil }

        // Raum an seiner Stelle ersetzen bzw. ins neue Stockwerk verschieben
        var oldIndex: (Int, Int)?
        for fi in floors.indices {
            if let ri = floors[fi].rooms.firstIndex(where: { $0.id == roomID }) { oldIndex = (fi, ri) }
        }
        if let idx = oldIndex {
            let fi = idx.0, ri = idx.1
            if floors[fi].id == floorID {
                floors[fi].rooms[ri] = room
            } else {
                floors[fi].rooms.remove(at: ri)
                if let ti = floors.firstIndex(where: { $0.id == floorID }) { floors[ti].rooms.append(room) }
            }
        }
        for item in moving {
            guard let target = moves[item.e] else { continue }
            for fi in floors.indices {
                if let ri = floors[fi].rooms.firstIndex(where: { $0.id == target }),
                   !floors[fi].rooms[ri].list.contains(where: { $0.e == item.e }) {
                    if floors[fi].rooms[ri].items == nil { floors[fi].rooms[ri].items = [] }
                    floors[fi].rooms[ri].items?.append(item)
                }
            }
        }
        if await model.save(floors, store) { dismiss() }
    }

    private func deleteRoom() async {
        var floors = model.floors
        for fi in floors.indices { floors[fi].rooms.removeAll { $0.id == roomID } }
        if await model.save(floors, store) { dismiss() }
    }
}

/// Ein Gerät: Name, Art, Nachfrage, Raum
struct RoomItemEditView: View {
    @Environment(AppStore.self) private var store
    @Binding var item: RoomItem
    @Binding var moveTo: String
    let rooms: [Room]
    let currentRoom: String

    private var kind: Binding<String> {
        Binding(get: { item.kind ?? "" }, set: { item.kind = $0.isEmpty ? nil : $0 })
    }
    private var confirm: Binding<Bool> {
        Binding(get: { item.confirm ?? false }, set: { item.confirm = $0 ? true : nil })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name in der App", text: $item.n)
                LabeledContent("Gerät", value: store.states[item.e]?.name ?? item.e)
                LabeledContent("Zustand", value: store.states[item.e]?.state ?? "nicht gefunden")
            } footer: {
                Text(item.e)
            }
            Section {
                Picker("Art", selection: kind) {
                    Text("Automatisch").tag("")
                    Text("Lampe").tag("light")
                    Text("Nur auslösen").tag("button")
                    Text("Esstischlampe (Spezialansicht)").tag("esstisch")
                }
                Toggle("Vor dem Schalten fragen", isOn: confirm)
                NavigationLink {
                    IconPickerView(selection: $item.icon, fallback: ControlIcons.symbol(
                        RoomItem(e: item.e, n: item.n, kind: item.kind, status: item.status, confirm: nil, icon: nil).control, on: true))
                } label: {
                    LabeledContent("Symbol") {
                        Image(systemName: ControlIcons.symbol(item.control, on: true)).foregroundStyle(Color.accentColor)
                    }
                }
            } footer: {
                Text("„Lampe“ für Schalter, an denen ein Licht hängt – dann zählt es bei „Alle aus“ mit. „Nur auslösen“ für Taster wie die Markise.")
            }
            Section("Raum") {
                Picker("Verschieben nach", selection: $moveTo) {
                    ForEach(rooms) { r in Text(r.name).tag(r.id) }
                }
                if moveTo != currentRoom {
                    Text("Wird beim Sichern verschoben.").font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(item.n.isEmpty ? "Gerät" : item.n)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Gerät aus Home Assistant auswählen
struct RoomEntityPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let roomName: String
    let taken: Set<String>
    let onPick: (RoomItem) -> Void

    @State private var search = ""
    @State private var model = RoomsModel.shared

    static let domains: Set<String> = ["light", "switch", "cover", "fan", "lock", "script", "scene", "button",
                                       "input_boolean", "input_button", "valve"]

    private var candidates: [HAState] {
        store.states.values
            .filter { s in
                let d = String(s.entity_id.split(separator: ".").first ?? "")
                return Self.domains.contains(d) && !taken.contains(s.entity_id)
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.entity_id.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// „Wohnzimmer Deckenlicht“ im Raum „Wohnzimmer“ → „Deckenlicht“
    private func shortName(_ full: String) -> String {
        var n = full
        if n.lowercased().hasPrefix(roomName.lowercased()) {
            n = String(n.dropFirst(roomName.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -–:"))
        }
        return n.isEmpty ? full : n
    }

    var body: some View {
        NavigationStack {
            List(candidates) { s in
                Button {
                    onPick(RoomItem(e: s.entity_id, n: shortName(s.name), kind: nil, status: nil, confirm: nil, icon: nil))
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ControlIcons.symbol(domain: String(s.entity_id.split(separator: ".").first ?? "")))
                            .foregroundStyle(Color.accentColor).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).foregroundStyle(.primary)
                            HStack(spacing: 4) {
                                Text(s.entity_id)
                                if let r = model.roomName(containing: s.entity_id) {
                                    Text("· schon in \(r)").foregroundStyle(.orange)
                                }
                                if s.state == "unavailable" {
                                    Text("· nicht erreichbar").foregroundStyle(.red)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

/// Räume eines Stockwerks: hinzufügen, umbenennen, sortieren, löschen
struct FloorEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let floorID: String

    @State private var model = RoomsModel.shared
    @State private var rooms: [Room] = []
    @State private var newName = ""
    @State private var loaded = false

    private var floor: Floor? { model.floors.first { $0.id == floorID } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($rooms) { $r in
                        HStack {
                            TextField("Name", text: $r.name)
                            Spacer()
                            Text(r.page != nil ? "Seite" : "\(r.list.count) Geräte")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { rooms.remove(atOffsets: $0) }
                    .onMove { rooms.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Räume")
                } footer: {
                    Text("Ziehen zum Sortieren, wischen zum Löschen. Geräte bearbeitest du im jeweiligen Raum.")
                }
                Section("Neuer Raum") {
                    HStack {
                        TextField("z. B. Waschküche", text: $newName)
                        Button("Hinzufügen") { addRoom() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(floor?.title ?? floor?.name ?? "Stockwerk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }
                    }
                }
            }
            .onAppear {
                guard !loaded, let f = floor else { return }
                rooms = f.rooms
                loaded = true
            }
        }
    }

    private func addRoom() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let existing = Set(model.floors.flatMap(\.rooms).map(\.id) + rooms.map(\.id))
        rooms.append(Room(id: RoomsModel.newID(name, existing: existing), name: name, climate: nil, items: [], page: nil))
        newName = ""
    }

    private func save() async {
        var floors = model.floors
        guard let fi = floors.firstIndex(where: { $0.id == floorID }) else { return }
        floors[fi].rooms = rooms.map { r in
            var r = r
            r.name = r.name.trimmingCharacters(in: .whitespaces)
            return r
        }.filter { !$0.name.isEmpty }
        if await model.save(floors, store) { dismiss() }
    }
}

// MARK: - Hilfen

extension Optional where Wrapped == [RoomItem] {
    /// Erlaubt Bindings auf eine optionale Geräteliste (nil = leer)
    var orEmpty: [RoomItem] {
        get { self ?? [] }
        set { self = newValue }
    }
}


/// Fenster- und Türkontakte aus Home Assistant
struct ContactPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taken: Set<String>
    let onPick: (String) -> Void
    @State private var search = ""

    private var candidates: [HAState] {
        store.states.values
            .filter { s in
                s.entity_id.hasPrefix("binary_sensor.") && !taken.contains(s.entity_id)
                    && ["window", "door", "opening", "garage_door"].contains(s.attr("device_class")?.string ?? "")
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { s in
                Button {
                    onPick(s.entity_id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).foregroundStyle(.primary)
                        Text(s.entity_id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Kontakt suchen")
            .navigationTitle("Fenster & Türen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}
