import SwiftUI
import MapKit
import Charts

// MARK: - Live-Weltkarte: wohin gehen gerade Verbindungen aus dem Heimnetz?
//
// Quelle: Die UDM schickt die Protokollzeilen der Firewall-Regel „Internet Out Log“ per Syslog an
// Family Hub. Family Hub ordnet die Ziel-IPs über eine lokale Datenbank (DB-IP Lite) einem Ort zu.
// Oben: Auslastung der Internetleitungen direkt aus der UDM.

struct WorldTraffic {
    struct Place: Identifiable, Hashable {
        var id: String { "\(lat),\(lon)" }
        let lat: Double
        let lon: Double
        let land: String
        let landname: String
        let stadt: String
        let n: Int
        let alter: Double
        var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    struct Target: Identifiable, Hashable {
        var id: String { ip }
        let ip: String
        let n: Int
        let dienst: String
        let geraet: String
        let alter: Double
        let land: String
        let ort: String
        let lat: Double?
        let lon: Double?
    }
    struct WAN: Identifiable, Hashable {
        var id: String { key }
        let key: String
        let name: String
        let rx: Double
        let tx: Double
        let up: Bool
        let speed: Double
    }
    struct Sample: Identifiable {
        var id: String { "\(t.timeIntervalSince1970)-\(key)" }
        let t: Date
        let key: String
        let rx: Double
    }

    var syslogActive = false
    var syslogLines = 0
    var syslogError = ""
    var geoReady = false
    var geoError = ""
    var window = 30
    var connections = 0
    var places: [Place] = []
    var targets: [Target] = []
    struct Country: Identifiable, Hashable { var id: String { iso }; let iso: String; let n: Int }
    var countries: [Country] = []
    struct PortStat: Identifiable, Hashable { var id: Int { port }; let port: Int; let dienst: String; let n: Int }
    var ports: [PortStat] = []
    var wans: [WAN] = []
    var history: [Sample] = []
    struct Device: Identifiable, Hashable { var id: String { name }; let name: String; let rate: Double }
    var starlinkDevices: [Device] = []

    init() {}

