import SwiftUI

// MARK: - Internet & Netzwerk: beide Anschlüsse (UniFi), Speedtest, VPN, Starlink

enum NetConfig {
    static let script = "familie_netz"
    // Starlink (Home-Assistant-Integration)
    static let slOnline = "binary_sensor.starlink_konnektivitat"
    static let slPing = "sensor.starlink_ping"
    static let slDrop = "sensor.starlink_ping_drop_rate"
    static let slDown = "sensor.starlink_downlink_durchsatz"
    static let slUp = "sensor.starlink_uplink_durchsatz"
    static let slPower = "sensor.starlink_leistung"
    static let slDownTotal = "sensor.starlink_download"
    static let slUpTotal = "sensor.starlink_upload"
    static let slLastBoot = "sensor.starlink_letzter_neustart"
    static let slReboot = "button.starlink_neu_starten"
    static let slStow = "switch.starlink_verstaut"
    static let slSleepSchedule = "switch.starlink_zeitplan_fur_ruhezustand"
    /// Warnungen der Schüssel: Entität → Text
    static let slWarnings: [(String, String, String)] = [
        ("binary_sensor.starlink_beeintrachtigt", "Sicht behindert (Hindernisse)", "exclamationmark.triangle.fill"),
        ("binary_sensor.starlink_thermische_drossel", "Zu heiß – gedrosselt", "thermometer.sun.fill"),
        ("binary_sensor.starlink_motoren_stecken_fest", "Motoren stecken fest", "gearshape.2.fill"),
        ("binary_sensor.starlink_mast_fast_senkrecht", "Mast nicht gerade", "arrow.up.and.down"),
        ("binary_sensor.starlink_unerwarteter_standort", "Unerwarteter Standort", "location.slash.fill"),
        ("binary_sensor.starlink_ethernet_geschwindigkeiten", "Ethernet-Geschwindigkeit eingeschränkt", "cable.connector"),
        ("binary_sensor.starlink_update", "Update steht an", "arrow.down.circle.fill"),
        ("binary_sensor.starlink_heizung", "Heizt (Schnee schmelzen)", "snowflake"),
        ("binary_sensor.starlink_ruhezustand", "Im Ruhezustand", "moon.zzz.fill"),
    ]
    /// Umleitungen im UniFi (Traffic-Routen) → verständlicher Name
    static let routes: [(String, String)] = [
        ("switch.unifi_network_family_wlan_starlink", "Familien-WLAN über Starlink"),
        ("switch.unifi_network_starlink_guest_wlan", "Gäste-WLAN über Starlink"),
        ("switch.unifi_network_gaste_wlan_starlink", "Gäste-WLAN über Starlink (alt)"),
        ("switch.unifi_network_jans_pc_telekom_direkt", "Jans PC direkt über Telekom"),
    ]
    static let udmRestart = "button.udm_pro_restart"
}

struct NetStatus {
    struct Wan: Identifiable {
        let name: String
        let group: String
        let up: Bool
        let ip: String?
        let latency: Double?
        let availability: Double?
        let uptime: Double?
        let rx: Double?
        let tx: Double?
        let priority: Int?
        let mode: String?
        var id: String { group }
    }
    var wans: [Wan] = []
    var activeWan: String?
    var online = false
    var latency: Double?
    var drops: Int?
    var speedDown: Double?
    var speedUp: Double?
    var speedPing: Double?
    var speedLast: Date?
    var clients: Int?
    var gwCPU: Double?
    var gwMem: Double?
    var gwUptime: Double?
    var gwVersion: String?
    var vpnSites: [(name: String, enabled: Bool, client: Bool, connected: Bool?, since: Date?)] = []
    var siteActive = 0
    var siteInactive = 0
    var remoteUserEnabled = false
    var vpnConnections: [String] = []
    var error: String?
}

