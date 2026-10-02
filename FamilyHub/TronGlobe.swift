import SwiftUI

// MARK: - 3D-Punkt-Globus (Entwurf B): dreht sich langsam, mit Finger drehen, Bögen zu den Zielen

enum GlobeDots {
    /// Landpunkte (gleichmäßig auf der Kugel verteilt) als (sin φ, cos φ, λ)
    static let points: [(Double, Double, Double)] = {
        guard let url = Bundle.main.url(forResource: "world_dots", withExtension: "bin"),
              let d = try? Data(contentsOf: url), d.count > 4 else { return [] }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let n = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
            var out: [(Double, Double, Double)] = []
            out.reserveCapacity(n)
            var o = 4
            for _ in 0..<n where o + 4 <= raw.count {
                let la = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self))) / 10 * .pi / 180
                let lo = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 2, as: Int16.self))) / 10 * .pi / 180
                out.append((sin(la), cos(la), lo))
                o += 4
            }
            return out
        }
    }()
}

/// Blickrichtung des Globus
struct GlobeCam {
    var lat0: Double = 38
    var lon0: Double = -20
    var zoom: CGFloat = 1
    /// Zeitpunkt der letzten Berührung – danach dreht er sich nach 3 s wieder von selbst
    var touched: Double = 0
    static let spin = 5.0  // Grad pro Sekunde

    func lon(at t: Double) -> Double {
        let idle = t - touched - 3
        return lon0 + (idle > 0 ? idle * GlobeCam.spin : 0)
    }
}

struct TronGlobe: View {
    let places: [WorldTraffic.Place]
    let home: (lat: Double, lon: Double)
    let lifetime: Double
    var stamp: Date = .now
    var showLines = true
    var rotated = false
    var interactive = true
    var inbound = false
    @Binding var cam: GlobeCam

