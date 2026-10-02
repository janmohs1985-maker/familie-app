import SwiftUI
import Charts

// MARK: - Netzwerk-Cockpit (Entwurf 7): Auswahl-Kacheln oben, Inhalt darunter

enum NetTab: String, CaseIterable, Identifiable {
    case overview, world, streaming, vpn
    var id: String { rawValue }
}

enum WanColor {
    static func of(_ key: String) -> Color {
        switch key {
        case "wan1": return .blue
        case "wan2": return .orange
        default: return Color.green
        }
    }
}

/// Wischbare Reihe kleiner Auswahl-Kacheln mit Mini-Inhalten
struct NetTabStrip: View {
    @Binding var tab: NetTab
    let live: WorldTraffic
    let stamp: Date
    let iptv: IPTVStatus?
    let vpnUp: Int
    let vpnTotal: Int
    let home: (lat: Double, lon: Double)
    @State private var miniVP = TronViewport()
    @State private var miniCam = GlobeCam()
    @AppStorage("weltStil") private var worldStyle = WorldStyle.karte.rawValue

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                tile(.overview) {
                    Text("Übersicht").font(.caption.weight(.bold)).foregroundStyle(tab == .overview ? Color.indigo : .secondary)
                    let total = live.wans.reduce(0) { $0 + $1.rx }
                    mbit(total)
                    MiniWanChart(history: live.history).frame(height: 30)
                }
                tile(.world, padding: 6) {
                    Group {
                        if worldStyle == WorldStyle.globus.rawValue {
                            TronGlobe(places: live.places, home: home, lifetime: 12, stamp: stamp,
                                      showLines: true, interactive: false, cam: $miniCam)
                        } else {
                            TronWorldMap(places: live.places, home: home, lifetime: 12, stamp: stamp,
                                         showLines: true, showLabels: false, interactive: false, dots: worldStyle != WorldStyle.neon.rawValue, viewport: $miniVP)
                        }
                    }
                        .frame(height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                    Text("Weltkarte · \(live.places.filter { $0.alter < 12 }.count)")
                        .font(.caption.weight(.bold)).foregroundStyle(tab == .world ? Color.indigo : .secondary)
                        .padding(.horizontal, 4)
                }
                tile(.streaming) {
                    HStack(spacing: 5) {
                        Text("Streaming").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        if iptv?.streaming == true {
                            Text("LIVE").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1)
                                .foregroundStyle(.white).background(Color.pink, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    mbit(iptv?.rx ?? 0)
                    MiniLine(values: (iptv?.verlauf ?? []).suffix(60).map(\.rx), color: .pink).frame(height: 30)
                }
                tile(.vpn) {
                    Text("VPN").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("\(vpnUp)/\(max(vpnTotal, vpnUp))").font(.title3.weight(.heavy)).monospacedDigit()
                    Text(vpnUp > 0 ? "verbunden" : "getrennt").font(.caption2.weight(.semibold))
                        .foregroundStyle(vpnUp > 0 ? Color.green : .red)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .padding(.horizontal, -16)
    }

    private func mbit(_ bps: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(Rate.text(bps)).font(.title3.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
            Text(Rate.unit(bps)).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func tile<C: View>(_ t: NetTab, padding: CGFloat = 10, @ViewBuilder content: () -> C) -> some View {
        let on = tab == t
        return Button {
            withAnimation(.snappy) { tab = t }
        } label: {
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(padding)
                .frame(width: 118, height: 104, alignment: .topLeading)
                .cardSurface(radius: DS.tileRadius)
                .overlay(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                    .strokeBorder(Color.indigo, lineWidth: on ? 2 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Mini-Graph beider Leitungen (feste Farben je Leitung)
struct MiniWanChart: View {
    let history: [WorldTraffic.Sample]
    var body: some View {
        let keys = Array(Set(history.map(\.key))).sorted()
        ZStack {
            ForEach(keys, id: \.self) { k in
                MiniLine(values: history.filter { $0.key == k }.suffix(60).map(\.rx), color: WanColor.of(k),
                         maxValue: history.map(\.rx).max())
            }
        }
    }
}

/// Einfache Sparkline ohne Achsen
struct MiniLine: View {
    let values: [Double]
    let color: Color
    var maxValue: Double? = nil
    var fill = false

    var body: some View {
        GeometryReader { g in
            let mx = max(1, maxValue ?? values.max() ?? 1)
            let n = max(1, values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(n), y: g.size.height * (1 - CGFloat(v / mx)) * 0.92 + 1)
            }
            ZStack {
                if fill, pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: Übersicht-Bausteine

struct NetHeroCard: View {
    let live: WorldTraffic

    var body: some View {
        let total = live.wans.reduce(0) { $0 + $1.rx }
        let up = live.wans.reduce(0) { $0 + $1.tx }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Rate.text(total)).font(.system(size: 46, weight: .heavy, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Text(Rate.unit(total) + " gesamt").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Label(Rate.full(up), systemImage: "arrow.up").font(.caption.weight(.semibold))
                    .foregroundStyle(Color.purple.opacity(0.9)).monospacedDigit()
            }
            if live.history.count > 4 {
                Chart(live.history) { s in
                    AreaMark(x: .value("Zeit", s.t), y: .value("Mbit/s", s.rx / 1_000_000))
                        .foregroundStyle(by: .value("Leitung", s.key))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(domain: ["wan1", "wan2", "wan3"],
                                           range: [Color.blue.opacity(0.55), Color.orange.opacity(0.6), Color.green.opacity(0.55)])
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(d, specifier: "%.0f")") } }
                    }
                }
                .frame(height: 120)
            } else {
                Text("Verlauf wird aufgezeichnet …").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack(spacing: 14) {
                ForEach(live.wans) { w in
                    HStack(spacing: 6) {
                        Circle().fill(WanColor.of(w.key)).frame(width: 8, height: 8)
                        Text(w.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(18)
        .cardSurface(radius: 26)
    }
}

struct WanTile: View {
    let wan: WorldTraffic.WAN
    let history: [WorldTraffic.Sample]
    let subtitle: String

    var body: some View {
        let c = WanColor.of(wan.key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: wan.key == "wan2" ? "dot.radiowaves.up.forward" : "house.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background((wan.up ? c : .red).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(wan.name).font(.footnote.weight(.bold)).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Rate.text(wan.rx)).font(.title2.weight(.heavy)).monospacedDigit().contentTransition(.numericText())
                Text(Rate.unit(wan.rx)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            MiniLine(values: history.filter { $0.key == wan.key }.suffix(60).map(\.rx), color: c, fill: true)
                .frame(height: 30)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 20)
    }
}

struct FamilyWifiCard: View {
    let devices: [WorldTraffic.Device]

    var body: some View {
        let active = devices.filter { $0.rate > 20_000 }
        let mx = max(1, active.map(\.rate).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FAMILY-WLAN ÜBER STARLINK").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(devices.count) Geräte").font(.caption2).foregroundStyle(.secondary)
            }
            if active.isEmpty {
                Text(devices.isEmpty ? "Gerade niemand im Family-WLAN." : "Alle Geräte gerade ruhig.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(active.prefix(6)) { d in
                HStack(spacing: 10) {
                    Text(d.name).font(.subheadline).lineLimit(1)
                    Spacer()
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.orange.opacity(0.15))
                            Capsule().fill(Color.orange).frame(width: max(4, g.size.width * d.rate / mx))
                        }
                    }
                    .frame(width: 100, height: 6)
                    Text(Rate.full(d.rate)).font(.caption.weight(.semibold)).monospacedDigit()
                        .frame(width: 78, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .cardSurface(radius: 20)
    }
}

struct KPITile: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.weight(.heavy)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 18)
    }
}
