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
    var wans: [WAN] = []
    var history: [Sample] = []

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
        history = h
    }
}

@MainActor
extension AppStore {
    func loadWorldTraffic(seconds: Int) async throws -> WorldTraffic {
        let r = try await client.callWithResponse("rest_command", "familie_weltkarte",
                                                  ["daten": ["sekunden": seconds]], timeout: 25)
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
    @State private var position: MapCameraPosition = .camera(MapCamera(centerCoordinate: .init(latitude: 35, longitude: 10),
                                                                        distance: 28_000_000))
    @State private var selected: WorldTraffic.Target?
    @State private var lines = true

    /// Punkte leben 12 s nach der letzten Verbindung und verblassen dabei
    private let lifetime = 12.0

    private var home: CLLocationCoordinate2D {
        store.homeCoordinate ?? .init(latitude: 51.2, longitude: 10.4)
    }
    private var livePlaces: [WorldTraffic.Place] { data.places.filter { $0.alter < lifetime } }
    private var maxN: Int { max(1, livePlaces.map(\.n).max() ?? 1) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                bandwidthCard
                mapCard
                if !data.syslogActive && loaded { setupCard }
                if !data.countries.isEmpty { countryStrip }
                if !data.targets.isEmpty { targetList }
                Text("IP-Standorte: DB-IP.com (CC BY 4.0) · Ortsangaben sind ungefähr – oft der Standort des Rechenzentrums.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Weltkarte")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func load() async {
        do {
            let d = try await store.loadWorldTraffic(seconds: Int(lifetime) + 3)
            withAnimation(.easeInOut(duration: 0.6)) { data = d; loaded = true; error = nil }
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
                .chartForegroundStyleScale(range: [Color.cyan.opacity(0.75), Color.orange.opacity(0.75), Color.green.opacity(0.75)])
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
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                if lines {
                    ForEach(livePlaces.prefix(14)) { p in
                        MapPolyline(coordinates: [home, p.coord], contourStyle: .geodesic)
                            .stroke(Color.cyan.opacity(0.55 * fade(p)), style: StrokeStyle(lineWidth: 1.2 + 2 * weight(p), lineCap: .round))
                    }
                }
                Annotation("", coordinate: home, anchor: .center) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.25)).frame(width: 22, height: 22)
                        Image(systemName: "house.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Color.indigo, in: Circle())
                    }
                }
                ForEach(livePlaces) { p in
                    Annotation("", coordinate: p.coord, anchor: .center) {
                        PulseDot(size: 8 + 26 * weight(p), color: color(p), fresh: p.alter < 3)
                            .opacity(fade(p))
                    }
                }
            }
            .mapStyle(.imagery(elevation: .flat))
            .colorScheme(.dark)
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(data.syslogActive ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(data.syslogActive ? "\(livePlaces.count) Orte live" : "wartet auf Daten")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                .environment(\.colorScheme, .dark)
                Spacer()
                Button { withAnimation { lines.toggle() } } label: {
                    Image(systemName: lines ? "point.topleft.down.to.point.bottomright.curvepath.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(8).background(.ultraThinMaterial.opacity(0.9), in: Circle())
                }
                .environment(\.colorScheme, .dark)
            }
            .padding(12)
        }
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
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
            }
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top-Ziele gerade").font(.headline).padding(.bottom, 8)
            ForEach(data.targets.prefix(12)) { z in
                Button {
                    if let la = z.lat, let lo = z.lon {
                        withAnimation(.easeInOut(duration: 1.2)) {
                            position = .camera(MapCamera(centerCoordinate: .init(latitude: la, longitude: lo), distance: 4_000_000))
                        }
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
        .cardSurface()
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
