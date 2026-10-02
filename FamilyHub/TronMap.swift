import SwiftUI

// MARK: - Weltkarte im HUD-Look (schwarz, Neon-Linien), selbst gezeichnet
//
// Umrisse: Natural Earth (gemeinfrei), 1:110m Länder + 1:50m Küsten, als kompakte Binärdateien im App-Bundle.

enum WorldShapes {
    static let w0: CGFloat = 1000
    static let latTop: Double = 84
    static let latBottom: Double = -58
    static var h0: CGFloat { w0 * CGFloat((latTop - latBottom) / 360) }

    static func project(lat: Double, lon: Double) -> CGPoint {
        let x = (lon + 180) / 360 * Double(w0)
        let y = (latTop - max(latBottom, min(latTop, lat))) / 360 * Double(w0)
        return CGPoint(x: x, y: y)
    }

    static let countries: Path = load("world_countries", q: 10)
    static let land: Path = load("world_land", q: 20)
    static let grid: Path = {
        var p = Path()
        for lon in stride(from: -180.0, through: 180.0, by: 15) {
            p.move(to: project(lat: latTop, lon: lon)); p.addLine(to: project(lat: latBottom, lon: lon))
        }
        for lat in stride(from: -45.0, through: 75.0, by: 15) {
            p.move(to: project(lat: lat, lon: -180)); p.addLine(to: project(lat: lat, lon: 180))
        }
        return p
    }()

    private static func load(_ name: String, q: Double) -> Path {
        var p = Path()
        guard let url = Bundle.main.url(forResource: name, withExtension: "bin"),
              let d = try? Data(contentsOf: url), d.count > 4 else { return p }
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = 0
            func u32() -> Int { let v = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self); o += 4; return Int(UInt32(littleEndian: v)) }
            func i16() -> Double { let v = raw.loadUnaligned(fromByteOffset: o, as: Int16.self); o += 2; return Double(Int16(littleEndian: v)) }
            let rings = u32()
            for _ in 0..<rings {
                guard o + 4 <= raw.count else { break }
                let n = u32()
                guard o + n * 4 <= raw.count else { break }
                for i in 0..<n {
                    let lon = i16() / q, lat = i16() / q
                    let pt = project(lat: lat, lon: lon)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
            }
        }
        return p
    }
}

enum Tron {
    static let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)
    static let deep = Color(red: 0.0, green: 0.35, blue: 0.45)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.11)
    static let hot = Color(red: 1.0, green: 0.18, blue: 0.39)
    static let bg = Color(red: 0.0, green: 0.02, blue: 0.04)
}

/// Zoom/Verschiebung der Karte (wird von Karte und Vollbild geteilt)
struct TronViewport {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    func scale(in size: CGSize) -> CGFloat { min(size.width / WorldShapes.w0, size.height / WorldShapes.h0) * zoom }
    func transform(in size: CGSize) -> CGAffineTransform {
        let s = scale(in: size)
        let ox = size.width / 2 + pan.width - WorldShapes.w0 * s / 2
        let oy = size.height / 2 + pan.height - WorldShapes.h0 * s / 2
        return CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
    }
    func clamped(in size: CGSize) -> TronViewport {
        var v = self
        v.zoom = min(14, max(1, zoom))
        let s = v.scale(in: size)
        let mx = max(0, (WorldShapes.w0 * s - size.width) / 2)
        let my = max(0, (WorldShapes.h0 * s - size.height) / 2)
        v.pan = CGSize(width: min(mx, max(-mx, pan.width)), height: min(my, max(-my, pan.height)))
        return v
    }
}

struct TronWorldMap: View {
    let places: [WorldTraffic.Place]
    let home: (lat: Double, lon: Double)
    let lifetime: Double
    /// Zeitpunkt der Daten – das Alter der Punkte läuft zwischen zwei Abfragen weiter
    var stamp: Date = .now
    var showLines = true
    var showLabels = true
    /// Karte ist um 90° gedreht dargestellt (Vollbild „quer“) – Wischgesten werden umgerechnet
    var rotated = false
    /// false = Vorschau ohne Gesten (z. B. in einer ScrollView)
    var interactive = true
    /// geblockter Verkehr von außen: rote Farben, Impulse laufen zum Haus
    var inbound = false
    @Binding var viewport: TronViewport

    @State private var base: TronViewport?

