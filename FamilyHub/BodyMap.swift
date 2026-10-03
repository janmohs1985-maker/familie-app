import SwiftUI

// MARK: - Körperfigur (vorne/hinten) mit eingefärbten Muskeln
//
// Gleiche Zeichnung wie in den Entwürfen: linke Körperhälfte als Pfade, rechts gespiegelt (Mitte x = 64).

enum Muscle: String, CaseIterable {
    case traps, delts, chest, biceps, triceps, forearms, abs, obliques, lats, lowerback, glutes, quads, hamstrings, calves

    var title: String {
        switch self {
        case .traps: "Nacken"
        case .delts: "Schultern"
        case .chest: "Brust"
        case .biceps: "Bizeps"
        case .triceps: "Trizeps"
        case .forearms: "Unterarme"
        case .abs: "Bauch"
        case .obliques: "Seitl. Bauch"
        case .lats: "Breiter Rücken"
        case .lowerback: "Unterer Rücken"
        case .glutes: "Po"
        case .quads: "Oberschenkel"
        case .hamstrings: "Beinbeuger"
        case .calves: "Waden"
        }
    }

    /// grobe Gruppen für die Liste unter der Figur
    var group: String {
        switch self {
        case .quads, .hamstrings, .glutes, .calves: "Beine & Po"
        case .lats, .traps, .lowerback: "Rücken"
        case .chest: "Brust"
        case .abs, .obliques: "Bauch & Rumpf"
        case .delts, .biceps, .triceps, .forearms: "Arme & Schultern"
        }
    }
}

struct BodyMapView: View {
    let load: [Muscle: Double]
    var showLabels = true
    var only: Side? = nil
    @Environment(\.colorScheme) private var scheme

    enum Side { case front, back }