@MainActor
extension AppStore {
    func loadNetStatus() async -> NetStatus? {
        guard let r = try? await client.callWithResponse("script", NetConfig.script, ["aktion": "status"], timeout: 40) else { return nil }
        let c = r["content"] ?? r
        var s = NetStatus()
        s.error = c["error"]?.string
        for w in c["wans"]?.array ?? [] {
            s.wans.append(.init(name: w["name"]?.string ?? "WAN", group: w["group"]?.string ?? "WAN",
                                up: w["up"]?.string == "true", ip: w["ip"]?.string,
                                latency: w["latency"]?.double, availability: w["availability"]?.double,
                                uptime: w["uptime"]?.double, rx: w["rx_rate"]?.double, tx: w["tx_rate"]?.double,
                                priority: w["failover_priority"]?.int, mode: w["load_balance"]?.string))
        }
        s.activeWan = c["active_wan"]?.string
        s.online = c["internet"]?["status"]?.string == "ok"
        s.latency = c["internet"]?["latency"]?.double
        s.drops = c["internet"]?["drops"]?.int
        s.speedDown = c["speedtest"]?["down"]?.double
        s.speedUp = c["speedtest"]?["up"]?.double
        s.speedPing = c["speedtest"]?["ping"]?.double
        s.speedLast = c["speedtest"]?["lastrun"]?.double.map { Date(timeIntervalSince1970: $0) }
        s.clients = c["clients"]?.int
        s.gwCPU = c["gateway"]?["cpu"]?.double
        s.gwMem = c["gateway"]?["mem"]?.double
        s.gwUptime = c["gateway"]?["uptime"]?.double
        s.gwVersion = c["gateway"]?["version"]?.string
        var tunnelIDs = Set<String>()
        for v in c["vpn"]?.array ?? [] {
            let purpose = v["purpose"]?.string ?? ""
            if let id = v["id"]?.string { tunnelIDs.insert(id) }
            // „verbunden“ prüft Family Hub selbst (Client: Verbindungsliste, Standort: Gegenstelle antwortet)
            let connected: Bool? = v["verbunden"].map { $0.string == "true" }
            s.vpnSites.append((name: v["name"]?.string ?? "VPN", enabled: v["enabled"]?.string != "false",
                               client: purpose == "vpn-client", connected: connected,
                               since: v["seit"]?.double.map { Date(timeIntervalSince1970: $0) }))
        }
        let vh = c["vpn_health"]
        s.siteActive = vh?["site_to_site_num_active"]?.int ?? 0
        s.siteInactive = vh?["site_to_site_num_inactive"]?.int ?? 0
        s.remoteUserEnabled = vh?["remote_user_enabled"]?.string == "true"
        for conn in c["vpn_connections"]?.array ?? [] {
            // eigene Tunnel (z. B. Mullvad) stehen schon oben – hier nur Leute, die sich von unterwegs einwählen
            if let nid = conn["network_id"]?.string, tunnelIDs.contains(nid) { continue }
            let name = conn["name"]?.string ?? conn["user_name"]?.string ?? conn["client_name"]?.string ?? conn["type"]?.string ?? "Verbindung"
            s.vpnConnections.append(name)
        }
        return s
    }

    struct NetRoute: Identifiable, Hashable {
        let id: String
        let name: String
        let guest: Bool
        let subnet: String?
        var starlink: Bool
        let killSwitch: Bool
    }

    func loadNetRoutes() async -> [NetRoute]? {
        guard let r = try? await client.callWithResponse("script", NetConfig.script, ["aktion": "routes"], timeout: 40) else { return nil }
        let c = r["content"] ?? r
        guard c["ok"]?.string == "true" else { return nil }
        return (c["networks"]?.array ?? []).compactMap { n in
            guard let id = n["id"]?.string else { return nil }
            return NetRoute(id: id, name: n["name"]?.string ?? "Netz", guest: n["guest"]?.string == "true",
                            subnet: n["subnet"]?.string, starlink: n["starlink"]?.string == "true",
                            killSwitch: n["kill_switch"]?.string == "true")
        }
    }

    func setNetRoute(_ id: String, starlink: Bool, killSwitch: Bool? = nil) async -> String? {
        var data: [String: Any] = ["aktion": "route_set", "network_id": id, "starlink": starlink]
        if let killSwitch { data["kill_switch"] = killSwitch }
        do {
            let r = try await client.callWithResponse("script", NetConfig.script, data, timeout: 40)
            let c = r["content"] ?? r
            return c["ok"]?.string == "true" ? nil : (c["error"]?.string ?? "Umschalten fehlgeschlagen")
        } catch { return error.localizedDescription }
    }

