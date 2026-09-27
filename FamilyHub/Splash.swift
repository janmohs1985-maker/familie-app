import SwiftUI

// MARK: - Profilbilder auf dem Gerät zwischenspeichern (für die Startanimation ohne Wartezeit)

enum AvatarCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("avatars")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ person: String) -> URL { dir.appendingPathComponent(person + ".png") }

    static func save(_ image: UIImage, for person: String) {
        let small = image.scaled(maxSide: 300)
        if let data = small.pngData() { try? data.write(to: file(person), options: .atomic) }
    }

    static func loadAll() -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for p in FamilyConfig.people {
            if let data = try? Data(contentsOf: file(p.id)), let img = UIImage(data: data) { out[p.id] = img }
        }
        return out
    }
}

// MARK: - Startanimation

struct SplashView: View {
    let pictures: [String: UIImage]
    let name: String?
    let onFinish: () -> Void

    @State private var gathered = false
    @State private var heart = false
    @State private var title = false
    @State private var leaving = false

    // Startpunkte außerhalb des Bildschirms (Ecken) und Zielpunkte im Kreis um die Mitte
    private let starts: [CGSize] = [CGSize(width: -260, height: -420), CGSize(width: 260, height: -420),
                                    CGSize(width: -260, height: 420), CGSize(width: 260, height: 420)]
    private let targets: [CGSize] = [CGSize(width: -62, height: -62), CGSize(width: 62, height: -62),
                                     CGSize(width: -62, height: 62), CGSize(width: 62, height: 62)]

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let base: String
        switch h {
        case 5..<11: base = "Guten Morgen"
        case 11..<17: base = "Hallo"
        case 17..<22: base = "Guten Abend"
        default: base = "Gute Nacht"
        }
        return name.map { "\(base), \($0)!" } ?? "\(base)!"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.indigo, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            // weiche Lichtkreise im Hintergrund
            Circle().fill(.white.opacity(0.08)).frame(width: 420).offset(x: -140, y: -260)
                .scaleEffect(gathered ? 1 : 0.6)
            Circle().fill(.white.opacity(0.06)).frame(width: 360).offset(x: 160, y: 300)
                .scaleEffect(gathered ? 1 : 0.6)

            VStack(spacing: 36) {
                ZStack {
                    // Haus mit Herz in der Mitte
                    ZStack {
                        Image(systemName: "house.fill")
                            .font(.system(size: 58))
                            .foregroundStyle(.white)
                        Image(systemName: "heart.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.pink)
                            .offset(y: 9)
                    }
                    .scaleEffect(heart ? 1 : 0.1)
                    .opacity(heart ? 1 : 0)

                    ForEach(Array(FamilyConfig.people.prefix(4).enumerated()), id: \.offset) { i, p in
                        Avatar(image: pictures[p.id], name: p.name, color: p.color)
                            .frame(width: 84, height: 84)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                            .offset(gathered ? targets[i] : starts[i])
                            .rotationEffect(.degrees(gathered ? 0 : (i.isMultiple(of: 2) ? -40 : 40)))
                            .scaleEffect(gathered ? 1 : 0.4)
                            .animation(.spring(response: 0.7, dampingFraction: 0.68).delay(Double(i) * 0.09), value: gathered)
                    }
                }
                .frame(width: 260, height: 260)

                VStack(spacing: 6) {
                    Text("Familie Mohs")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(greeting)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .opacity(title ? 1 : 0)
                .offset(y: title ? 0 : 16)
            }
            .scaleEffect(leaving ? 1.35 : 1)
        }
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            gathered = true
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { heart = true }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeOut(duration: 0.45)) { title = true }
            try? await Task.sleep(for: .milliseconds(1200))
            finish()
        }
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.35)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(360))
            onFinish()
        }
    }
}
