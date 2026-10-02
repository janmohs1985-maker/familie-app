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
        var ort: String = ""
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
    struct Ruckler: Identifiable, Hashable {
        var id: Date { start }
        let start: Date
        let ende: Date
        let von: Double
        let auf: Double
        var dauer: Int { max(10, Int(ende.timeIntervalSince(start))) }
    }
    struct Session: Identifiable, Hashable {
        var id: Date { start }
        let start: Date
        let ende: Date
        let mbit: Double
        let ruckler: Int
    }
    var sessionStart: Date?
    var sessionRuckler = 0
    var ruckler: [Ruckler] = []
    var sessions: [Session] = []
    var melden = false
    /// gerade etwas am Laufen?
    var streaming: Bool { sessionStart != nil || rx > 1_000_000 }

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
                 blockiert: (v["aktion"]?.string ?? "").lowercased().contains("block"),
                 ort: v["ort"]?.string ?? "")
        }
        func sec(_ v: JSONValue?) -> Date { Date(timeIntervalSince1970: v?.double ?? 0) }
        if let st = c["sitzung"], st.object != nil {
            sessionStart = sec(st["start"])
            sessionRuckler = st["ruckler"]?.int ?? 0
        }
        ruckler = (c["ruckler"]?.array ?? []).map { r in
            Ruckler(start: sec(r["start"]), ende: sec(r["ende"]), von: r["von"]?.double ?? 0, auf: r["auf"]?.double ?? 0)
        }
        sessions = (c["sitzungen"]?.array ?? []).map { r in
            Session(start: sec(r["start"]), ende: sec(r["ende"]), mbit: r["mbit"]?.double ?? 0, ruckler: r["ruckler"]?.int ?? 0)
        }
        melden = c["melden"]?.string == "true"
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
    func setIPTVAlert(_ on: Bool) async {
        _ = try? await client.callWithResponse("rest_command", "familie_iptv",
                                               ["daten": ["aktion": "melden", "an": on]], timeout: 30)
    }

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

struct ConnCard: View {
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
                    Text([c.ort, c.domain, ":" + String(st.port)].filter { !$0.isEmpty }.joined(separator: " "))
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