    func startSpeedtest() async {
        _ = try? await client.callWithResponse("script", NetConfig.script, ["aktion": "speedtest"], timeout: 40)
    }

    func pressButton(_ entity: String) async {
        do { _ = try await client.call("button", "press", ["entity_id": entity]) } catch { report(error) }
    }
}

/// Zwei Knöpfe 1&1 | Starlink – die gewählte Seite ist grün
struct WanChooser: View {
    let starlink: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            option("1&1", icon: "network", selected: !starlink) { if starlink { onChange(false) } }
            option("Starlink", icon: "antenna.radiowaves.left.and.right", selected: starlink) { if !starlink { onChange(true) } }
        }
        .padding(3)
        .background(Color(.systemGray5), in: Capsule())
    }

    private func option(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .background {
                if selected { Capsule().fill(Color.green.gradient) }
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
    }
}

struct RouteLine: View {
    let name: String
    let via: String
    let starlink: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.subheadline)
            Spacer()
            Image(systemName: starlink ? "antenna.radiowaves.left.and.right" : "network")
                .font(.caption)
            Text(via).font(.caption.weight(.semibold))
        }
        .foregroundStyle(starlink ? Color.orange : Color.blue)
    }
}

enum NetFmt {
    /// Bytes/s → Mbit/s
    static func rate(_ bps: Double?) -> String {
        guard let b = bps else { return "–" }
        let mbit = b * 8 / 1_000_000
        return mbit >= 10 ? String(format: "%.0f Mbit/s", mbit) : String(format: "%.1f Mbit/s", mbit)
    }
    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "–" }
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d) T \(h) Std" }
        if h > 0 { return "\(h) Std \(m) Min" }
        return "\(m) Min"
    }
}

// MARK: - Ansicht

struct NetworkView: View {
    @Environment(AppStore.self) private var store
    @State private var net: NetStatus?
    @State private var loading = true
    @State private var speedRunning = false
    @State private var confirm: ConfirmAction?
    @State private var routes: [AppStore.NetRoute]?
    @State private var vpnRoutes: [AppStore.VPNRoute] = []
    @State private var vpnBusy: String?
    @State private var routeBusy: String?
    @State private var modeError: String?
    @State private var trafficOpen = false

