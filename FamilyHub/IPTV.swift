import SwiftUI
import Charts

// MARK: - Streaming-Monitor (IPTV, Port 25461)
//
// Family Hub fragt die UniFi-Flows nach Verbindungen auf den IPTV-Port ab (eine eigene Log-Regel
// „Familie-App: IPTV-Log“ macht sie sichtbar), dazu Durchsatz und Zustand des VPN-Tunnels.

struct IPTVStatus {
    struct Conn: Identifiable, Hashable {
        var id: String { mac + ">" + ziel }
        let geraet: String
        let ip: String
        let mac: String
        let netz: String
        let ziel: String
        let domain: String
        let anzahl: Int
        let bytes: Int
        let erst: Date
        let zuletzt: Date
        let vpn: Bool
        let route: Bool
        let blockiert: Bool
        var viaVPN: Bool { vpn || route }
    }
    struct Sample: Identifiable {
        var id: Date { t }
        let t: Date
        let rx: Double      // bit/s
        let tx: Double
        let geraete: [String: Double]
    }
    struct Route: Identifiable, Hashable { let id: String; let name: String; var an: Bool }

    var port = 25461
    var log = false
    var logTreffer = 0
    var tunnelName = "VPN"
    var tunnelUp = false
    var rx: Double = 0
    var tx: Double = 0
    var routen: [Route] = []
    var conns: [Conn] = []
    var verlauf: [Sample] = []

    init() {}

    init(_ c: JSONValue) {
        port = c["port"]?.int ?? 25461
        log = c["log"]?.string == "true"
        logTreffer = c["log_treffer"]?.int ?? 0
        let t = c["tunnel"]
        tunnelName = t?["name"]?.string ?? "VPN"
        tunnelUp = t?["verbunden"]?.string == "true"
        rx = t?["rx"]?.double ?? 0
        tx = t?["tx"]?.double ?? 0
        routen = (c["routen"]?.array ?? []).compactMap { r in
            guard let id = r["id"]?.string else { return nil }
            return Route(id: id, name: r["name"]?.string ?? "Route", an: r["an"]?.string == "true")
        }
        func ms(_ v: JSONValue?) -> Date { Date(timeIntervalSince1970: (v?.double ?? 0) / 1000) }
        conns = (c["verbindungen"]?.array ?? []).map { v in
            Conn(geraet: v["geraet"]?.string ?? "?", ip: v["ip"]?.string ?? "", mac: v["mac"]?.string ?? "",
                 netz: v["netz"]?.string ?? "", ziel: v["ziel"]?.string ?? "", domain: v["domain"]?.string ?? "",
                 anzahl: v["anzahl"]?.int ?? 0, bytes: v["bytes"]?.int ?? 0,
                 erst: ms(v["erst"]), zuletzt: ms(v["zuletzt"]),
                 vpn: v["vpn"]?.string == "true", route: v["route"]?.string == "true",
                 blockiert: (v["aktion"]?.string ?? "").lowercased().contains("block"))
        }
        verlauf = (c["verlauf"]?.array ?? []).map { s in
            var g: [String: Double] = [:]
            for (k, v) in s["g"]?.object ?? [:] { g[k] = v.double ?? 0 }
            return Sample(t: Date(timeIntervalSince1970: s["t"]?.double ?? 0),
                          rx: s["rx"]?.double ?? 0, tx: s["tx"]?.double ?? 0, geraete: g)
        }
    }

    /// Gerät gilt als „streamt gerade“, wenn die letzte neue Verbindung < 15 min her ist
    /// oder es laut UniFi gerade nennenswert Daten bewegt.
    func isLive(_ c: Conn, now: Date = .now) -> Bool {
        if now.timeIntervalSince(c.zuletzt) < 15 * 60 { return true }
        if let r = verlauf.last?.geraete[c.ip], r > 500_000 { return true }
        return false
    }
}

@MainActor
extension AppStore {
    func loadIPTV(setup: Bool = false) async throws -> IPTVStatus {
        var d: [String: Any] = ["minuten": 180]
        if setup { d["aktion"] = "einrichten" }
        let r = try await client.callWithResponse("rest_command", "familie_iptv", ["daten": d], timeout: 40)
        let c = r["content"] ?? r
        if c["ok"]?.string != "true" { throw HAError.unexpected(c["error"]?.string ?? "Family Hub nicht erreichbar") }
        return IPTVStatus(c)
    }
}