    @State private var base: GlobeCam?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, sz in draw(ctx, sz, t) }
            }
            .contentShape(Rectangle())
            .gesture(rotate(size), including: interactive ? .all : .subviews)
        }
    }

    // MARK: Gesten: ziehen = drehen, zwei Finger = zoomen

    private func rotate(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .simultaneously(with: MagnifyGesture())
            .onChanged { v in
                let now = Date.now.timeIntervalSinceReferenceDate
                if base == nil {
                    var b = cam
                    b.lon0 = cam.lon(at: now)
                    base = b
                }
                guard var c = base else { return }
                c.zoom = min(4, max(0.8, c.zoom * (v.second?.magnification ?? 1)))
                if let d = v.first?.translation {
                    let local = rotated ? CGSize(width: d.height, height: -d.width) : d
                    let r = radius(size) * c.zoom
                    let k = 180 / (.pi * Double(r))
                    c.lon0 -= Double(local.width) * k
                    c.lat0 = min(80, max(-80, c.lat0 + Double(local.height) * k))
                }
                c.touched = now
                cam = c
            }
            .onEnded { _ in
                cam.touched = Date.now.timeIntervalSinceReferenceDate
                base = nil
            }
    }

    private func radius(_ s: CGSize) -> CGFloat { min(s.width, s.height) * 0.44 }

    // MARK: Zeichnen

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let R = radius(sz) * cam.zoom
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let lat0 = cam.lat0 * .pi / 180, lon0 = cam.lon(at: t) * .pi / 180
        let s0 = sin(lat0), c0 = cos(lat0)
        let accent = inbound ? Tron.hot : DotBlue.pillar

        /// Projektion: (x, y, Tiefe) – Tiefe > 0 = Vorderseite
        func proj(_ sl: Double, _ cl: Double, _ lo: Double, alt: Double = 0) -> (CGPoint, Double) {
            let d = lo - lon0
            let cd = cos(d)
            let k = Double(R) * (1 + alt)
            let x = k * cl * sin(d)
            let y = k * (c0 * sl - s0 * cl * cd)
            let z = k * (s0 * sl + c0 * cl * cd)
            return (CGPoint(x: c.x + x, y: c.y - y), z)
        }
        func projLL(_ lat: Double, _ lon: Double, alt: Double = 0) -> (CGPoint, Double) {
            let la = lat * .pi / 180
            return proj(sin(la), cos(la), lon * .pi / 180, alt: alt)
        }

        // Atmosphäre + Kugel
        ctx.drawLayer { g in
            g.addFilter(.blur(radius: R * 0.12))
            g.fill(Path(ellipseIn: CGRect(x: c.x - R * 1.04, y: c.y - R * 1.04, width: R * 2.08, height: R * 2.08)),
                   with: .color(accent.opacity(0.28)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)),
                 with: .radialGradient(Gradient(colors: [Color(red: 0.03, green: 0.08, blue: 0.16), Color(red: 0.01, green: 0.02, blue: 0.05)]),
                                       center: CGPoint(x: c.x - R * 0.3, y: c.y - R * 0.35), startRadius: 0, endRadius: R * 1.3))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)),
                   with: .color(accent.opacity(0.45)), lineWidth: 1)

        // Gradnetz
        var grat = Path()
        for lonG in stride(from: -180.0, to: 180.0, by: 30) {
            var started = false
            for latG in stride(from: -90.0, through: 90.0, by: 4) {
                let (p, z) = projLL(latG, lonG)
                if z > 0 { if started { grat.addLine(to: p) } else { grat.move(to: p); started = true } } else { started = false }
            }
        }
        for latG in stride(from: -60.0, through: 60.0, by: 30) {
            var started = false
            for lonG in stride(from: -180.0, through: 180.0, by: 4) {
                let (p, z) = projLL(latG, lonG)
                if z > 0 { if started { grat.addLine(to: p) } else { grat.move(to: p); started = true } } else { started = false }
            }
        }
        ctx.stroke(grat, with: .color(accent.opacity(0.1)), lineWidth: 0.6)

        // Landpunkte
        let dotR = max(0.7, R / 150)
        var front = Path(), rim = Path()
        for (sl, cl, lo) in GlobeDots.points {
            let (p, z) = proj(sl, cl, lo)
            guard z > 0 else { continue }
            let rect = CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)
            if z > Double(R) * 0.25 { front.addEllipse(in: rect) } else { rim.addEllipse(in: rect) }
        }
        ctx.fill(rim, with: .color(accent.opacity(0.35)))
        ctx.fill(front, with: .color(accent.opacity(0.8)))

        // Bögen und Ziele
        let extra = max(0, t - stamp.timeIntervalSinceReferenceDate)
        let live = places.filter { $0.alter + extra < lifetime }
        let maxN = max(1, live.map(\.n).max() ?? 1)
        let (h, hz) = projLL(home.lat, home.lon)

        for (i, p) in live.prefix(18).enumerated() {
            let fade = max(0, 1 - (p.alter + extra) / lifetime)
            let w = sqrt(Double(p.n) / Double(maxN))
            let col = color(w)
            if showLines {
                // Großkreis Zuhause → Ziel, in der Mitte angehoben
                let a = unit(home.lat, home.lon), b = unit(p.lat, p.lon)
                let ang = acos(max(-1, min(1, a.0 * b.0 + a.1 * b.1 + a.2 * b.2)))
                guard ang > 0.01 else { continue }
                var arc = Path()
                var started = false
                let steps = 36
                for s in 0...steps {
                    let f = Double(s) / Double(steps)
                    let v = slerp(a, b, ang, f)
                    let lat = asin(v.2) * 180 / .pi, lon = atan2(v.1, v.0) * 180 / .pi
                    let (q, z) = projLL(lat, lon, alt: sin(f * .pi) * min(0.35, ang * 0.25))
                    let visible = z > 0 || hypot(q.x - c.x, q.y - c.y) > R
                    if visible { if started { arc.addLine(to: q) } else { arc.move(to: q); started = true } } else { started = false }
                }
                ctx.stroke(arc, with: .color(col.opacity(0.35 * fade)), lineWidth: 1)
                let ph0 = (t * 0.5 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)
                let ph = inbound ? 1 - ph0 : ph0
                let seg = arc.trimmedPath(from: max(0, ph - 0.15), to: min(1, ph + (inbound ? 0.15 : 0)))
                ctx.drawLayer { g in
                    g.addFilter(.blur(radius: 3))
                    g.stroke(seg, with: .color(col.opacity(0.9 * fade)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                ctx.stroke(seg, with: .color(.white.opacity(0.85 * fade)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
            let (q, z) = projLL(p.lat, p.lon)
            guard z > 0 else { continue }
            let r = (2.5 + 7 * w) * Double(max(1, cam.zoom * 0.8))
            let wave = (t * 0.8 + p.lat * 0.01).truncatingRemainder(dividingBy: 1)
            let rr = r + wave * (12 + 14 * w)
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(col.opacity((1 - wave) * 0.7 * fade)), lineWidth: 1)
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 5))
                g.fill(Path(ellipseIn: CGRect(x: q.x - r * 2, y: q.y - r * 2, width: r * 4, height: r * 4)), with: .color(col.opacity(0.7 * fade)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)), with: .color(col.opacity(fade)))
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - r * 0.4, y: q.y - r * 0.4, width: r * 0.8, height: r * 0.8)), with: .color(.white.opacity(fade)))
        }

        // Zuhause
        if hz > 0 {
            let homeCol = inbound ? Tron.cyan : Tron.amber
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: 4))
                g.fill(Path(ellipseIn: CGRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14)), with: .color(homeCol))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6)), with: .color(.white))
            let rr = 10 + 4 * sin(t * 3)
            ctx.stroke(Path(ellipseIn: CGRect(x: h.x - rr, y: h.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(homeCol.opacity(0.8)), lineWidth: 1.4)
        }
    }

    private func color(_ w: Double) -> Color {
        if inbound { return w > 0.7 ? Color(red: 1, green: 0.1, blue: 0.2) : (w > 0.35 ? Tron.hot : Tron.amber) }
        return w > 0.6 ? DotBlue.hot : DotBlue.pillar
    }

    private func unit(_ lat: Double, _ lon: Double) -> (Double, Double, Double) {
        let la = lat * .pi / 180, lo = lon * .pi / 180
        return (cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
    }

    private func slerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ ang: Double, _ f: Double) -> (Double, Double, Double) {
        let s = sin(ang)
        let ka = sin((1 - f) * ang) / s, kb = sin(f * ang) / s
        return (a.0 * ka + b.0 * kb, a.1 * ka + b.1 * kb, a.2 * ka + b.2 * kb)
    }
}