    struct ConfirmAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let run: () async -> Void
    }

    private var isParent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner()
                if loading && net == nil {
                    ProgressView("Frage UniFi …").frame(maxWidth: .infinity, minHeight: 160)
                }
                if let net {
                    headerCard(net)
                    if isParent {
                        NavigationLink { WorldTrafficView() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "globe.americas.fill")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Color.teal.gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Live-Weltkarte").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("Wohin gerade Verbindungen gehen · Auslastung").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .padding(14).cardSurface()
                        }
                        .buttonStyle(.plain)
                    }
                    trafficCard
                    guestCard
                    ForEach(net.wans) { w in wanCard(w, net: net) }
                    speedCard(net)
                    vpnCard(net)
                }
                starlinkCard
                if let net { udmCard(net) }
                if net == nil && !loading {
                    Label("UniFi-Daten gerade nicht verfügbar", systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Internet")
        .refreshable { await load() }
        .task { await load() }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Abbrechen", role: .cancel) { confirm = nil }
            Button("Ja", role: .destructive) {
                let c = confirm
                confirm = nil
                Task { await c?.run() }
            }
        } message: { Text(confirm?.message ?? "") }
    }

    private func load() async {
        loading = true
        async let n = store.loadNetStatus()
        async let m = store.loadNetRoutes()
        async let s: Void = store.refreshStates()
        async let v = store.loadVPNRoutes()
        net = await n
        routes = await m
        vpnRoutes = await v
        _ = await s
        loading = false
    }

    // MARK: Kopf

    private func headerCard(_ n: NetStatus) -> some View {
        let active = n.wans.first { $0.group == n.activeWan } ?? n.wans.first { $0.up }
        let onBackup = active?.group != nil && active?.group != "WAN"
        return HStack(spacing: 14) {
            Image(systemName: n.online ? "globe.europe.africa.fill" : "wifi.slash")
                .font(.system(size: 30)).foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background((n.online ? (onBackup ? Color.orange : Color.green) : Color.red).gradient, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(n.online ? "Internet läuft" : "Internet gestört").font(.title3.weight(.bold))
                if let a = active {
                    Text("über \(a.name)" + (onBackup ? " (Reserve!)" : "")).font(.subheadline)
                        .foregroundStyle(onBackup ? Color.orange : Color.secondary)
                }
                HStack(spacing: 10) {
                    if let l = n.latency { Label("\(Int(l)) ms", systemImage: "timer") }
                    if let c = n.clients { Label("\(c) Geräte", systemImage: "laptopcomputer.and.iphone") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }


    // MARK: Wohin geht der Verkehr?

    /// Zugeklappt: nur eine Zeile „x über 1&1 · y über Starlink“, aufgeklappt die Umschalter
    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { trafficOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wohin geht der Verkehr?").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(trafficSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(trafficOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if trafficOpen {
                if let routes {
                    ForEach(routes) { r in routeRow(r) }
                    Text(isParent ? "Grün = so geht das Netz gerade ins Internet. Antippen zum Umschalten."
                                  : "Welches Netz über welchen Anschluss ins Internet geht.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            if let modeError {
                Label(modeError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var trafficSummary: String {
        guard let routes else { return "wird geladen …" }
        let sl = routes.filter(\.starlink).count
        let one = routes.count - sl
        var parts: [String] = []
        if one > 0 { parts.append("\(one) \(one == 1 ? "Netz" : "Netze") über 1&1") }
        if sl > 0 { parts.append("\(sl) über Starlink") }
        if routes.contains(where: { $0.starlink && $0.killSwitch }) { parts.append("Notaus an") }
        return parts.isEmpty ? "keine Umleitungen" : parts.joined(separator: " · ")
    }

    private func routeRow(_ r: AppStore.NetRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.netLabel(r.name)).font(.subheadline.weight(.semibold))
                    if let sub = r.subnet { Text(sub).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                }
                Spacer()
                if routeBusy == r.id {
                    ProgressView()
                } else if isParent {
                    WanChooser(starlink: r.starlink) { want in switchRoute(r, to: want) }
                } else {
                    Text(r.starlink ? "Starlink" : "1&1").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(.white)
                        .background(Color.green.gradient, in: Capsule())
                }
            }
            if r.starlink && isParent && routeBusy != r.id {
                Button { toggleKill(r) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: r.killSwitch ? "lock.fill" : "lock.open")
                        Text(r.killSwitch ? "Notaus an – bei Starlink-Ausfall kein Internet" : "Notaus aus – bei Ausfall springt 1&1 ein")
                        Spacer()
                        Text(r.killSwitch ? "aus­schalten" : "an­schalten").foregroundStyle(Color.accentColor)
                    }
                    .font(.caption)
                    .foregroundStyle(r.killSwitch ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func toggleKill(_ r: AppStore.NetRoute) {
        let want = !r.killSwitch
        confirm = .init(title: want ? "Notaus für \(Self.netLabel(r.name)) einschalten?" : "Notaus für \(Self.netLabel(r.name)) ausschalten?",
                        message: want
                        ? "Fällt Starlink aus, hat dieses Netz dann gar kein Internet – es weicht nicht auf 1&1 aus."
                        : "Fällt Starlink aus, geht dieses Netz automatisch über 1&1 weiter ins Internet.") {
            routeBusy = r.id
            modeError = await store.setNetRoute(r.id, starlink: true, killSwitch: want)
            routes = await store.loadNetRoutes() ?? routes
            routeBusy = nil
        }
    }

    private func switchRoute(_ r: AppStore.NetRoute, to want: Bool) {
        guard want != r.starlink else { return }
        confirm = .init(title: "\(Self.netLabel(r.name)) über \(want ? "Starlink" : "1&1")?",
                        message: r.name.lowercased().contains("smarthome")
                        ? "Home Assistant ist in diesem Netz – die App ist von unterwegs ca. 1 Minute nicht erreichbar, bis Nabu Casa neu verbunden ist."
                        : "Laufende Downloads oder Videoanrufe in diesem Netz können kurz abbrechen.") {
            routeBusy = r.id
            modeError = await store.setNetRoute(r.id, starlink: want)
            routes = await store.loadNetRoutes() ?? routes
            routeBusy = nil
        }
    }

    static func netLabel(_ n: String) -> String {
        ["Guest LAN / WLAN": "Gäste-WLAN", "Mohs Family": "Familien-WLAN", "Mohs": "Hauptnetz (Mohs)",
         "Unifi Management": "UniFi-Geräte"][n] ?? n
    }

    // MARK: Gäste-WLAN

    @ViewBuilder private var guestCard: some View {
        if isParent {
            let on = store.states[FamilyConfig.guestWifiSwitch]?.state == "on"
            NavigationLink { GuestWifiView() } label: {
                Card(title: "Gäste-WLAN", symbol: "wifi") {
                    HStack(spacing: 12) {
                        Image(systemName: on ? "wifi" : "wifi.slash")
                            .font(.title3).foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background((on ? Color.blue : Color.gray).gradient, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(on ? "„Mohs - Gäste“ ist an" : "Gäste-WLAN ist aus").font(.headline)
                            Text("Passwort, verbundene Gäste, sperren").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Anschlüsse

    private func wanCard(_ w: NetStatus.Wan, net: NetStatus) -> some View {
        let active = w.group == net.activeWan
        let role = (w.priority ?? 1) <= 1 ? "Hauptanschluss" : (w.mode == "failover-only" ? "Reserve (springt bei Ausfall ein)" : "Zusatz")
        let isStarlink = w.name.lowercased().contains("starlink")
        return Card(title: w.name, symbol: isStarlink ? "antenna.radiowaves.left.and.right" : "network") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(w.up ? Color.green : Color.red).frame(width: 10, height: 10)
                    Text(w.up ? (active ? "Verbunden · aktiv" : "Verbunden · bereit") : "Getrennt").font(.headline)
                    Spacer()
                    Text(role).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    StatBlock(value: w.latency.map { "\(Int($0)) ms" } ?? "–", label: "Latenz", color: .blue)
                    StatBlock(value: w.availability.map { String(format: "%.1f %%", $0).replacingOccurrences(of: ".0 %", with: " %") } ?? "–",
                              label: "verfügbar", color: .green)
                    StatBlock(value: NetFmt.duration(w.uptime), label: "stabil seit", color: .purple)
                }
                if active {
                    HStack {
                        Label("↓ " + NetFmt.rate(w.rx), systemImage: "arrow.down.circle")
                        Spacer()
                        Label("↑ " + NetFmt.rate(w.tx), systemImage: "arrow.up.circle")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let ip = w.ip, isParent {
                    Text("IP \(ip)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Speedtest

    private func speedCard(_ n: NetStatus) -> some View {
        Card(title: "Speedtest", symbol: "speedometer") {
            VStack(spacing: 10) {
                HStack {
                    StatBlock(value: n.speedDown.map { "\(Int($0))" } ?? "–", label: "↓ Mbit/s", color: .blue)
                    StatBlock(value: n.speedUp.map { "\(Int($0))" } ?? "–", label: "↑ Mbit/s", color: .green)
                    StatBlock(value: n.speedPing.map { "\(Int($0)) ms" } ?? "–", label: "Ping", color: .orange)
                }
                HStack {
                    if let d = n.speedLast {
                        Text("zuletzt \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isParent {
                        Button {
                            speedRunning = true
                            Task {
                                await store.startSpeedtest()
                                try? await Task.sleep(for: .seconds(45))       // Test dauert ca. 30–40 s
                                net = await store.loadNetStatus() ?? net
                                speedRunning = false
                            }
                        } label: {
                            if speedRunning {
                                HStack(spacing: 6) { ProgressView(); Text("misst …") }
                            } else {
                                Label("Jetzt messen", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(speedRunning)
                    }
                }
            }
        }
    }

    // MARK: VPN

    private func vpnCard(_ n: NetStatus) -> some View {
        Card(title: "VPN", symbol: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if n.vpnSites.isEmpty && n.vpnConnections.isEmpty && !n.remoteUserEnabled {
                    Text("Keine VPN-Verbindungen eingerichtet").foregroundStyle(.secondary)
                }
                ForEach(Array(n.vpnSites.enumerated()), id: \.offset) { _, site in
                    let connected = site.connected ?? (n.siteActive > 0)
                    HStack {
                        Image(systemName: connected ? "checkmark.shield.fill" : "xmark.shield.fill")
                            .foregroundStyle(connected ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(site.name).font(.subheadline.weight(.semibold))
                            Text((site.client ? "VPN-Client" : "Standort-Verbindung")
                                 + (site.enabled ? "" : " · ausgeschaltet")
                                 + (connected ? (site.since.map { " · seit " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "") : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(connected ? "verbunden" : "getrennt").font(.caption.weight(.semibold))
                            .foregroundStyle(connected ? Color.green : Color.red)
                    }
                }
                if isParent && !vpnRoutes.isEmpty {
                    Divider()
                    Text("Über VPN umleiten").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(vpnRoutes) { r in
                        HStack(spacing: 10) {
                            Image(systemName: r.on ? "lock.fill" : "lock.open")
                                .foregroundStyle(r.on ? Color.green : Color.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text((r.target == "alles" ? "gesamter Verkehr" : r.target) + " → " + r.vpn)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if vpnBusy == r.id {
                                ProgressView()
                            } else {
                                Toggle(r.name, isOn: Binding(get: { r.on }, set: { want in
                                    Task {
                                        vpnBusy = r.id
                                        if let e = await store.setVPNRoute(r.id, on: want) { modeError = e }
                                        vpnRoutes = await store.loadVPNRoutes()
                                        vpnBusy = nil
                                    }
                                }))
                                .labelsHidden()
                            }
                        }
                    }
                }
                if n.remoteUserEnabled || !n.vpnConnections.isEmpty {
                    Divider()
                    Text(n.vpnConnections.isEmpty ? "Niemand per VPN von unterwegs verbunden"
                                                  : "Von unterwegs verbunden: " + n.vpnConnections.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Starlink

    private var starlinkCard: some View {
        let online = store.states[NetConfig.slOnline]?.state == "on"
        let warnings = NetConfig.slWarnings.filter { store.states[$0.0]?.state == "on" }
        let stowed = store.states[NetConfig.slStow]?.state == "on"
        return Card(title: "Starlink-Schüssel", symbol: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(online ? Color.green : Color.red).frame(width: 10, height: 10)
                    Text(stowed ? "Verstaut" : (online ? "Online" : "Offline")).font(.headline)
                    Spacer()
                    if let w = store.num(NetConfig.slPower) {
                        Label("\(Int(w.rounded())) W", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    StatBlock(value: store.num(NetConfig.slPing).map { "\(Int($0.rounded())) ms" } ?? "–", label: "Ping", color: .blue)
                    StatBlock(value: store.num(NetConfig.slDrop).map { String(format: "%.1f %%", $0) } ?? "–", label: "Paketverlust", color: .orange)
                    StatBlock(value: store.num(NetConfig.slDown).map { String(format: "%.1f", $0) } ?? "–", label: "↓ Mbit/s jetzt", color: .green)
                }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                    let info: Bool = w.0.contains("heizung") || w.0.contains("ruhezustand") || w.0.contains("update")
                    Label(w.1, systemImage: w.2).font(.subheadline)
                        .foregroundStyle(info ? Color.blue : Color.orange)
                }
                if warnings.isEmpty && online {
                    Label("Keine Probleme gemeldet", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
                VStack(spacing: 6) {
                    InfoRow("Daten insgesamt", {
                        guard let d = store.num(NetConfig.slDownTotal), let u = store.num(NetConfig.slUpTotal) else { return nil }
                        return String(format: "↓ %.0f GB · ↑ %.0f GB", d, u)
                    }())
                    InfoRow("Letzter Neustart", HADate.parse(store.states[NetConfig.slLastBoot]?.state).map { $0.formatted(.relative(presentation: .named)) })
                }
                if isParent {
                    Toggle(isOn: Binding(get: { store.states[NetConfig.slSleepSchedule]?.state == "on" },
                                         set: { v in Task { await store.setSwitch(NetConfig.slSleepSchedule, v) } })) {
                        Label("Zeitplan Ruhezustand", systemImage: "moon.zzz")
                    }
                    .font(.subheadline)
                    HStack(spacing: 10) {
                        Button {
                            confirm = .init(title: "Starlink neu starten?", message: "Die Schüssel ist 2–5 Minuten offline. Solange übernimmt 1&1 allein.") {
                                await store.pressButton(NetConfig.slReboot)
                            }
                        } label: { Label("Neustart", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        Button {
                            confirm = .init(title: stowed ? "Schüssel ausfahren?" : "Schüssel verstauen?",
                                            message: stowed ? "Starlink richtet sich wieder aus und geht online."
                                                            : "Die Schüssel klappt flach und ist offline, bis sie wieder ausgefahren wird.") {
                                await store.setSwitch(NetConfig.slStow, !stowed)
                            }
                        } label: {
                            Label(stowed ? "Ausfahren" : "Verstauen", systemImage: stowed ? "arrow.up.to.line" : "arrow.down.to.line")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: Umleitungen

    @ViewBuilder private var routesCard: some View {
        let available = NetConfig.routes.filter { r in store.states[r.0].map { !$0.isUnavailable } ?? false }
        if !available.isEmpty {
            Card(title: "Umleitungen (UniFi)", symbol: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(available.enumerated()), id: \.offset) { _, r in
                        let on = store.states[r.0]?.state == "on"
                        Toggle(isOn: Binding(get: { on }, set: { v in
                            confirm = .init(title: "\(r.1) \(v ? "einschalten" : "ausschalten")?",
                                            message: "Geräte in diesem Netz werden kurz neu verbunden.") {
                                await store.setSwitch(r.0, v)
                            }
                        })) {
                            Text(r.1).font(.subheadline)
                        }
                    }
                    Text("Legt fest, über welchen Anschluss bestimmte Netze ins Internet gehen.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: UDM

    private func udmCard(_ n: NetStatus) -> some View {
        Card(title: "UniFi Dream Machine", symbol: "server.rack") {
            VStack(spacing: 8) {
                if let cpu = n.gwCPU {
                    HStack {
                        Text("CPU").font(.caption).frame(width: 60, alignment: .leading)
                        ProgressView(value: min(cpu, 100), total: 100).tint(cpu > 80 ? .red : .blue)
                        Text("\(Int(cpu)) %").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                    }
                }
                if let mem = n.gwMem {
                    HStack {
                        Text("Speicher").font(.caption).frame(width: 60, alignment: .leading)
                        ProgressView(value: min(mem, 100), total: 100).tint(mem > 90 ? .red : .purple)
                        Text("\(Int(mem)) %").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                    }
                }
                InfoRow("Läuft seit", NetFmt.duration(n.gwUptime))
                InfoRow("Firmware", n.gwVersion)
                if isParent && store.states[NetConfig.udmRestart] != nil {
                    Button(role: .destructive) {
                        confirm = .init(title: "UDM neu starten?", message: "Das ganze Netzwerk und Internet sind für ca. 3–5 Minuten weg – auch Home Assistant ist so lange nicht erreichbar.") {
                            await store.pressButton(NetConfig.udmRestart)
                        }
                    } label: { Label("UDM neu starten", systemImage: "power").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
        }
    }
}


// MARK: - Umleitungen über einen VPN-Client (z. B. Mullvad) an/aus

@MainActor
extension AppStore {
    struct VPNRoute: Identifiable, Hashable {
        let id: String
        let name: String
        let vpn: String
        let target: String
        var on: Bool
    }

    func loadVPNRoutes() async -> [VPNRoute] {
        guard let r = try? await client.callWithResponse("rest_command", "familie_vpn_route_ip",
                                                         ["daten": ["aktion": "liste"]], timeout: 40) else { return [] }
        let c = r["content"] ?? r
        return (c["routen"]?.array ?? []).compactMap { x in
            guard let id = x["id"]?.string else { return nil }
            return VPNRoute(id: id, name: x["name"]?.string ?? "Route", vpn: x["vpn"]?.string ?? "VPN",
                            target: x["ziel"]?.string ?? "", on: x["an"]?.string == "true")
        }
    }

    func setVPNRoute(_ id: String, on: Bool) async -> String? {
        do {
            let r = try await client.callWithResponse("rest_command", "familie_vpn_route_ip",
                                                      ["daten": ["aktion": "schalten", "id": id, "an": on]], timeout: 40)
            let c = r["content"] ?? r
            return c["ok"]?.string == "true" ? nil : (c["error"]?.string ?? "Umschalten fehlgeschlagen")
        } catch { return error.localizedDescription }
    }
}
