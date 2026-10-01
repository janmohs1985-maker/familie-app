import SwiftUI
import WatchKit

@main
struct FamilieWatchApp: App {
    @StateObject private var link = WatchLink.shared

    init() { WatchLink.shared.start() }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if link.linked {
                    HomeView(parent: link.parent)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward").font(.largeTitle).foregroundStyle(.indigo)
                        Text("Öffne Familie einmal auf dem iPhone").multilineTextAlignment(.center).font(.footnote)
                    }
                    .padding()
                }
            }
        }
    }
}

enum W {
    static let shopping = "todo.einkaufsliste"
    static let gateScript = "script.toggle_garage_door"
    static let gateStatus = "sensor.garagentor_status"
    static let frontDoor = "button.doorbird_ture_relay_ghqsex_1"
    static let teslaSoc = "sensor.tesla_akku"
    static let teslaCharging = "binary_sensor.evcc_openwb_charging"
    static let pv = "sensor.evcc_pv_power"
    static let grid = "sensor.evcc_grid_power"
}

// MARK: Start

struct HomeView: View {
    let parent: Bool
    @State private var soc: Double?
    @State private var charging = false
    @State private var pv: Double?
    @State private var grid: Double?
    @State private var gate: String?
    @State private var openCount: Int?
    @State private var confirm: Pending?
    @State private var message: String?

    enum Pending: String, Identifiable {
        case gate, door
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Gauge(value: (soc ?? 0) / 100) {
                        Image(systemName: charging ? "bolt.fill" : "car.side.fill")
                    } currentValueLabel: {
                        Text(soc.map { "\(Int($0))" } ?? "–")
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tesla").font(.headline)
                        Text(charging ? "lädt" : "steht").font(.caption2).foregroundStyle(.secondary)
                        if let pv {
                            Label(pv >= 1000 ? String(format: "%.1f kW", pv / 1000) : "\(Int(pv)) W", systemImage: "sun.max.fill")
                                .font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                }
            }

            NavigationLink {
                ShoppingView()
            } label: {
                Label {
                    HStack {
                        Text("Einkaufsliste")
                        Spacer()
                        if let openCount, openCount > 0 { Text("\(openCount)").foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: "cart.fill").foregroundStyle(.green) }
            }

            if parent {
                Button { confirm = .gate } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Garagentor")
                            if let gate { Text(gate).font(.caption2).foregroundStyle(.secondary) }
                        }
                    } icon: { Image(systemName: "door.garage.closed").foregroundStyle(.orange) }
                }
                Button { confirm = .door } label: {
                    Label("Haustür öffnen", systemImage: "door.left.hand.open").foregroundStyle(.primary)
                }
                NavigationLink {
                    CallView()
                } label: {
                    Label("Alle rufen", systemImage: "megaphone.fill")
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Familie")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(confirm == .gate ? "Garagentor bewegen?" : "Haustür öffnen?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button(confirm == .gate ? "Tor bewegen" : "Öffnen", role: .destructive) {
                let what = confirm
                confirm = nil
                Task { await run(what) }
            }
            Button("Abbrechen", role: .cancel) { confirm = nil }
        }
    }

    private func load() async {
        async let s = WatchHA.shared.state(W.teslaSoc)
        async let c = WatchHA.shared.state(W.teslaCharging)
        async let p = WatchHA.shared.state(W.pv)
        async let g = WatchHA.shared.state(W.gateStatus)
        async let items = ShoppingView.openItems()
        soc = Double(await s?.state ?? "")
        charging = await c?.state == "on"
        pv = Double(await p?.state ?? "")
        gate = await g?.state
        openCount = await items?.count
    }

    private func run(_ what: Pending?) async {
        do {
            switch what {
            case .gate: try await WatchHA.shared.call("script", "turn_on", ["entity_id": W.gateScript])
            case .door: try await WatchHA.shared.call("button", "press", ["entity_id": W.frontDoor])
            case nil: return
            }
            WKInterfaceDevice.current().play(.success)
            message = what == .gate ? "Tor fährt" : "Tür summt"
            try? await Task.sleep(for: .seconds(8))
            await load()
            message = nil
        } catch {
            WKInterfaceDevice.current().play(.failure)
            message = error.localizedDescription
        }
    }
}

// MARK: Einkaufsliste – antippen = gekauft

struct ShopItem: Identifiable, Hashable {
    let id: String
    let title: String
}

struct ShoppingView: View {
    @State private var items: [ShopItem] = []
    @State private var loading = true
    @State private var error: String?

    static func openItems() async -> [ShopItem]? {
        guard let r = try? await WatchHA.shared.callResponse("todo", "get_items",
                                                             ["entity_id": W.shopping, "status": ["needs_action"]]),
              let list = (r[W.shopping] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        return list.compactMap { i in
            guard let uid = i["uid"] as? String else { return nil }
            return ShopItem(id: uid, title: i["summary"] as? String ?? "")
        }
    }

    var body: some View {
        List {
            if loading && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                Label("Alles erledigt", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            ForEach(items) { item in
                Button {
                    Task { await done(item) }
                } label: {
                    Label(item.title, systemImage: "circle")
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Einkauf")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        if let l = await Self.openItems() { items = l; error = nil } else { error = "Liste nicht geladen" }
        loading = false
    }

    private func done(_ item: ShopItem) async {
        withAnimation { items.removeAll { $0.id == item.id } }
        WKInterfaceDevice.current().play(.click)
        do {
            try await WatchHA.shared.call("todo", "update_item", ["entity_id": W.shopping, "item": item.id, "status": "completed"])
        } catch {
            self.error = error.localizedDescription
            await load()
        }
    }
}

// MARK: Alle rufen

struct CallView: View {
    @State private var sent: String?
    @State private var error: String?
    private let presets = ["Essen ist fertig!", "Abfahrt in 10 Minuten!", "Kommt bitte mal runter!", "Zähne putzen und ab ins Bett!"]

    var body: some View {
        List {
            ForEach(presets, id: \.self) { p in
                Button(p) { Task { await send(p) } }
            }
            if let sent { Label("Gesendet: \(sent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Rufen")
    }

    private func send(_ text: String) async {
        guard let token = WatchKeychain.load()?.pushToken, !token.isEmpty else {
            error = "Öffne Familie einmal auf dem iPhone"
            return
        }
        do {
            let r = try await WatchHA.shared.callResponse("rest_command", "familie_rufen",
                                                          ["daten": ["aktion": "rufen", "text": text, "token": token]])
            let content = r["content"] as? [String: Any] ?? r
            if content["ok"] as? Bool == true {
                sent = text
                error = nil
                WKInterfaceDevice.current().play(.success)
            } else {
                error = content["error"] as? String ?? "Nicht gesendet"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