/// Darstellung der Weltkarte (wird gemerkt): A Punktmatrix, B Globus, Neon-Linien
enum WorldStyle: String {
    case karte, globus, neon
    static func next(_ raw: String) -> String {
        switch WorldStyle(rawValue: raw) ?? .karte {
        case .karte: return WorldStyle.globus.rawValue
        case .globus: return WorldStyle.neon.rawValue
        case .neon: return WorldStyle.karte.rawValue
        }
    }
    /// Symbol für den Knopf = der Stil, zu dem er wechselt
    static func nextIcon(_ raw: String) -> String {
        switch WorldStyle(rawValue: next(raw)) ?? .karte {
        case .karte: return "circle.grid.3x3.fill"
        case .globus: return "globe.europe.africa"
        case .neon: return "map"
        }
    }
    static func nextLabel(_ raw: String) -> String {
        switch WorldStyle(rawValue: next(raw)) ?? .karte {
        case .karte: return "Als Punktkarte zeigen"
        case .globus: return "Als Globus zeigen"
        case .neon: return "Als Neon-Karte zeigen"
        }
    }
}

enum DotBlue {
    static let dot = Color(red: 0.23, green: 0.48, blue: 1.0)
    static let pillar = Color(red: 0.44, green: 0.66, blue: 1.0)
    static let hot = Color(red: 1.0, green: 0.48, blue: 0.85)
    static let bg = Color(red: 0.016, green: 0.024, blue: 0.06)
}