    private var maxN: Int { max(1, places.map(\.n).max() ?? 1) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let t = viewport.transform(in: size)
            ZStack {
                Tron.bg
                staticLayer(t: t, size: size)
                    .drawingGroup()
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    dynamicLayer(t: t, time: tl.date.timeIntervalSinceReferenceDate, size: size)
                }
                .allowsHitTesting(false)
                scanlines.allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(panZoom(size), including: interactive ? .all : .subviews)
            .onTapGesture(count: 2) {
                guard interactive else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    viewport = (viewport.zoom > 3 ? TronViewport() : TronViewport(zoom: viewport.zoom * 2.2, pan: viewport.pan * 2.2))
                        .clamped(in: size)
                }
            }
        }
        .clipped()
    }

    // MARK: Gesten

    private func panZoom(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .simultaneously(with: MagnifyGesture())
            .onChanged { v in
                if base == nil { base = viewport }
                let b = base ?? viewport
                let z = min(14, max(1, b.zoom * (v.second?.magnification ?? 1)))
                let f = z / b.zoom
                var pan = CGSize(width: b.pan.width * f, height: b.pan.height * f)
                if let d = v.first?.translation {
                    let local = rotated ? CGSize(width: d.height, height: -d.width) : d
                    pan.width += local.width
                    pan.height += local.height
                }
                viewport = TronViewport(zoom: z, pan: pan).clamped(in: size)
            }
            .onEnded { _ in base = nil }
    }

    // MARK: Statische Ebene: Raster, Länder, Küsten mit Glühen

    private func staticLayer(t: CGAffineTransform, size: CGSize) -> some View {
        let zoom = viewport.zoom
        return Canvas { ctx, _ in
            let grid = WorldShapes.grid.applying(t)
            ctx.stroke(grid, with: .color(Tron.cyan.opacity(0.07)), lineWidth: 0.5)

            let countries = WorldShapes.countries.applying(t)
            let coast = (zoom > 2.2 ? WorldShapes.land : WorldShapes.countries).applying(t)
            ctx.fill(countries, with: .color(Tron.deep.opacity(0.18)))
            // Glühen
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 5))
                g.stroke(coast, with: .color(Tron.cyan.opacity(0.55)), lineWidth: 2.5)
            }
            // Ländergrenzen fein, Küste hell
            ctx.stroke(countries, with: .color(Tron.cyan.opacity(0.28)), lineWidth: 0.5)
            ctx.stroke(coast, with: .color(Tron.cyan.opacity(0.9)), lineWidth: zoom > 2.2 ? 0.9 : 0.7)
        }
    }

    // MARK: Bewegte Ebene: Bögen, Punkte, Zuhause

    private func dynamicLayer(t: CGAffineTransform, time: Double, size: CGSize) -> some View {
        Canvas { ctx, _ in
            let h = WorldShapes.project(lat: home.lat, lon: home.lon).applying(t)
            let extra = max(0, time - stamp.timeIntervalSinceReferenceDate)
            func age(_ p: WorldTraffic.Place) -> Double { p.alter + extra }
            func fadeOf(_ p: WorldTraffic.Place) -> Double { max(0, 1 - age(p) / lifetime) }
            let live = places.filter { age($0) < lifetime }

            if showLines {
                for (i, p) in live.prefix(18).enumerated() {
                    let q = WorldShapes.project(lat: p.lat, lon: p.lon).applying(t)
                    let dx = q.x - h.x, dy = q.y - h.y
                    let dist = sqrt(dx * dx + dy * dy)
                    guard dist > 4 else { continue }
                    let mid = CGPoint(x: (h.x + q.x) / 2, y: (h.y + q.y) / 2 - dist * 0.28)
                    var arc = Path(); arc.move(to: h); arc.addQuadCurve(to: q, control: mid)
                    let fade = fadeOf(p)
                    let c = colorOf(p)
                    ctx.stroke(arc, with: .color(c.opacity(0.22 * fade)), lineWidth: 1)
                    // Lichtimpuls, der zum Ziel läuft
                    let ph0 = (time * 0.55 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)
                    let ph = inbound ? 1 - ph0 : ph0
                    let seg = inbound ? arc.trimmedPath(from: ph, to: min(1, ph + 0.18))
                                      : arc.trimmedPath(from: max(0, ph - 0.18), to: ph)
                    ctx.drawLayer { g in
                        g.addFilter(.blur(radius: 3))
                        g.stroke(seg, with: .color(c.opacity(0.9 * fade)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    ctx.stroke(seg, with: .color(.white.opacity(0.85 * fade)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }

            for p in live {
                let q = WorldShapes.project(lat: p.lat, lon: p.lon).applying(t)
                guard q.x > -40, q.y > -40, q.x < size.width + 40, q.y < size.height + 40 else { continue }
                let w = weightOf(p)
                let fade = fadeOf(p)
                let c = colorOf(p)
                let r = 2.5 + 9 * w
                // Aufploppen in den ersten 0,6 s
                let pop = min(1, max(0.2, age(p) / 0.6))
                // Wellenring
                let wave = (time * 0.8 + p.lat * 0.01).truncatingRemainder(dividingBy: 1)
                let rr = r + wave * (14 + 18 * w)
                ctx.stroke(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(c.opacity((1 - wave) * 0.7 * fade)), lineWidth: 1)
                ctx.drawLayer { g in
                    g.addFilter(.blur(radius: 6))
                    let gr = r * 2.2 * pop
                    g.fill(Path(ellipseIn: CGRect(x: q.x - gr, y: q.y - gr, width: gr * 2, height: gr * 2)), with: .color(c.opacity(0.75 * fade)))
                }
                let cr = r * pop
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - cr, y: q.y - cr, width: cr * 2, height: cr * 2)), with: .color(c.opacity(fade)))
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - cr * 0.4, y: q.y - cr * 0.4, width: cr * 0.8, height: cr * 0.8)), with: .color(.white.opacity(fade)))
            }

            // Beschriftung der stärksten Ziele
            if showLabels {
                let n = viewport.zoom > 2 ? 10 : 5
                for p in live.sorted(by: { $0.n > $1.n }).prefix(n) {
                    let q = WorldShapes.project(lat: p.lat, lon: p.lon).applying(t)
                    let name = (p.stadt.isEmpty ? p.landname : p.stadt).uppercased()
                    guard !name.isEmpty else { continue }
                    let txt = Text("\(name) · \(p.n)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Tron.cyan.opacity(0.9 * fadeOf(p)))
                    ctx.draw(txt, at: CGPoint(x: q.x + 10, y: q.y - 9), anchor: .leading)
                }
            }

            // Zuhause: rotierendes Fadenkreuz
            let spin = Angle.degrees(time * 40)
            for (k, rad) in [(0.0, 13.0), (1.0, 19.0)] {
                var a = Path()
                let start = spin.radians * (k == 0 ? 1 : -1.4)
                for s in 0..<3 {
                    let b = start + Double(s) * 2 * .pi / 3
                    a.move(to: CGPoint(x: h.x + rad * cos(b), y: h.y + rad * sin(b)))
                    a.addArc(center: h, radius: rad, startAngle: .radians(b), endAngle: .radians(b + 1.3), clockwise: false)
                }
                ctx.stroke(a, with: .color((inbound ? Tron.cyan : Tron.amber).opacity(0.9)), lineWidth: 1.4)
            }
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 4))
                g.fill(Path(ellipseIn: CGRect(x: h.x - 6, y: h.y - 6, width: 12, height: 12)), with: .color(inbound ? Tron.cyan : Tron.amber))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6)), with: .color(.white))
        }
    }

    private var scanlines: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            var p = Path()
            while y < size.height { p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)); y += 3 }
            ctx.fill(p, with: .color(.black.opacity(0.18)))
        }
    }

    private func weightOf(_ p: WorldTraffic.Place) -> Double { sqrt(Double(p.n) / Double(maxN)) }
    private func colorOf(_ p: WorldTraffic.Place) -> Color {
        let w = weightOf(p)
        if inbound { return w > 0.7 ? Color(red: 1, green: 0.1, blue: 0.2) : (w > 0.35 ? Tron.hot : Tron.amber) }
        return w > 0.7 ? Tron.hot : (w > 0.35 ? Tron.amber : Tron.cyan)
    }
}

private extension CGSize {
    static func * (l: CGSize, r: CGFloat) -> CGSize { CGSize(width: l.width * r, height: l.height * r) }
}

/// Ecken-Klammern wie bei einem HUD
struct HUDFrame: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l: CGFloat = 16
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}
