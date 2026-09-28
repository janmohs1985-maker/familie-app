import SwiftUI

// MARK: - Symbol auswählen

enum IconCatalog {
    static let groups: [(String, [String])] = [
        ("Licht", ["lightbulb", "lightbulb.2", "lamp.ceiling", "lamp.ceiling.inverse", "chandelier", "light.recessed",
                   "light.cylindrical.ceiling", "light.panel", "light.strip.2", "lamp.desk", "lamp.floor", "lamp.table",
                   "lightspectrum.horizontal", "sparkles", "star", "moon.stars"]),
        ("Steckdosen & Geräte", ["poweroutlet.type.f", "powerplug", "bolt", "power", "tv", "hifispeaker", "speaker.wave.2",
                                 "desktopcomputer", "printer", "gamecontroller", "washer", "dryer", "dishwasher", "oven",
                                 "refrigerator", "microwave", "cooktop", "fan", "fan.ceiling", "air.conditioner.horizontal",
                                 "heater.vertical", "humidifier", "air.purifier"]),
        ("Rollläden & Fenster", ["blinds.horizontal.closed", "blinds.vertical.closed", "window.shade.closed",
                                 "window.awning.closed", "curtains.closed", "rectangle.split.3x1"]),
        ("Außen & Garten", ["tree", "leaf", "drop", "sprinkler.and.droplets", "spigot", "flame", "figure.pool.swim",
                            "sun.max", "beach.umbrella", "tent", "car", "bicycle", "ev.charger", "door.garage.closed",
                            "door.left.hand.closed", "lock", "key", "camera", "bell"]),
        ("Räume & Sonstiges", ["house", "sofa", "bed.double", "shower", "bathtub", "fork.knife", "cup.and.saucer",
                               "figure.walk", "pawprint", "cube", "shippingbox", "play", "hand.tap"]),
    ]

    static func exists(_ name: String) -> Bool { UIImage(systemName: name) != nil }
}

struct IconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    let fallback: String

    @State private var custom = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        cell(fallback, selected: selection == nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatisch").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("Passend zur Geräteart").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                ForEach(IconCatalog.groups.indices, id: \.self) { gi in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(IconCatalog.groups[gi].0.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(IconCatalog.groups[gi].1.filter { IconCatalog.exists($0) }, id: \.self) { name in
                                Button {
                                    selection = name
                                    dismiss()
                                } label: { cell(name, selected: selection == name) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(name)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("EIGENES SYMBOL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("Name aus SF Symbols, z. B. lamp.ceiling", text: $custom)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if IconCatalog.exists(custom.trimmingCharacters(in: .whitespaces)) {
                            Image(systemName: custom.trimmingCharacters(in: .whitespaces))
                            Button("Nehmen") {
                                selection = custom.trimmingCharacters(in: .whitespaces)
                                dismiss()
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Symbol")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cell(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(selected ? Color.white : Color.accentColor)
            .frame(width: 52, height: 52)
            .background(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Gerät hinzufügen (von der Räume-Übersicht aus)

struct AddDeviceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let startFloor: String

    @State private var model = RoomsModel.shared
    @State private var item: RoomItem?
    @State private var roomID = ""
    @State private var showPicker = false

    private var rooms: [Room] { model.floors.flatMap(\.rooms).filter { $0.page == nil } }
    private var roomName: String { rooms.first { $0.id == roomID }?.name ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gerät") {
                    if let item {
                        HStack(spacing: 12) {
                            Image(systemName: ControlIcons.symbol(item.control, on: true))
                                .foregroundStyle(Color.accentColor).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.states[item.e]?.name ?? item.e)
                                Text(item.e).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ändern") { showPicker = true }.font(.footnote)
                        }
                    } else {
                        Button { showPicker = true } label: {
                            Label("Gerät aus Home Assistant wählen", systemImage: "magnifyingglass")
                        }
                    }
                }
                Section("Wohin?") {
                    Picker("Raum", selection: $roomID) {
                        ForEach(model.floors) { f in
                            Section(f.title ?? f.name) {
                                ForEach(f.rooms.filter { $0.page == nil }) { r in Text(r.name).tag(r.id) }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                if item != nil {
                    Section {
                        TextField("Name in der App", text: Binding(get: { item?.n ?? "" }, set: { item?.n = $0 }))
                        Picker("Art", selection: Binding(get: { item?.kind ?? "" },
                                                         set: { item?.kind = $0.isEmpty ? nil : $0 })) {
                            Text("Automatisch").tag("")
                            Text("Lampe").tag("light")
                            Text("Nur auslösen").tag("button")
                        }
                        NavigationLink {
                            IconPickerView(selection: Binding(get: { item?.icon }, set: { item?.icon = $0 }),
                                           fallback: fallbackIcon)
                        } label: {
                            LabeledContent("Symbol") {
                                Image(systemName: item.map { ControlIcons.symbol($0.control, on: true) } ?? "questionmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Toggle("Vor dem Schalten fragen", isOn: Binding(get: { item?.confirm ?? false },
                                                                        set: { item?.confirm = $0 ? true : nil }))
                    } header: { Text("Anzeige") }
                }
            }
            .navigationTitle("Gerät hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }
                            .disabled(item == nil || roomID.isEmpty || (item?.n.trimmingCharacters(in: .whitespaces).isEmpty ?? true))
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                RoomEntityPicker(roomName: roomName, taken: []) { picked in item = picked }
            }
            .onAppear {
                if roomID.isEmpty {
                    roomID = model.floors.first { $0.id == startFloor }?.rooms.first { $0.page == nil }?.id ?? rooms.first?.id ?? ""
                }
            }
        }
    }

    private var fallbackIcon: String {
        guard let item else { return "questionmark" }
        var plain = item
        plain.icon = nil
        return ControlIcons.symbol(plain.control, on: true)
    }

    private func save() async {
        guard var new = item else { return }
        new.n = new.n.trimmingCharacters(in: .whitespaces)
        var floors = model.floors
        for fi in floors.indices {
            if let ri = floors[fi].rooms.firstIndex(where: { $0.id == roomID }) {
                if floors[fi].rooms[ri].list.contains(where: { $0.e == new.e }) {
                    store.lastError = "„\(new.n)“ ist in diesem Raum schon vorhanden."
                    return
                }
                if floors[fi].rooms[ri].items == nil { floors[fi].rooms[ri].items = [] }
                floors[fi].rooms[ri].items?.append(new)
            }
        }
        if await model.save(floors, store) { dismiss() }
    }
}