    init(_ c: JSONValue) {
        syslogActive = c["syslog"]?["aktiv"]?.string == "true"
        syslogLines = c["syslog"]?["zeilen"]?.int ?? 0
        syslogError = c["syslog"]?["fehler"]?.string ?? ""
        geoReady = c["geo"]?["bereit"]?.string == "true"
        geoError = c["geo"]?["fehler"]?.string ?? ""
        window = c["fenster"]?.int ?? 30
        connections = c["verbindungen"]?.int ?? 0
        places = (c["orte"]?.array ?? []).map { o in
            Place(lat: o["lat"]?.double ?? 0, lon: o["lon"]?.double ?? 0, land: o["land"]?.string ?? "",
                  landname: o["landname"]?.string ?? "", stadt: o["stadt"]?.string ?? "",
                  n: o["n"]?.int ?? 1, alter: o["alter"]?.double ?? 0)
        }
        targets = (c["ziele"]?.array ?? []).map { z in
            let g = z["geo"]
            let ort = [g?["stadt"]?.string ?? "", g?["landname"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
            return Target(ip: z["ip"]?.string ?? "", n: z["n"]?.int ?? 0, dienst: z["dienst"]?.string ?? "",
                          geraet: z["geraet"]?.string ?? "", alter: z["alter"]?.double ?? 0,
                          land: g?["land"]?.string ?? "", ort: ort,
                          lat: g?["lat"]?.double, lon: g?["lon"]?.double)
        }
        countries = (c["laender"]?.array ?? []).compactMap { p in
            guard let a = p.array, a.count == 2, let k = a[0].string else { return nil }
            return Country(iso: k, n: a[1].int ?? 0)
        }
        ports = (c["ports"]?.array ?? []).map { p in
            PortStat(port: p["port"]?.int ?? 0, dienst: p["dienst"]?.string ?? "", n: p["n"]?.int ?? 0)
        }
        wans = (c["wan"]?.array ?? []).map { w in
            WAN(key: w["k"]?.string ?? "", name: w["name"]?.string ?? "WAN", rx: w["rx"]?.double ?? 0,
                tx: w["tx"]?.double ?? 0, up: w["up"]?.string == "true", speed: w["speed"]?.double ?? 1000)
        }
        var h: [Sample] = []
        for s in c["verlauf"]?.array ?? [] {
            let t = Date(timeIntervalSince1970: s["t"]?.double ?? 0)
            for (k, v) in s["w"]?.object ?? [:] {
                h.append(Sample(t: t, key: k, rx: v.array?.first?.double ?? 0))
            }
        }
        starlinkDevices = (c["starlink_geraete"]?.array ?? []).map { d in
            Device(name: d["name"]?.string ?? "?", rate: d["rate"]?.double ?? 0)
        }
        history = h.sorted { ($0.t, $0.key) < ($1.t, $1.key) }
    }
}

@MainActor
extension AppStore {
    func loadWorldTraffic(seconds: Int, blocked: Bool = false, devices: Bool = false) async throws -> WorldTraffic {
        let r = try await client.callWithResponse("rest_command", "familie_weltkarte",
                                                  ["daten": ["sekunden": seconds, "modus": blocked ? "block" : "aus",
                                                             "geraete": devices]], timeout: 25)
        let c = r["content"] ?? r
        if c["ok"]?.string != "true" { throw HAError.unexpected(c["error"]?.string ?? "Family Hub nicht erreichbar") }
        return WorldTraffic(c)
    }
}

enum Flag {
    static func emoji(_ iso: String) -> String {
        var out = ""
        for u in iso.uppercased().unicodeScalars {
            if let f = Unicode.Scalar(127397 + u.value) { out.unicodeScalars.append(f) }
        }
        return out
    }
}

struct WorldTrafficView: View {
    @Environment(AppStore.self) private var store
    @State private var data = WorldTraffic()
    @State private var loaded = false
    @State private var error: String?
    @State private var viewport = TronViewport()
    @State private var globeCam = GlobeCam()
    @AppStorage("weltStil") private var style = WorldStyle.karte.rawValue
    @State private var stamp = Date()
    @State private var lines = true
    @State private var fullscreen = false
    @State private var focus: (lat: Double, lon: Double)?
    @State private var blocked = false

    /// Punkte leben 12 s (geblockt: 30 s) nach der letzten Verbindung und verblassen dabei
    private var lifetime: Double { blocked ? 30 : 12 }

    private var home: CLLocationCoordinate2D {
        store.homeCoordinate ?? .init(latitude: 51.2, longitude: 10.4)
    }
    private var homePair: (lat: Double, lon: Double) { (home.latitude, home.longitude) }
    private var livePlaces: [WorldTraffic.Place] { data.places.filter { $0.alter < lifetime } }
    private var maxN: Int { max(1, livePlaces.map(\.n).max() ?? 1) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Richtung", selection: $blocked) {
                    Text("Ausgehend").tag(false)
                    Text("Geblockt von außen").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: blocked) { data = WorldTraffic(); Task { await load() } }
                if !blocked { bandwidthCard }
                mapCard
                if blocked && !data.ports.isEmpty { portStrip }
                if !data.syslogActive && loaded { if blocked { blockSetupCard } else { setupCard } }
                if !data.countries.isEmpty { countryStrip }
                if !data.targets.isEmpty { targetList }
                Text("IP-Standorte: DB-IP.com (CC BY 4.0) · Ortsangaben sind ungefähr – oft der Standort des Rechenzentrums.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("Weltkarte")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $fullscreen) {
            TronFullscreen(initial: data, home: homePair, lifetime: lifetime, focus: focus, blocked: blocked)
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func load() async {
        do {
            let d = try await store.loadWorldTraffic(seconds: Int(lifetime) + 3, blocked: blocked)
            data = d; stamp = .now; loaded = true; error = nil
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }

    // MARK: Auslastung

    private var bandwidthCard: some View {
        let total = data.wans.reduce(0) { $0 + $1.rx }
        let up = data.wans.reduce(0) { $0 + $1.tx }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Internet gerade").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Rate.text(total)).font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit().contentTransition(.numericText())
                        Text(Rate.unit(total)).font(.headline).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Label(Rate.full(total), systemImage: "arrow.down").foregroundStyle(Color.cyan)
                    Label(Rate.full(up), systemImage: "arrow.up").foregroundStyle(Color.purple.opacity(0.9))
                    Text("\(data.connections) neue Verb. / \(Int(lifetime)) s").foregroundStyle(.white.opacity(0.6))
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
            }

            if data.history.count > 4 {
                Chart(data.history) { s in
                    AreaMark(x: .value("Zeit", s.t), y: .value("Mbit/s", s.rx / 1_000_000))
                        .foregroundStyle(by: .value("Leitung", name(s.key)))
                        .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale(domain: data.wans.map(\.name),
                                           range: Array([Color.cyan.opacity(0.75), Color.orange.opacity(0.75), Color.green.opacity(0.75)]
                                               .prefix(max(1, data.wans.count))))
                .chartLegend(.hidden)
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
                .frame(height: 110)
            } else {
                HStack { Spacer(); Text("Verlauf wird aufgezeichnet …").font(.caption).foregroundStyle(.white.opacity(0.5)); Spacer() }
                    .frame(height: 110)
            }

            // je Leitung ein Balken: Anteil an der Leitungsgeschwindigkeit
            ForEach(Array(data.wans.enumerated()), id: \.element.id) { i, w in
                let color = [Color.cyan, .orange, .green][i % 3]
                let cap = max(1, w.speed) * 1_000_000
                HStack(spacing: 10) {
                    Circle().fill(w.up ? color : .red).frame(width: 7, height: 7)
                    Text(w.name).font(.caption.weight(.semibold)).frame(width: 100, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill(color.gradient)
                                .frame(width: max(3, g.size.width * min(1, w.rx / cap)))
                        }
                    }
                    .frame(height: 6)
                    Text(Rate.full(w.rx)).font(.caption.weight(.semibold)).monospacedDigit()
                        .frame(width: 84, alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.16), Color(red: 0.08, green: 0.12, blue: 0.24)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func name(_ key: String) -> String { data.wans.first { $0.key == key }?.name ?? key.uppercased() }

    // MARK: Karte

    private var mapCard: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if style == WorldStyle.globus.rawValue {
                    TronGlobe(places: data.places, home: homePair, lifetime: lifetime, stamp: stamp,
                              showLines: lines, interactive: false, inbound: blocked, cam: $globeCam)
                        .frame(height: 340)
                        .background(Tron.bg)
                } else {
                    TronWorldMap(places: data.places, home: homePair, lifetime: lifetime, stamp: stamp,
                                 showLines: lines, interactive: false, inbound: blocked, dots: style != WorldStyle.neon.rawValue, viewport: $viewport)
                        .aspectRatio(WorldShapes.w0 / WorldShapes.h0, contentMode: .fit)
                }
            }
            .onTapGesture { focus = nil; fullscreen = true }
            HUDFrame().stroke(Tron.cyan.opacity(0.6), lineWidth: 1.2).padding(6).allowsHitTesting(false)
            HStack(spacing: 8) {
                Circle().fill(data.syslogActive ? Tron.cyan : Tron.amber).frame(width: 6, height: 6)
                    .shadow(color: Tron.cyan, radius: 4)
                Text(data.syslogActive ? (blocked ? "ABWEHR · \(data.connections) GEBLOCKT · \(livePlaces.count) QUELLEN" : "NETZ-RADAR · \(livePlaces.count) ZIELE")
                                       : (blocked ? "KEINE GEBLOCKTEN DATEN" : "WARTE AUF DATEN"))
                Spacer()
                Button { withAnimation(.snappy) { style = WorldStyle.next(style) } } label: {
                    Image(systemName: WorldStyle.nextIcon(style))
                }
                .accessibilityLabel(WorldStyle.nextLabel(style))
                Button { withAnimation { lines.toggle() } } label: {
                    Image(systemName: lines ? "point.topleft.down.to.point.bottomright.curvepath.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                }
                Button { focus = nil; fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Tron.cyan)
            .padding(.horizontal, 14).padding(.top, 12)
        }
        .background(Tron.bg)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tron.cyan.opacity(0.25)))
        .shadow(color: Tron.cyan.opacity(0.25), radius: 14)
    }

    private func weight(_ p: WorldTraffic.Place) -> Double { sqrt(Double(p.n) / Double(maxN)) }
    private func fade(_ p: WorldTraffic.Place) -> Double { max(0.15, 1 - p.alter / lifetime) }
    private func color(_ p: WorldTraffic.Place) -> Color {
        let w = weight(p)
        return w > 0.7 ? Color(red: 1, green: 0.35, blue: 0.45) : (w > 0.35 ? Color.orange : Color.cyan)
    }

    // MARK: Länder + Ziele

    private var countryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(data.countries) { c in
                    HStack(spacing: 5) {
                        Text(Flag.emoji(c.iso))
                        Text(c.iso).font(.caption.weight(.bold))
                        Text("\(c.n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Tron.bg, in: Capsule())
                    .overlay(Capsule().strokeBorder(Tron.cyan.opacity(0.3)))
                }
            }
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(blocked ? "Wer klopft gerade an?" : "Top-Ziele gerade").font(.headline).padding(.bottom, 8)
            ForEach(data.targets.prefix(12)) { z in
                Button {
                    if let la = z.lat, let lo = z.lon {
                        focus = (la, lo)
                        fullscreen = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(z.land.isEmpty ? "🌐" : Flag.emoji(z.land)).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(z.ort.isEmpty ? z.ip : z.ort).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text([z.ip, z.dienst, z.geraet].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(z.n)").font(.subheadline.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background((z.dienst == "IPTV" ? Color.pink : Color.accentColor).opacity(0.15), in: Capsule())
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if z.id != data.targets.prefix(12).last?.id { Divider() }
            }
        }
        .padding(16)
        .background(Tron.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tron.cyan.opacity(0.2)))
    }

    private var portStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Angefragte Dienste").font(.headline)
            let mx = max(1, data.ports.map(\.n).max() ?? 1)
            ForEach(data.ports) { p in
                HStack(spacing: 10) {
                    Text(p.dienst).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 120, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(LinearGradient(colors: [Tron.amber, Tron.hot], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, g.size.width * CGFloat(p.n) / CGFloat(mx)))
                    }
                    .frame(height: 6)
                    Text("\(p.n)").font(.system(size: 12, weight: .bold, design: .monospaced)).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .foregroundStyle(Tron.hot)
        .padding(16)
        .background(Tron.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tron.hot.opacity(0.3)))
    }

    private var blockSetupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Noch keine geblockten Verbindungen", systemImage: "shield.lefthalf.filled").font(.headline)
            Text("Die UDM protokolliert geblockte Zugriffe von außen erst, wenn bei den Standard-Regeln **„Block All Traffic“** für **External → Gateway** und **External → Internal** das Protokollieren (Syslog) an ist.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Noch keine Verbindungsdaten", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            Text("In UniFi unter **Einstellungen › CyberSecure › Traffic Logging** (bzw. „SIEM Server“ / „Remote Syslog“) als Server die Home-Assistant-IP **10.10.2.10** und Port **5514** eintragen. In der Regel „Internet Out Log“ muss Protokollieren an sein.")
                .font(.subheadline).foregroundStyle(.secondary)
            if data.syslogLines > 0 {
                Text("\(data.syslogLines) Syslog-Zeilen empfangen, aber noch keine Verbindungen erkannt.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !data.syslogError.isEmpty { Text(data.syslogError).font(.caption).foregroundStyle(.red) }
            if !data.geoError.isEmpty { Text("Standorte: " + data.geoError).font(.caption).foregroundStyle(.red) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }
}

/// Punkt, der beim Auftauchen „aufploppt“ und pulsiert
private struct PulseDot: View {
    let size: CGFloat
    let color: Color
    let fresh: Bool
    @State private var pulse = false
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.25))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(pulse ? 1.15 : 0.6)
                .opacity(pulse ? 0 : 0.9)
            Circle().fill(color.opacity(0.35)).frame(width: size * 1.4, height: size * 1.4).blur(radius: 3)
            Circle().fill(color).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: fresh ? 1.5 : 0.5))
                .shadow(color: color, radius: fresh ? 8 : 3)
        }
        .scaleEffect(shown ? 1 : 0.1)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { shown = true }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Vollbild: Karte quer über den ganzen Bildschirm, mit Zoomen und Verschieben

struct TronFullscreen: View {
    let initial: WorldTraffic
    let home: (lat: Double, lon: Double)
    let lifetime: Double
    var focus: (lat: Double, lon: Double)?
    var blocked = false

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var data = WorldTraffic()
    @State private var stamp = Date()
    @State private var viewport = TronViewport()
    @State private var globeCam = GlobeCam()
    @AppStorage("weltStil") private var style = WorldStyle.karte.rawValue
    @State private var landscape = true
    @State private var lines = true
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            let full = geo.size
            let inner = landscape ? CGSize(width: full.height, height: full.width) : full
            ZStack {
                Tron.bg.ignoresSafeArea()
                content(inner)
                    .frame(width: inner.width, height: inner.height)
                    .rotationEffect(.degrees(landscape ? 90 : 0))
                    .position(x: full.width / 2, y: full.height / 2)
            }
            .onAppear {
                guard !started else { return }
                started = true
                data = initial
                if let f = focus, style == WorldStyle.globus.rawValue {
                    globeCam = GlobeCam(lat0: f.lat, lon0: f.lon, zoom: 1.6, touched: Date.now.timeIntervalSinceReferenceDate + 5)
                } else if let f = focus {
                    let s = TronViewport(zoom: 4).scale(in: inner)
                    let u = WorldShapes.project(lat: f.lat, lon: f.lon)
                    viewport = TronViewport(zoom: 4, pan: CGSize(width: (WorldShapes.w0 / 2 - u.x) * s,
                                                                 height: (WorldShapes.h0 / 2 - u.y) * s)).clamped(in: inner)
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task {
            while !Task.isCancelled {
                if let d = try? await store.loadWorldTraffic(seconds: Int(lifetime) + 3, blocked: blocked) { data = d; stamp = .now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func content(_ size: CGSize) -> some View {
        ZStack {
            if style == WorldStyle.globus.rawValue {
                TronGlobe(places: data.places, home: home, lifetime: lifetime, stamp: stamp,
                          showLines: lines, rotated: landscape, inbound: blocked, cam: $globeCam)
                    .background(Tron.bg)
            } else {
                TronWorldMap(places: data.places, home: home, lifetime: lifetime, stamp: stamp,
                             showLines: lines, rotated: landscape, inbound: blocked, dots: style != WorldStyle.neon.rawValue, viewport: $viewport)
            }
            HUDFrame().stroke(Tron.cyan.opacity(0.7), lineWidth: 1.5).padding(landscape ? 18 : 10).allowsHitTesting(false)
            hud(size)
        }
    }

    private func hud(_ size: CGSize) -> some View {
        let down = data.wans.reduce(0) { $0 + $1.rx }
        let up = data.wans.reduce(0) { $0 + $1.tx }
        let live = data.places.filter { $0.alter < lifetime }
        return VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(blocked ? "ABWEHR // MOHS" : "NETZ-RADAR // MOHS").font(.system(size: 13, weight: .heavy, design: .monospaced))
                    Text("\(blocked ? "GEBLOCKT" : "LINKS") \(data.connections) · \(blocked ? "QUELLEN" : "ZIELE") \(live.count) · ZOOM \(String(format: "%.1f", style == WorldStyle.globus.rawValue ? globeCam.zoom : viewport.zoom))×")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.75)
                }
                Spacer()
                HStack(spacing: 14) {
                    hudButton(WorldStyle.nextIcon(style)) {
                        style = WorldStyle.next(style)
                    }
                    hudButton(lines ? "point.topleft.down.to.point.bottomright.curvepath.fill" : "point.topleft.down.to.point.bottomright.curvepath") { lines.toggle() }
                    hudButton("arrow.counterclockwise") { withAnimation(.spring) { viewport = TronViewport(); globeCam = GlobeCam() } }
                    hudButton(landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                        viewport = TronViewport(); landscape.toggle()
                    }
                    hudButton("xmark") { dismiss() }
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(data.wans) { w in
                        Text("\(w.name.uppercased())  ▼ \(Rate.full(w.rx))  ▲ \(Rate.full(w.tx))")
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.85)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Rate.text(down)).font(.system(size: 34, weight: .bold, design: .monospaced))
                        .contentTransition(.numericText())
                    Text("\(Rate.unit(down)) ▼   \(Rate.full(up)) ▲").font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.75)
                }
            }
            if !data.countries.isEmpty {
                HStack(spacing: 10) {
                    ForEach(data.countries.prefix(6)) { c in
                        Text("\(Flag.emoji(c.iso)) \(c.iso) \(c.n)")
                    }
                    Spacer()
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.top, 4)
            }
        }
        .foregroundStyle(blocked ? Tron.hot : Tron.cyan)
        .shadow(color: (blocked ? Tron.hot : Tron.cyan).opacity(0.6), radius: 6)
        .padding(.horizontal, landscape ? 34 : 22)
        .padding(.vertical, landscape ? 28 : 60)
    }

    private func hudButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Tron.bg.opacity(0.7), in: Circle())
                .overlay(Circle().strokeBorder(Tron.cyan.opacity(0.5)))
        }
    }
}
