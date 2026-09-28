import SwiftUI

// MARK: - Neue App-Version
//
// Family Hub (Home Assistant) holt jede neue Version von GitHub und stellt sie
// unter einem geheimen Link bereit. Die App fragt über das Skript
// „familie_app_version“ nach, ob es eine neuere Build-Nummer gibt, und bietet
// dann „Jetzt aktualisieren“ an (Installation direkt über iOS).

struct AppVersionInfo: Equatable {
    let version: String
    let build: Int
    let installURL: URL?
    let pageURL: URL?

    static var current: (version: String, build: Int) {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Int(info["CFBundleVersion"] as? String ?? "1") ?? 1
        return (v, b)
    }

    var isNewer: Bool { build > Self.current.build && installURL != nil }
}

enum AppUpdate {
    static let script = "familie_app_version"

    @MainActor
    static func check(_ store: AppStore) async -> AppVersionInfo? {
        guard let r = try? await store.client.callWithResponse("script", script, [:], timeout: 30) else { return nil }
        let c = r["content"] ?? r
        guard let build = c["build"]?.int else { return nil }
        let signed = c["signed"]?.string == "true"
        return AppVersionInfo(
            version: c["version"]?.string ?? "?",
            build: build,
            installURL: signed ? c["install_url"]?.string.flatMap(URL.init(string:)) : nil,
            pageURL: c["page_url"]?.string.flatMap(URL.init(string:))
        )
    }
}

/// Kleiner Hinweis oben auf „Heute“ – erscheint nur, wenn es eine neuere Version gibt.
struct AppUpdateBanner: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var info: AppVersionInfo?
    @AppStorage("updateBannerHiddenBuild") private var hiddenBuild = 0

    var body: some View {
        Group {
            if let info, info.isNewer, hiddenBuild != info.build, let url = info.installURL {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neue Version verfügbar").font(.subheadline.weight(.semibold))
                        Text("Version \(info.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Laden") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    Button { hiddenBuild = info.build } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .task { info = await AppUpdate.check(store) }
    }
}

/// Abschnitt in den Einstellungen: installierte Version + Aktualisieren
struct AppVersionSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var info: AppVersionInfo?
    @State private var checking = false

    var body: some View {
        let cur = AppVersionInfo.current
        Section {
            LabeledContent("Installiert", value: "\(cur.version) (\(cur.build))")
            if let info {
                LabeledContent("Neueste", value: "\(info.version) (\(info.build))")
                if info.isNewer, let url = info.installURL {
                    Button { openURL(url) } label: {
                        Label("Jetzt aktualisieren", systemImage: "arrow.down.app.fill")
                    }
                }
            }
            Button {
                Task { checking = true; info = await AppUpdate.check(store); checking = false }
            } label: {
                HStack {
                    Label("Nach Update suchen", systemImage: "arrow.clockwise")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .disabled(checking)
        } header: { Text("App") } footer: {
            if let info, !info.isNewer, info.build <= cur.build { Text("Die App ist aktuell.") }
        }
        .task { info = await AppUpdate.check(store) }
    }
}