enum Rate {
    static func text(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f", bps / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if bps >= 1_000 { return String(format: "%.0f", bps / 1_000) }
        return String(format: "%.0f", bps)
    }
    static func unit(_ bps: Double) -> String { bps >= 1_000_000 ? "Mbit/s" : (bps >= 1_000 ? "kbit/s" : "bit/s") }
    static func full(_ bps: Double) -> String { text(bps) + " " + unit(bps) }
}

struct IPTVView: View {
    @Environment(AppStore.self) private var store
    @State private var st: IPTVStatus?
    @State private var error: String?
    @State private var routeBusy: String?
    @State private var setupBusy = false

    private var live: [IPTVStatus.Conn] { (st?.conns ?? []).filter { st?.isLive($0) ?? false } }
    private var older: [IPTVStatus.Conn] { (st?.conns ?? []).filter { !(st?.isLive($0) ?? false) } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error { errorCard(error) }
                if let st {
                    hero(st)
                    if !st.routen.isEmpty { routeCard(st) }
                    devicesSection(st)
                    if !st.log || (st.logTreffer == 0 && st.conns.isEmpty) { logHint(st) }
                } else if error == nil {
                    ProgressView("Frage UniFi …").frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Streaming")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func load(setup: Bool = false) async {
        do {
            let s = try await store.loadIPTV(setup: setup)
            withAnimation(.easeInOut(duration: 0.35)) { st = s; error = nil }
        } catch {
            if st == nil { self.error = error.localizedDescription }
        }
    }

    // MARK: Kopf mit Live-Durchsatz und Graph

    private func hero(_ s: IPTVStatus) -> some View {
        let live = !self.live.isEmpty || s.rx > 1_000_000
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(s.tunnelUp ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: s.tunnelUp ? .green : .red, radius: 4)
                Text(s.tunnelUp ? "Tunnel verbunden" : "Tunnel getrennt")
                    .font(.caption.weight(.semibold))
                Text("· " + s.tunnelName).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer()
                if live {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.red.gradient, in: Capsule())
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Rate.text(s.rx))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text(Rate.unit(s.rx)).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Label(Rate.full(s.rx), systemImage: "arrow.down").foregroundStyle(Color.cyan)
                    Label(Rate.full(s.tx), systemImage: "arrow.up").foregroundStyle(Color.purple.opacity(0.9))
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
            }
            Text("durch den VPN-Tunnel").font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.top, -10)
            chart(s)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.20), Color(red: 0.16, green: 0.08, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder private func chart(_ s: IPTVStatus) -> some View {
        let pts = s.verlauf
        if pts.count < 2 {
            HStack { Spacer(); Text("Verlauf wird aufgezeichnet …").font(.caption).foregroundStyle(.white.opacity(0.5)); Spacer() }
                .frame(height: 130)
        } else {
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Zeit", p.t), y: .value("Mbit/s", p.rx / 1_000_000), series: .value("R", "rx"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Color.cyan.opacity(0.55), Color.cyan.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Zeit", p.t), y: .value("Mbit/s", p.rx / 1_000_000), series: .value("R", "rx"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    LineMark(x: .value("Zeit", p.t), y: .value("Mbit/s", p.tx / 1_000_000), series: .value("R", "tx"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.purple.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                }
                if let l = pts.last {
                    PointMark(x: .value("Zeit", l.t), y: .value("Mbit/s", l.rx / 1_000_000))
                        .foregroundStyle(.white).symbolSize(40)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.white.opacity(0.5))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(d, specifier: "%.0f")") } }
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 130)
        }
    }

    // MARK: Route-Schalter

    private func routeCard(_ s: IPTVStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Port \(String(s.port)) über VPN", systemImage: "lock.shield.fill")
                .font(.headline)
            ForEach(s.routen) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.subheadline.weight(.semibold))
                        Text(r.an ? "Streams gehen durch den Tunnel" : "Streams gehen direkt raus")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if routeBusy == r.id { ProgressView() }
                    Toggle("", isOn: Binding(get: { r.an }, set: { want in
                        routeBusy = r.id
                        Task {
                            if let e = await store.setVPNRoute(r.id, on: want) { error = e }
                            await load()
                            routeBusy = nil
                        }
                    }))
                    .labelsHidden().disabled(routeBusy != nil)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: Geräte

    @ViewBuilder private func devicesSection(_ s: IPTVStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gerade aktiv").font(.title3.weight(.bold))
                Spacer()
                Text("\(live.count)").font(.subheadline.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            if live.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tv.slash").font(.title2).foregroundStyle(.secondary)
                    Text(s.rx > 1_000_000
                         ? "Im Tunnel fließen Daten – die Verbindung ist aber älter als das Protokoll."
                         : "Gerade schaut niemand über Port \(String(s.port)).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
            }
            ForEach(live) { c in ConnCard(c: c, st: s, live: true) }
            if !older.isEmpty {
                Text("Vorhin").font(.headline).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(older.prefix(10)) { c in ConnCard(c: c, st: s, live: false) }
            }
        }
    }

    private func logHint(_ s: IPTVStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Protokoll noch ohne Treffer", systemImage: "info.circle.fill").font(.headline)
            if s.log {
                Text("Die Regel „Familie-App: IPTV-Log“ ist angelegt. Damit UniFi sie zählt, muss sie in UniFi unter Einstellungen › Richtlinien-Engine › Zonen Intern › Extern **ganz oben** stehen (vor „Internet Out Log“).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Damit sichtbar wird, welches Gerät über Port \(String(s.port)) streamt, legt die App in UniFi eine Erlauben-und-Protokollieren-Regel an. Am Verkehr ändert sie nichts.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    setupBusy = true
                    Task { await load(setup: true); setupBusy = false }
                } label: {
                    HStack { if setupBusy { ProgressView() }; Text("Protokoll-Regel anlegen") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(setupBusy)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    private func errorCard(_ e: String) -> some View {
        Label(e, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline).foregroundStyle(.orange)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }
}

private struct ConnCard: View {
    let c: IPTVStatus.Conn
    let st: IPTVStatus
    let live: Bool

    struct Pt: Identifiable { let t: Date; let v: Double; var id: Date { t } }
    private var rates: [Pt] {
        st.verlauf.compactMap { s in s.geraete[c.ip].map { Pt(t: s.t, v: $0) } }
    }
    private var icon: String {
        let n = (c.geraet + " " + c.netz).lowercased()
        if n.contains("tv") || n.contains("fire") || n.contains("apple tv") || n.contains("shield") { return "tv.fill" }
        if n.contains("iphone") || n.contains("pixel") || n.contains("handy") { return "iphone" }
        if n.contains("ipad") || n.contains("tab") { return "ipad" }
        if n.contains("pc") || n.contains("desktop") || n.contains("laptop") || n.contains("mac") { return "desktopcomputer" }
        return "play.tv.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background((live ? Color.indigo : Color.gray).gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    if live {
                        Circle().fill(.green).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 4, y: -4)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.geraet).font(.headline).lineLimit(1)
                    Text([c.ip, c.netz].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                badge
            }

            // Weg: Gerät → (Tunnel) → Ziel
            HStack(spacing: 8) {
                Image(systemName: "house.fill").foregroundStyle(.secondary)
                pathLine
                Image(systemName: c.viaVPN ? "lock.shield.fill" : "globe").foregroundStyle(c.viaVPN ? Color.green : Color.orange)
                pathLine
                VStack(alignment: .trailing, spacing: 1) {
                    Text(c.ziel).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(c.domain.isEmpty ? ":" + String(st.port) : c.domain + " :" + String(st.port))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .textSelection(.enabled)

            if rates.count > 2, live {
                Chart(rates) { p in
                    AreaMark(x: .value("t", p.t), y: .value("bit/s", p.v))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Color.indigo.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", p.t), y: .value("bit/s", p.v))
                        .interpolationMethod(.catmullRom).foregroundStyle(Color.indigo)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 44)
                .overlay(alignment: .topLeading) {
                    Text(Rate.full(rates.last?.v ?? 0)).font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            HStack(spacing: 14) {
                Label(c.erst.formatted(date: .omitted, time: .shortened), systemImage: "play.circle")
                Label(relative(c.zuletzt), systemImage: "clock")
                Label("\(c.anzahl)×", systemImage: "arrow.triangle.branch")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .cardSurface()
        .opacity(live ? 1 : 0.75)
    }

    private var pathLine: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Color.secondary.opacity(0.2), c.viaVPN ? Color.green.opacity(0.7) : Color.orange.opacity(0.7)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 2).frame(maxWidth: .infinity)
    }

    @ViewBuilder private var badge: some View {
        if c.blockiert {
            Text("blockiert").font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Color.red, in: Capsule())
        } else if c.viaVPN {
            Label("VPN", systemImage: "checkmark.shield.fill").font(.caption.weight(.bold)).foregroundStyle(.green)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Color.green.opacity(0.15), in: Capsule())
        } else {
            Label("direkt", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.bold)).foregroundStyle(.orange)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Color.orange.opacity(0.15), in: Capsule())
        }
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date.now.timeIntervalSince(d))
        if s < 60 { return "gerade eben" }
        if s < 3600 { return "vor \(s / 60) min" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}
