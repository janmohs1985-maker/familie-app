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
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, p in
            // beim Zurückkehren in die App erneut nachsehen
            if p == .active { Task { info = await AppUpdate.check(store) } }
        }
    }
}

// MARK: - Builds in der Pipeline (GitHub Actions, nur Jan)

struct BuildRun: Identifiable, Decodable {
    let id: Int
    let display_title: String
    let status: String              // queued, in_progress, completed
    let conclusion: String?         // success, failure, cancelled …
    let run_started_at: String?
    let updated_at: String?
    let html_url: String

    /// „Update 168: …“ → 168
    var update: Int? {
        guard let m = display_title.firstMatch(of: #/Update (\d+)/#) else { return nil }
        return Int(m.1)
    }
    var text: String {
        display_title.replacingOccurrences(of: #"^Update \d+:\s*"#, with: "", options: .regularExpression)
    }
    var started: Date? { HADate.parse(run_started_at) }
    var finished: Date? { status == "completed" ? HADate.parse(updated_at) : nil }
}

enum BuildPipeline {
    static let repo = "janmohs1985-maker/familie-app"

    static func load() async throws -> [BuildRun] {
        struct Wrap: Decodable { let workflow_runs: [BuildRun] }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/actions/runs?per_page=6")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FamilieApp", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 || code == 429 { throw URLError(.resourceUnavailable) }
        return try JSONDecoder().decode(Wrap.self, from: data).workflow_runs
    }
}

struct BuildsSection: View {
    @Environment(\.openURL) private var openURL
    @State private var runs: [BuildRun] = []
    @State private var error: String?
    @State private var loading = false

    private var installed: Int? { Int(AppVersionInfo.current.version.split(separator: ".").last ?? "") }

    var body: some View {
        Section {
            if runs.isEmpty && loading { HStack { ProgressView(); Text("Lade …").foregroundStyle(.secondary) } }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(spacing: 0) {
                    ForEach(runs.prefix(5)) { r in
                        row(r, now: ctx.date)
                        if r.id != runs.prefix(5).last?.id { Divider().padding(.leading, 40) }
                    }
                }
            }
            Button {
                if let u = URL(string: "itms-beta://") { openURL(u) }
            } label: {
                Label("TestFlight öffnen", systemImage: "airplane")
            }
        } header: {
            HStack {
                Text("Builds")
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
        } footer: {
            Text("Live von GitHub. „Fertig“ heißt: in TestFlight verfügbar (manchmal braucht Apple danach noch ein paar Minuten).")
        }
        .task {
            // aktualisiert sich jede Minute, solange die Einstellungen offen sind
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(runs.contains { $0.status != "completed" } ? 60 : 180))
            }
        }
    }

    private func reload() async {
        loading = true
        do {
            runs = try await BuildPipeline.load()
            error = nil
        } catch {
            self.error = "GitHub gerade nicht erreichbar."
        }
        loading = false
    }

    private func row(_ r: BuildRun, now: Date) -> some View {
        let (symbol, color, state): (String, Color, String) = {
            switch (r.status, r.conclusion) {
            case ("queued", _), ("waiting", _), ("pending", _): return ("clock.fill", .gray, "wartet")
            case ("in_progress", _):
                let m = r.started.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
                return ("hammer.fill", .orange, "baut · \(m) Min")
            case (_, .some("success")): return ("checkmark.circle.fill", .green, "fertig")
            case (_, .some("cancelled")): return ("minus.circle.fill", .gray, "abgebrochen")
            default: return ("xmark.octagon.fill", .red, "Fehler")
            }
        }()
        let isInstalled = r.update != nil && r.update == installed
        return Button {
            if let u = URL(string: r.html_url) { openURL(u) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).font(.title3)
                    .symbolEffect(.pulse, isActive: r.status == "in_progress")
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.update.map { "Update \($0)" } ?? "Build").font(.subheadline.weight(.bold))
                        if isInstalled {
                            Text("installiert").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor, in: Capsule())
                        }
                    }
                    Text(r.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state).font(.caption.weight(.bold)).foregroundStyle(color)
                    if let f = r.finished {
                        Text(f.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