    var body: some View {
        let dark = scheme == .dark
        let base = dark ? Color(red: 0.23, green: 0.23, blue: 0.26) : Color(red: 0.83, green: 0.83, blue: 0.855)
        let line = dark ? Color(red: 0.08, green: 0.08, blue: 0.095) : Color.white
        VStack(spacing: 2) {
            Canvas { ctx, size in
                let figs: [(BodyShapes.Figure, CGFloat)] = switch only {
                case .front: [(BodyShapes.front, 0)]
                case .back: [(BodyShapes.back, 0)]
                case nil: [(BodyShapes.front, 0), (BodyShapes.back, 152)]
                }
                let vbW: CGFloat = only == nil ? 280 : 128
                let vbH: CGFloat = only == nil ? 276 : 264
                let s = min(size.width / vbW, size.height / vbH)
                let ox = (size.width - vbW * s) / 2
                for (fig, dx) in figs {
                    var c = ctx
                    c.translateBy(x: ox + dx * s, y: 4 * s)
                    c.scaleBy(x: s, y: s)
                    for pass in 0..<2 {
                        for (m, path) in fig.center { draw(&c, path, m, pass, base, line) }
                        for (m, path) in fig.side { draw(&c, path, m, pass, base, line) }
                        var mirror = c
                        mirror.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 128, ty: 0))
                        for (m, path) in fig.side { draw(&mirror, path, m, pass, base, line) }
                    }
                }
            }
            .aspectRatio(only == nil ? 280 / 276 : 128 / 264, contentMode: .fit)
            if showLabels && only == nil {
                HStack {
                    Text("vorne").frame(maxWidth: .infinity)
                    Text("hinten").frame(maxWidth: .infinity)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Körper mit trainierten Muskeln: " + load.filter { $0.value > 0.3 }.keys.map(\.title).joined(separator: ", "))
    }

    private func draw(_ c: inout GraphicsContext, _ p: Path, _ m: Muscle?, _ pass: Int, _ base: Color, _ line: Color) {
        if pass == 0 {
            c.fill(p, with: .color(base))
            c.stroke(p, with: .color(base), style: StrokeStyle(lineWidth: 3.2, lineJoin: .round))
        } else {
            c.fill(p, with: .color(m.map { Self.heat(load[$0] ?? 0, base: base) } ?? base))
            c.stroke(p, with: .color(line), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
        }
    }

    /// hell-orange → orange → rot
    static func heat(_ v: Double, base: Color) -> Color {
        guard v > 0.02 else { return base }
        let a: [Double] = [255, 196, 140], b: [Double] = [255, 122, 26], c: [Double] = [232, 58, 28]
        let t = min(1, v)
        let m = t < 0.5 ? zip(a, b).map { $0 + ($1 - $0) * t * 2 } : zip(b, c).map { $0 + ($1 - $0) * (t - 0.5) * 2 }
        return Color(red: m[0] / 255, green: m[1] / 255, blue: m[2] / 255)
    }
}

// MARK: Formen

enum BodyShapes {
    struct Figure {
        let side: [(Muscle?, Path)]
        let center: [(Muscle?, Path)]
    }

    static let front = Figure(side: [
        (.traps, svg("M57 38C54 42 48 45 43 47L55 50Z")),
        (.delts, svg("M43 47C35 47 29 53 28 62C28 68 29 72 31 75C34 67 38 60 45 56C46 52 45 49 43 47Z")),
        (.chest, svg("M46 52C53 49 60 50 63.4 52L63.4 71C58 75 50 75 44 71C40 66 40 58 46 52Z")),
        (.biceps, svg("M31 77C28 83 27 92 28 99C30 103 34 103 36 99C38 91 38 82 36 74Z")),
        (.forearms, svg("M28 103C25 111 23 121 21 133C22 137 26 137 28 133C32 123 34 113 35 104Z")),
        (nil, ell(21, 143, 4, 7)),
        (.abs, svg("M55.5 75H63.4V85H55.5Z")), (.abs, svg("M55.5 87H63.4V97H55.5Z")), (.abs, svg("M55.5 99H63.4V109H55.5Z")),
        (.abs, svg("M55.5 111H63.4V124C59 124 56 120 55.5 114Z")),
        (.obliques, svg("M44 75C48 77 51 79 53.5 81L53.5 111C50 115 46 113 45 107C44 97 43 85 44 75Z")),
        (nil, svg("M45 114C50 120 57 125 63.4 127L63.4 133L48 129Z")),
        (.quads, svg("M44 124C40 136 38 154 40 170C42 182 46 189 51 191C55 187 58 177 59 165C60 150 58 136 55 127C51 127 47 126 44 124Z")),
        (nil, svg("M57 129C61 133 63.4 141 63 151C61 157 59 153 58 147Z")),
        (nil, ell(50, 197, 6, 6)),
        (.calves, svg("M44 205C42 217 43 233 46 244C48 248 52 248 54 244C56 233 57 217 55 205Z")),
        (nil, svg("M44 249L55 249L57 257L42 257Z"))
    ], center: [
        (nil, ell(64, 20, 12, 15)),
        (nil, svg("M58 33H70V43H58Z"))
    ])

    static let back = Figure(side: [
        (.delts, svg("M43 47C35 47 29 53 28 62C28 68 29 72 31 75C34 67 38 60 45 56C46 52 45 49 43 47Z")),
        (.lats, svg("M45 58C51 62 56 68 58 75L60 99C54 103 48 101 45 95C42 83 42 70 45 58Z")),
        (.triceps, svg("M31 77C28 83 27 92 28 99C30 103 34 103 36 99C38 91 38 82 36 74Z")),
        (.forearms, svg("M28 103C25 111 23 121 21 133C22 137 26 137 28 133C32 123 34 113 35 104Z")),
        (nil, ell(21, 143, 4, 7)),
        (.glutes, svg("M47 113C54 111 61 113 63.4 117L63.4 136C58 142 50 142 46 136C43 128 44 119 47 113Z")),
        (.hamstrings, svg("M46 141C44 153 44 169 47 185C50 191 56 191 58 185C61 171 61 153 60 143C56 145 50 145 46 141Z")),
        (nil, ell(52, 197, 6, 5)),
        (.calves, svg("M45 203C41 213 41 228 46 238C49 242 53 242 55 238C58 228 58 213 55 203Z")),
        (nil, svg("M46 243L55 243L57 257L43 257Z"))
    ], center: [
        (nil, ell(64, 20, 12, 15)),
        (nil, svg("M58 33H70V43H58Z")),
        (.traps, svg("M64 36C58 40 50 44 42 48C48 52 54 58 58 70L64 86L70 70C74 58 80 52 86 48C78 44 70 40 64 36Z")),
        (.lowerback, svg("M59 90L69 90L71 111C68 115 60 115 57 111Z"))
    ])

    static func ell(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    /// Mini-Leser für SVG-Pfade (nur M, L, H, V, C, Z – absolut)
    static func svg(_ d: String) -> Path {
        var p = Path()
        var nums: [CGFloat] = []
        var cmd: Character = "M"
        var cur = CGPoint.zero
        func flush() {
            switch cmd {
            case "M":
                var i = 0
                while i + 1 < nums.count {
                    cur = CGPoint(x: nums[i], y: nums[i + 1])
                    if i == 0 { p.move(to: cur) } else { p.addLine(to: cur) }
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < nums.count { cur = CGPoint(x: nums[i], y: nums[i + 1]); p.addLine(to: cur); i += 2 }
            case "H":
                for x in nums { cur = CGPoint(x: x, y: cur.y); p.addLine(to: cur) }
            case "V":
                for y in nums { cur = CGPoint(x: cur.x, y: y); p.addLine(to: cur) }
            case "C":
                var i = 0
                while i + 5 < nums.count {
                    cur = CGPoint(x: nums[i + 4], y: nums[i + 5])
                    p.addCurve(to: cur, control1: CGPoint(x: nums[i], y: nums[i + 1]), control2: CGPoint(x: nums[i + 2], y: nums[i + 3]))
                    i += 6
                }
            case "Z":
                p.closeSubpath()
            default: break
            }
            nums = []
        }
        var token = ""
        func endToken() {
            if let v = Double(token) { nums.append(CGFloat(v)) }
            token = ""
        }
        for ch in d {
            if ch.isLetter {
                endToken(); flush(); cmd = ch
                if ch == "Z" { flush() }
            } else if ch == " " || ch == "," {
                endToken()
            } else if ch == "-" && !token.isEmpty {
                endToken(); token = "-"
            } else {
                token.append(ch)
            }
        }
        endToken(); flush()
        return p
    }
}
