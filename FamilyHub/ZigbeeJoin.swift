import SwiftUI

// MARK: - Neue Zigbee-Geräte anlernen (Zigbee2MQTT) und gleich benennen

struct NewZigbeeDevice: Identifiable, Hashable {
    let id: String          // Geräte-ID in Home Assistant
    let ieee: String        // 0x… Adresse
    let name: String        // Name in Zigbee2MQTT (= Gerätename in HA)
    let model: String
    let maker: String
    let created: Date?
    /// noch nie umbenannt – Zigbee2MQTT nennt neue Geräte nach ihrer Adresse
    var unnamed: Bool { name.hasPrefix("0x") || name == ieee }
}

enum ZigbeeJoin {
    static let permitSwitch = "switch.zigbee2mqtt_bridge_permit_join"
    static let duration: TimeInterval = 254          // so lange lässt Zigbee2MQTT Geräte zu
}

@MainActor
extension AppStore {
    /// Zigbee-Geräte, die neu sind (letzte 7 Tage) oder noch ihren Adress-Namen tragen
    func loadNewZigbee() async throws -> [NewZigbeeDevice] {
        let list = try await client.websocket(["type": "config/device_registry/list"]).array ?? []
        let weekAgo = Date.now.addingTimeInterval(-7 * 86400)
        return list.compactMap { d -> NewZigbeeDevice? in
            let ids = d["identifiers"]?.array ?? []
            guard let ident = ids.compactMap({ $0.array?.last?.string }).first(where: { $0.hasPrefix("zigbee2mqtt_0x") }),
                  let id = d["id"]?.string else { return nil }
            let ieee = String(ident.dropFirst("zigbee2mqtt_".count))
            let created = d["created_at"]?.double.map { Date(timeIntervalSince1970: $0) }
            let dev = NewZigbeeDevice(id: id, ieee: ieee, name: d["name"]?.string ?? ieee,
                                      model: d["model"]?.string ?? "", maker: d["manufacturer"]?.string ?? "",
                                      created: created)
            return (dev.unnamed || (created ?? .distantPast) > weekAgo) ? dev : nil
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    func setZigbeePermitJoin(_ on: Bool) async throws {
        try await client.call("switch", on ? "turn_on" : "turn_off", ["entity_id": ZigbeeJoin.permitSwitch])
    }

    /// Umbenennen über Zigbee2MQTT – benennt auch Gerät und Entitäten in Home Assistant mit um
    func renameZigbee(from: String, to: String) async throws {
        let payload: [String: Any] = ["from": from, "to": to, "homeassistant_rename": true]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        try await client.call("mqtt", "publish", ["topic": "zigbee2mqtt/bridge/request/device/rename", "payload": json])
    }
}

/// Abschnitt oben in „Zigbee-Geräte“: Anlernen + neue Geräte benennen
struct ZigbeeJoinSection: View {
    @Environment(AppStore.self) private var store
    @State private var joinUntil: Date?
    @State private var busy = false
    @State private var error: String?
    @State private var fresh: [NewZigbeeDevice] = []
    @State private var renaming: NewZigbeeDevice?
    @State private var newName = ""
    @AppStorage("zigbeeErledigt") private var doneRaw = ""

    private var done: Set<String> { Set(doneRaw.split(separator: ",").map(String.init)) }
    private var shown: [NewZigbeeDevice] { fresh.filter { $0.unnamed || !done.contains($0.id) } }
    private var active: Bool {
        if let u = joinUntil, u > .now { return true }
        return store.states[ZigbeeJoin.permitSwitch]?.state == "on"
    }

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let left = max(0, Int((joinUntil ?? tl.date).timeIntervalSince(tl.date)))
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color.purple.opacity(0.18), lineWidth: 5)
                        if active, joinUntil != nil {
                            Circle().trim(from: 0, to: Double(left) / ZigbeeJoin.duration)
                                .stroke(Color.purple, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        Image(systemName: active ? "dot.radiowaves.left.and.right" : "plus")
                            .font(.headline).foregroundStyle(.purple)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: active)
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active ? "Anlernen läuft" : "Neues Gerät anlernen").font(.headline)
                        Text(active
                             ? (joinUntil != nil ? "noch \(left / 60):\(String(format: "%02d", left % 60)) · Gerät jetzt in den Kopplungsmodus bringen"
                                                 : "Gerät jetzt in den Kopplungsmodus bringen")
                             : "Für gut 4 Minuten dürfen neue Zigbee-Geräte beitreten.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            Button(active ? "Anlernen beenden" : "Anlernen starten") { toggle() }
                .disabled(busy)
                .foregroundStyle(active ? Color.red : Color.purple)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Neue Geräte")
        } footer: {
            Text("Neue Geräte heißen zuerst nach ihrer Adresse (0x…). Antippen, um ihnen einen Namen zu geben – der gilt dann auch in Home Assistant.")
        }
        .alert("Gerät benennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("z. B. Küche Bewegungsmelder", text: $newName)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Speichern") { rename() }
        } message: {
            Text(renaming.map { [$0.maker, $0.model].filter { !$0.isEmpty }.joined(separator: " ") } ?? "")
        }
        .task {
            await reload()
            // während des Anlernens alle 3 s nach neuen Geräten schauen, sonst alle 15 s
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(active ? 3 : 15))
                await store.refreshStates()
                await reload()
                if let u = joinUntil, u < .now { joinUntil = nil }
            }
        }

        if !shown.isEmpty {
            Section("Neu hinzugefügt") {
                ForEach(shown) { d in
                    Button {
                        newName = d.unnamed ? "" : d.name
                        renaming = d
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: d.unnamed ? "sparkles" : "checkmark.circle.fill")
                                .foregroundStyle(d.unnamed ? Color.purple : Color.green)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.unnamed ? "Noch ohne Namen" : d.name).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text([d.maker, d.model, d.unnamed ? d.ieee : nil,
                                      d.created.map { "seit " + DayText.short($0) }]
                                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !d.unnamed {
                            Button("Erledigt") { markDone(d) }.tint(.green)
                        }
                    }
                }
            }
        }
    }

    private func reload() async {
        if let l = try? await store.loadNewZigbee() { withAnimation { fresh = l } }
    }

    private func toggle() {
        let on = !active
        busy = true
        error = nil
        Task {
            do {
                try await store.setZigbeePermitJoin(on)
                joinUntil = on ? Date.now.addingTimeInterval(ZigbeeJoin.duration) : nil
                await store.refreshStates()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func rename() {
        guard let d = renaming else { return }
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !n.isEmpty, n != d.name else { return }
        Task {
            do {
                try await store.renameZigbee(from: d.name, to: n)
                try? await Task.sleep(for: .seconds(2))
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func markDone(_ d: NewZigbeeDevice) {
        var s = done
        s.insert(d.id)
        doneRaw = s.joined(separator: ",")
    }
}
