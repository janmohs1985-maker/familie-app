import SwiftUI
import AVKit

// MARK: - Kameras: Übersicht (A), Kamera mit Zeitleiste (B), Ereignisse (C),
// PTZ (E), Clip (F), Einstellungen (G). Entwürfe: Design-Fläche „Frigate Kameras – Entwürfe“.

// MARK: Bausteine

/// Schrift-Chip auf dem Kamerabild (dunkles Milchglas)
private struct VideoChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    fileprivate func videoChip() -> some View { modifier(VideoChip()) }
}

/// Standbild einer Kamera, das sich regelmäßig erneuert
struct CamSnapshot: View {
    let cam: FCam
    var interval: Double = 6
    @State private var tick = Int(Date().timeIntervalSince1970)

    var body: some View {
        HAImage(path: "/api/camera_proxy/\(cam.entityID)?t=\(tick)")
            .task(id: cam.entityID) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    tick = Int(Date().timeIntervalSince1970 * 10)
                }
            }
    }
}

/// AVPlayer ohne Bedienelemente (Live-Bild und Aufnahmen)
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
    }
}

/// Kachel einer Kamera: Bild, Name, Live-Punkt, letztes Ereignis
struct CamTile: View {
    @Environment(AppStore.self) private var store
    let cam: FCam
    var big = false
    private var fm: FrigateModel { .shared }

    var body: some View {
        let last = fm.events(of: cam).first
        let online = fm.isOnline(cam, store)
        Color.clear
            .aspectRatio(big ? 16 / 9 : 16 / 10, contentMode: .fit)
            .overlay { CamSnapshot(cam: cam, interval: big ? 3 : 8) }
            .overlay(alignment: .topLeading) {
                Text(cam.name).videoChip().padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if online {
                    if big { Text("LIVE").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 7)).padding(10)
                    } else { Circle().fill(Color.red).frame(width: 8, height: 8).padding(11) }
                } else {
                    Text("offline").videoChip().padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let last {
                    HStack(spacing: 6) {
                        Circle().fill(FLabel.color(last.label)).frame(width: 7, height: 7)
                        Text("\(FLabel.name(last.label)) · \(FFmt.ago(last.start))")
                        if big { Spacer(minLength: 0); Text("Zeitleiste ›").opacity(0.8) }
                    }
                    .videoChip()
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: big ? DS.cardRadius : DS.tileRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: big ? DS.cardRadius : DS.tileRadius, style: .continuous))
    }
}

/// Vorschaubild eines Ereignisses mit Farbpunkt
struct EventThumb: View {
    let ev: FEvent
    var body: some View {
        Color.clear
            .overlay { HAImage(path: ev.thumbPath) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor private func setSwitch(_ store: AppStore, _ id: String, _ on: Bool) async {
    UISelectionFeedbackGenerator().selectionChanged()
    do {
        try await store.client.call("switch", on ? "turn_on" : "turn_off", ["entity_id": id])
        try? await Task.sleep(for: .milliseconds(600))
        await store.refreshStates()
    } catch { store.report(error) }
}

// MARK: - Karte auf der Technik-Seite

struct CameraPreviewCard: View {
    @Environment(AppStore.self) private var store
    private var fm: FrigateModel { .shared }

    var body: some View {
        let cams = Array(fm.cameras.prefix(4))
        let online = fm.cameras.filter { fm.isOnline($0, store) }.count
        let new = fm.newEvents.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill").font(.headline).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kameras").font(.headline)
                    Text(fm.cameras.isEmpty ? "Frigate" : (online == fm.cameras.count ? "\(fm.cameras.count) Kameras · alle online" : "\(online) von \(fm.cameras.count) online"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if new > 0 {
                    Text("\(new) neu").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.red, in: Capsule())
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if !cams.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(cams) { c in
                        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { CamSnapshot(cam: c, interval: 15) }
                            .overlay(alignment: .bottomLeading) { Text(c.name).videoChip().padding(6) }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            if let ev = fm.events.first {
                HStack(spacing: 8) {
                    Circle().fill(FLabel.color(ev.label)).frame(width: 8, height: 8)
                    Text("\(FLabel.name(ev.label)) · \(fm.cameraName(ev))").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(FFmt.ago(ev.start)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .glassSurface()
        .task { await fm.load(store) }
    }
}

// MARK: - A · Übersicht

struct CamerasView: View {
    @Environment(AppStore.self) private var store
    private var fm: FrigateModel { .shared }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let hero = heroCamera
        ScrollView {
            VStack(spacing: 14) {
                stats
                if let err = fm.error, fm.cameras.isEmpty {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding().cardSurface()
                }
                if fm.loadedOnce && fm.cameras.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Keine Frigate-Kameras gefunden").font(.headline)
                        Text("Die Frigate-Integration in Home Assistant muss eingerichtet sein.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(24).cardSurface()
                } else if !fm.loadedOnce && fm.cameras.isEmpty {
                    ProgressView().padding(40)
                }
                if let hero {
                    NavigationLink { CameraDetailView(cam: hero) } label: { CamTile(cam: hero, big: true) }
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(fm.cameras.filter { $0.id != hero?.id }) { c in
                        NavigationLink { CameraDetailView(cam: c) } label: { CamTile(cam: c) }
                    }
                }
                if !fm.events.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Neueste Ereignisse").font(.title3.weight(.bold))
                        Spacer()
                        NavigationLink("Alle") { EventsFeedView() }.font(.subheadline)
                    }
                    .padding(.top, 4)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(fm.events.prefix(12)) { ev in
                                NavigationLink { EventClipView(ev: ev) } label: { eventCard(ev) }
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 4)
                    }
                    .padding(.horizontal, -16)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .buttonStyle(.plain)
        .background(AppBackground())
        .navigationTitle("Kameras")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { CameraSettingsView(selected: fm.cameras.first?.id) } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .refreshable { await fm.load(store, force: true) }
        .task {
            while !Task.isCancelled {
                await fm.load(store)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Die Kamera mit der jüngsten Bewegung (letzte 15 Min.) groß, sonst die erste
    private var heroCamera: FCam? {
        if let ev = fm.events.first, Date().timeIntervalSince(ev.start) < 900, let c = fm.camera(for: ev) { return c }
        return fm.cameras.first
    }

    private var stats: some View {
        let online = fm.cameras.filter { fm.isOnline($0, store) }.count
        return HStack(spacing: 0) {
            stat("\(online)", "online", online == fm.cameras.count ? Color.green : .orange)
            stat("\(fm.newEvents.count)", "neu", .indigo)
            stat("\(fm.todayCount)", "heute", .primary)
        }
        .padding(.vertical, 12)
        .glassSurface()
    }

    private func stat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.weight(.bold)).foregroundStyle(c).monospacedDigit()
            Text(l).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func eventCard(_ ev: FEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 150, height: 84)
                .overlay { HAImage(path: ev.thumbPath) }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(FLabel.color(ev.label)).frame(width: 8, height: 8)
                    Text(FLabel.name(ev.label)).font(.subheadline.weight(.bold))
                    if ev.start > fm.seenUntil {
                        Text("NEU").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1).background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("\(fm.cameraName(ev)) · \(FFmt.time(ev.start))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 150, alignment: .leading)
        .cardSurface(radius: DS.tileRadius)
        .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
    }
}

// MARK: - B · Kamera mit Zeitleiste (+ E · PTZ)

struct CameraDetailView: View {
    @Environment(AppStore.self) private var store
    @State var cam: FCam
    var startAt: Date? = nil
    private var fm: FrigateModel { .shared }

    @State private var player = AVPlayer()
    @State private var live = true
    @State private var liveFailed = false
    @State private var playbackFailed = false
    @State private var center = Date()
    @State private var vodStart: Date?
    @State private var playing = true
    @State private var speed: Float = 1
    @State private var scrubbing = false
    @State private var filter: String?
    @State private var ptz: FrigateModel.PTZInfo?
    @State private var fullscreen = false
    @State private var showSettings = false
    @AppStorage("frigatePTZManual") private var ptzManual = ""

    private var showPTZ: Bool { ptz != nil || cam.hasAutotracker || ptzManual.split(separator: ",").contains(Substring(cam.id)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                video
                camStrip
                timelinePanel
                controls
                if showPTZ { PTZPanel(cam: cam, info: ptz) }
                eventList
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle(cam.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showSettings = true } label: { Label("Einstellungen", systemImage: "slider.horizontal.3") }
                    if ptz == nil && !cam.hasAutotracker {
                        Button { togglePTZManual() } label: {
                            Label(showPTZ ? "Steuerung ausblenden" : "Steuerung (PTZ) zeigen", systemImage: "move.3d")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .navigationDestination(isPresented: $showSettings) { CameraSettingsView(selected: cam.id) }
        .fullScreenCover(isPresented: $fullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                PlayerLayerView(player: player, gravity: .resizeAspect).ignoresSafeArea()
                Button { fullscreen = false } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                }
                .environment(\.colorScheme, .dark)
                .padding()
            }
        }
        .task(id: cam.id) {
            ptz = await fm.ptzInfo(store, cam)
            if let startAt { await seek(startAt) } else { await goLive() }
        }
        .task {
            // Uhr der Zeitleiste mitlaufen lassen
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !scrubbing else { continue }
                if live { center = Date() }
                else if let s = vodStart {
                    let t = player.currentTime().seconds
                    if t.isFinite { center = s.addingTimeInterval(t) }
                    if player.currentItem?.status == .failed { playbackFailed = true }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await fm.load(store)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: center) { _, d in
            if scrubbing { Task { await fm.ensureDay(store, d) } }
        }
        .onDisappear { player.pause() }
    }

    // MARK: Video

    private var video: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if live && liveFailed { CamSnapshot(cam: cam, interval: 1) }
                else { PlayerLayerView(player: player) }
            }
            .overlay {
                if playbackFailed && !live {
                    Text("Für diese Zeit gibt es keine Aufnahme").videoChip()
                }
            }
            .overlay(alignment: .topLeading) {
                if live {
                    Text("LIVE").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 7)).padding(10)
                } else {
                    Text("\(FFmt.day(center)) \(center.formatted(.dateTime.hour().minute().second()))").videoChip().padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { fullscreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.footnote.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                }
                .environment(\.colorScheme, .dark)
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private var camStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(fm.cameras) { c in
                    Button {
                        guard c.id != cam.id else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        cam = c
                    } label: {
                        Color.clear.frame(width: 70, height: 42)
                            .overlay { CamSnapshot(cam: c, interval: 20) }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(c.id == cam.id ? Color.indigo : Color.white.opacity(0.6), lineWidth: c.id == cam.id ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.name)
                }
            }
            .padding(.horizontal).padding(.vertical, 2)
        }
        .padding(.horizontal, -16)
    }

    // MARK: Zeitleiste

    private var timelinePanel: some View {
        VStack(spacing: 8) {
            HStack {
                Button { Task { await seek(center.addingTimeInterval(-3600)) } } label: {
                    Image(systemName: "chevron.left").font(.headline).frame(width: 36, height: 32)
                }
                .accessibilityLabel("Eine Stunde zurück")
                Spacer()
                Text(FFmt.day(center)).font(.subheadline.weight(.bold))
                Spacer()
                if live {
                    Button { Task { await seek(center.addingTimeInterval(3600)) } } label: {
                        Image(systemName: "chevron.right").font(.headline).frame(width: 36, height: 32)
                    }
                    .disabled(true).opacity(0.3)
                } else {
                    Button { Task { await goLive() } } label: {
                        Text("LIVE ›").font(.caption.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.red, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 10)
            FrigateTimeline(center: $center, scrubbing: $scrubbing, events: fm.events(of: cam)) { t in
                Task { await seek(t) }
            }
        }
        .padding(.vertical, 10)
        .glassSurface()
    }

    private var controls: some View {
        HStack(spacing: 20) {
            roundButton("gobackward.10", "10 Sekunden zurück") { Task { await seek(center.addingTimeInterval(-10)) } }
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                if live { Task { await seek(Date().addingTimeInterval(-5)) }; return }
                playing.toggle()
                if playing { player.playImmediately(atRate: speed) } else { player.pause() }
            } label: {
                Image(systemName: live || !playing ? "play.fill" : "pause.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.indigo, in: Circle())
                    .shadow(color: .indigo.opacity(0.35), radius: 8, y: 4)
            }
            .accessibilityLabel(live || !playing ? "Abspielen" : "Pause")
            roundButton("goforward.10", "10 Sekunden vor") { Task { await seek(center.addingTimeInterval(10)) } }
            Button {
                speed = speed >= 8 ? 1 : speed * 2
                if !live && playing { player.rate = speed }
            } label: {
                Text("\(Int(speed))×").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    .frame(width: 46, height: 34)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.6)))
            }
            .accessibilityLabel("Geschwindigkeit")
        }
        .buttonStyle(.plain)
    }

    private func roundButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6)))
        }
        .accessibilityLabel(label)
    }

    // MARK: Ereignisse dieser Kamera

    private var eventList: some View {
        let all = fm.events(of: cam).filter { Calendar.current.isDate($0.start, inSameDayAs: center) }
        let groups = FLabel.groups.filter { g in all.contains { g.labels.contains($0.label) } }
        var shown = all
        if let k = filter, let g = FLabel.groups.first(where: { $0.key == k }) {
            shown = all.filter { g.labels.contains($0.label) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            if groups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "Alle", on: filter == nil) { filter = nil }
                        ForEach(groups) { g in
                            FilterChip(title: g.title, on: filter == g.key) { filter = filter == g.key ? nil : g.key }
                        }
                    }
                }
            }
            if shown.isEmpty {
                Text(Calendar.current.isDateInToday(center) ? "Heute noch nichts erkannt." : "An diesem Tag nichts erkannt.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding().cardSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { ev in
                        HStack(spacing: 12) {
                            Button { Task { await seek(ev.start.addingTimeInterval(-2)) } } label: {
                                HStack(spacing: 12) {
                                    EventThumb(ev: ev).frame(width: 80, height: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(FLabel.name(ev.label) + (ev.zones.first.map { " · \($0.replacingOccurrences(of: "_", with: " ").capitalized)" } ?? ""))
                                            .font(.subheadline.weight(.bold))
                                        Text("\(FFmt.time(ev.start)) · \(FFmt.duration(ev.duration))").font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            NavigationLink { EventClipView(ev: ev) } label: {
                                Image(systemName: "play.rectangle.fill").font(.title3).foregroundStyle(.indigo)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Clip ansehen")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        if ev.id != shown.last?.id { Divider().padding(.leading, 106) }
                    }
                }
                .cardSurface()
            }
        }
    }

    // MARK: Abspielen

    private func goLive() async {
        live = true
        playbackFailed = false
        vodStart = nil
        center = Date()
        player.pause()
        if let url = await fm.liveURL(store, cam) {
            liveFailed = false
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.isMuted = true
            player.playImmediately(atRate: 1)
            playing = true
        } else {
            liveFailed = true
            player.replaceCurrentItem(with: nil)
        }
    }

    private func seek(_ t: Date) async {
        let now = Date()
        if t > now.addingTimeInterval(-3) { await goLive(); return }
        UISelectionFeedbackGenerator().selectionChanged()
        live = false
        playbackFailed = false
        center = t
        await fm.ensureDay(store, t)
        let end = min(t.addingTimeInterval(3600), now)
        guard let asset = await fm.asset(store, path: fm.vodPath(cam, from: t, to: end)) else { playbackFailed = true; return }
        vodStart = t
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.isMuted = true
        playing = true
        player.playImmediately(atRate: speed)
    }

    private func togglePTZManual() {
        var ids = Set(ptzManual.split(separator: ",").map(String.init))
        if ids.contains(cam.id) { ids.remove(cam.id) } else { ids.insert(cam.id) }
        ptzManual = ids.sorted().joined(separator: ",")
    }
}

struct FilterChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background {
                    if on { Capsule().fill(Color.indigo) }
                    else { Capsule().fill(.ultraThinMaterial) }
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0 : 0.6)))
        }
        .buttonStyle(.plain)
    }
}

/// Waagrechte Zeitleiste zum Wischen: Mitte = angezeigte Zeit, farbige Marken = Ereignisse
struct FrigateTimeline: View {
    @Binding var center: Date
    @Binding var scrubbing: Bool
    let events: [FEvent]
    let onCommit: (Date) -> Void
    @State private var dragStart: Date?
    @State private var zoom: CGFloat = 180          // Punkte pro Stunde
    @State private var zoomStart: CGFloat?

    private var secPerPt: Double { 3600 / Double(zoom) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                let mid = size.width / 2
                let now = Date()
                func x(_ d: Date) -> CGFloat { mid + CGFloat(d.timeIntervalSince(center) / secPerPt) }
                let left = center.addingTimeInterval(-Double(mid) * secPerPt)
                let right = center.addingTimeInterval(Double(mid) * secPerPt)

                // Zukunft grau
                let xn = x(now)
                if xn < size.width {
                    ctx.fill(Path(CGRect(x: max(0, xn), y: 18, width: size.width - max(0, xn), height: size.height - 34)),
                             with: .color(.primary.opacity(0.05)))
                }
                // Striche: Viertelstunden, Stunden mit Uhrzeit
                let step: Double = zoom >= 120 ? 900 : 3600
                var t = (left.timeIntervalSince1970 / step).rounded(.down) * step
                while t <= right.timeIntervalSince1970 {
                    let d = Date(timeIntervalSince1970: t)
                    let px = x(d)
                    let isHour = Int(t) % 3600 == 0
                    let showLabel = isHour && (zoom >= 60 || Int(t) % 10800 == 0)
                    ctx.fill(Path(CGRect(x: px, y: 18, width: 1, height: isHour ? 10 : 5)),
                             with: .color(.primary.opacity(isHour ? 0.35 : 0.18)))
                    if showLabel {
                        let midnight = Calendar.current.component(.hour, from: d) == 0
                        let label = midnight ? d.formatted(.dateTime.weekday(.abbreviated).day()) : d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                        ctx.draw(Text(label).font(.caption2.weight(midnight ? .bold : .regular)).foregroundStyle(.secondary),
                                 at: CGPoint(x: px, y: 0), anchor: .top)
                    }
                    t += step
                }
                // Ereignisse
                for e in events {
                    let x0 = x(e.start), x1 = x(e.end ?? now)
                    guard x1 >= -10, x0 <= size.width + 10 else { continue }
                    let rect = CGRect(x: x0, y: 36, width: max(6, x1 - x0), height: 24)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(FLabel.color(e.label)))
                }
            }
            .overlay {
                // Abspielkopf
                Rectangle().fill(Color.primary).frame(width: 2)
                    .overlay(alignment: .bottom) {
                        Text(center.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(Color(.systemBackground))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
                            .fixedSize()
                    }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if dragStart == nil { dragStart = center; scrubbing = true }
                        let t = dragStart!.addingTimeInterval(-Double(v.translation.width) * secPerPt)
                        center = min(Date(), max(Date().addingTimeInterval(-14 * 86400), t))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        scrubbing = false
                        onCommit(center)
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if zoomStart == nil { zoomStart = zoom }
                        zoom = min(1200, max(30, zoomStart! * v.magnification))
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            .onTapGesture { loc in
                let t = center.addingTimeInterval(Double(loc.x - w / 2) * secPerPt)
                let tol = 12 * secPerPt
                if let e = events.first(where: { t >= $0.start.addingTimeInterval(-tol) && t <= ($0.end ?? Date()).addingTimeInterval(tol) }) {
                    onCommit(e.start.addingTimeInterval(-2))
                }
            }
        }
        .frame(height: 82)
        .padding(.horizontal, 4)
        .accessibilityElement()
        .accessibilityLabel("Zeitleiste, \(center.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onCommit(center.addingTimeInterval(600))
            case .decrement: onCommit(center.addingTimeInterval(-600))
            @unknown default: break
            }
        }
    }
}

// MARK: E · PTZ-Steuerung

struct PTZPanel: View {
    @Environment(AppStore.self) private var store
    let cam: FCam
    let info: FrigateModel.PTZInfo?
    @State private var pressed: String?
    private var fm: FrigateModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 26) {
                ZStack {
                    Circle().fill(Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
                    VStack(spacing: 0) {
                        hold("move", "up", "chevron.up", "Hoch")
                        HStack(spacing: 0) {
                            hold("move", "left", "chevron.left", "Links")
                            Button { Task { await fm.ptz(store, cam, action: "stop") } } label: {
                                Image(systemName: "stop.fill").font(.headline).foregroundStyle(.white)
                                    .frame(width: 64, height: 64).background(Color.indigo, in: Circle())
                                    .shadow(color: .indigo.opacity(0.35), radius: 8, y: 4)
                            }
                            .accessibilityLabel("Anhalten")
                            hold("move", "right", "chevron.right", "Rechts")
                        }
                        hold("move", "down", "chevron.down", "Runter")
                    }
                }
                .frame(width: 176, height: 176)
                VStack(spacing: 8) {
                    hold("zoom", "in", "plus", "Hineinzoomen", round: true)
                    Text("Zoom").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    hold("zoom", "out", "minus", "Herauszoomen", round: true)
                }
            }
            .frame(maxWidth: .infinity)

            if let presets = info?.presets, !presets.isEmpty {
                Text("Positionen").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { p in
                            FilterChip(title: p.replacingOccurrences(of: "_", with: " ").capitalized, on: false) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                Task { await fm.ptz(store, cam, action: "preset", argument: p) }
                            }
                        }
                    }
                }
            }

            if let auto = cam.switches.first(where: { $0.hasSuffix("_ptz_autotracker") }) {
                Toggle(isOn: Binding(get: { store.states[auto]?.state == "on" },
                                     set: { v in Task { await setSwitch(store, auto, v) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Autotracking").font(.subheadline.weight(.semibold))
                        Text("Kamera folgt Personen von selbst").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
                .padding(12)
                .cardSurface(radius: DS.tileRadius)
            }
        }
        .padding(16)
        .glassSurface()
    }

    /// Knopf, der die Kamera bewegt, solange er gedrückt wird
    private func hold(_ action: String, _ arg: String, _ symbol: String, _ label: String, round: Bool = false) -> some View {
        let on = pressed == arg
        return Image(systemName: symbol)
            .font(.title3.weight(.bold))
            .foregroundStyle(on ? Color.white : Color.indigo)
            .frame(width: round ? 50 : 54, height: round ? 50 : 54)
            .background {
                if round { Circle().fill(on ? Color.indigo : Color(.secondarySystemGroupedBackground)).shadow(color: .black.opacity(0.06), radius: 6, y: 3) }
                else if on { Circle().fill(Color.indigo.opacity(0.85)) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressed != arg else { return }
                        pressed = arg
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await fm.ptz(store, cam, action: action, argument: arg) }
                    }
                    .onEnded { _ in
                        pressed = nil
                        Task { await fm.ptz(store, cam, action: "stop") }
                    }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - C · Ereignisse

struct EventsFeedView: View {
    @Environment(AppStore.self) private var store
    private var fm: FrigateModel { .shared }
    @State private var filter: String?
    @State private var camFilter: String?
    @State private var loadingMore = false

    var body: some View {
        let list = filtered
        let days = Dictionary(grouping: list) { Calendar.current.startOfDay(for: $0.start) }
        let keys = days.keys.sorted(by: >)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summary
                ForEach(keys, id: \.self) { day in
                    Text(FFmt.day(day)).font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                        .textCase(.uppercase).padding(.horizontal, 4).padding(.top, 4)
                    let items = days[day] ?? []
                    if day == keys.first, let first = items.first, first.start > fm.seenUntil {
                        NavigationLink { EventClipView(ev: first) } label: { bigCard(first) }
                        rows(Array(items.dropFirst()))
                    } else {
                        rows(items)
                    }
                }
                if !fm.events.isEmpty {
                    Button {
                        guard let oldest = fm.events.last else { return }
                        loadingMore = true
                        Task {
                            await fm.loadEvents(store, before: oldest.start, limit: 100)
                            loadingMore = false
                        }
                    } label: {
                        HStack { if loadingMore { ProgressView() }; Text("Ältere laden") }
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(12)
                    }
                    .glassSurface(radius: DS.tileRadius)
                    .disabled(loadingMore)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .buttonStyle(.plain)
        .background(AppBackground())
        .navigationTitle("Ereignisse")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Kamera", selection: $camFilter) {
                        Text("Alle Kameras").tag(String?.none)
                        ForEach(fm.cameras) { c in Text(c.name).tag(String?.some(c.id)) }
                    }
                } label: { Image(systemName: camFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
            }
        }
        .refreshable { await fm.load(store, force: true) }
        .task {
            while !Task.isCancelled {
                await fm.load(store)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private var filtered: [FEvent] {
        var l = fm.events
        if let k = filter, let g = FLabel.groups.first(where: { $0.key == k }) { l = l.filter { g.labels.contains($0.label) } }
        if let c = camFilter, let cam = fm.cameras.first(where: { $0.id == c }) {
            let ids = Set(fm.events(of: cam).map(\.id))
            l = l.filter { ids.contains($0.id) }
        }
        return l
    }

    private var summary: some View {
        let new = fm.newEvents
        let parts = FLabel.groups.compactMap { g -> String? in
            let n = new.filter { g.labels.contains($0.label) }.count
            return n == 0 ? nil : "\(n) \(g.title)"
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(new.isEmpty ? "Alles gesehen" : (new.count == 1 ? "1 neues Ereignis" : "\(new.count) neue Ereignisse"))
                        .font(.headline)
                    Text(new.isEmpty ? "Seit \(FFmt.ago(fm.seenUntil))" : parts.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if !new.isEmpty {
                    Button {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation { fm.markAllSeen() }
                    } label: {
                        Text("Alle gesehen").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).background(Color.indigo, in: Capsule())
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "Alle", on: filter == nil) { filter = nil }
                    ForEach(FLabel.groups) { g in
                        FilterChip(title: g.title, on: filter == g.key) { filter = filter == g.key ? nil : g.key }
                    }
                }
            }
        }
        .padding(16)
        .glassSurface()
    }

    private func bigCard(_ ev: FEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay { HAImage(path: ev.snapshotPath) }
                .overlay {
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                }
                .overlay(alignment: .topLeading) {
                    Text("NEU").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 7)).padding(10)
                }
                .overlay(alignment: .bottomTrailing) { Text(FFmt.duration(ev.duration)).videoChip().padding(10) }
                .clipped()
            HStack(spacing: 10) {
                Circle().fill(FLabel.color(ev.label)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(FLabel.name(ev.label)) · \(fm.cameraName(ev))").font(.headline)
                    Text(meta(ev)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .cardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
    }

    @ViewBuilder private func rows(_ items: [FEvent]) -> some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { ev in
                    NavigationLink { EventClipView(ev: ev) } label: {
                        HStack(spacing: 12) {
                            EventThumb(ev: ev).frame(width: 92, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(FLabel.name(ev.label)) · \(fm.cameraName(ev))").font(.subheadline.weight(.bold)).lineLimit(1)
                                    if ev.start > fm.seenUntil {
                                        Text("NEU").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                Text(meta(ev)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    if ev.id != items.last?.id { Divider().padding(.leading, 118) }
                }
            }
            .cardSurface()
        }
    }

    private func meta(_ ev: FEvent) -> String {
        var p = [FFmt.time(ev.start), FFmt.duration(ev.duration)]
        if let s = ev.score { p.append("\(Int((s * 100).rounded())) %") }
        return p.joined(separator: " · ")
    }
}

// MARK: - F · Clip ansehen

struct EventClipView: View {
    @Environment(AppStore.self) private var store
    let ev: FEvent
    private var fm: FrigateModel { .shared }
    @State private var player: AVPlayer?
    @State private var clipFile: URL?
    @State private var imageFile: URL?

    var body: some View {
        let cam = fm.camera(for: ev)
        let same = cam.map { fm.events(of: $0) } ?? []
        let idx = same.firstIndex(where: { $0.id == ev.id })
        let before = idx.flatMap { $0 + 1 < same.count ? same[$0 + 1] : nil }
        let after = idx.flatMap { $0 > 0 ? same[$0 - 1] : nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let player { VideoPlayer(player: player) }
                        else { HAImage(path: ev.hasSnapshot ? ev.snapshotPath : ev.thumbPath, contentMode: .fit) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: FLabel.symbol(ev.label)).foregroundStyle(FLabel.color(ev.label))
                            Text("\(FLabel.name(ev.label))\(ev.subLabel.map { " (\($0))" } ?? "") · \(fm.cameraName(ev))")
                        }
                        .font(.title3.weight(.bold))
                        Text(details).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if ev.hasClip { share(clipFile, "Video", "film") }
                        share(imageFile, "Bild", "photo")
                        if let cam {
                            NavigationLink { CameraDetailView(cam: cam, startAt: ev.start.addingTimeInterval(-5)) } label: {
                                action("Aufnahme", "clock.arrow.circlepath", ready: true)
                            }
                        }
                    }
                }
                .padding(16)
                .glassSurface()

                if before != nil || after != nil {
                    VStack(spacing: 0) {
                        if let before { neighbor(before, "‹ Davor") }
                        if before != nil && after != nil { Divider().padding(.leading, 16) }
                        if let after { neighbor(after, "Danach ›") }
                    }
                    .cardSurface()
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .buttonStyle(.plain)
        .background(AppBackground())
        .navigationTitle(FFmt.time(ev.start))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ev.id) {
            if ev.hasClip, let asset = await fm.asset(store, path: ev.clipPath) {
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                p.play()
            }
            let stamp = Int(ev.start.timeIntervalSince1970)
            imageFile = await fm.download(store, path: ev.hasSnapshot ? ev.snapshotPath : ev.thumbPath, name: "Kamera-\(stamp).jpg")
            if ev.hasClip { clipFile = await fm.download(store, path: ev.clipPath, name: "Kamera-\(stamp).mp4") }
        }
        .onDisappear { player?.pause() }
    }

    private var details: String {
        var p = [FFmt.day(ev.start) + " " + FFmt.time(ev.start), FFmt.duration(ev.duration)]
        if let z = ev.zones.first { p.append("Zone " + z.replacingOccurrences(of: "_", with: " ").capitalized) }
        if let s = ev.score { p.append("\(Int((s * 100).rounded())) % sicher") }
        return p.joined(separator: " · ")
    }

    @ViewBuilder private func share(_ url: URL?, _ title: String, _ symbol: String) -> some View {
        if let url {
            ShareLink(item: url) { action(title, symbol, ready: true) }
        } else {
            action(title, symbol, ready: false)
        }
    }

    private func action(_ title: String, _ symbol: String, ready: Bool) -> some View {
        VStack(spacing: 4) {
            if ready { Image(systemName: symbol).font(.title3) } else { ProgressView().frame(height: 22) }
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(ready ? Color.indigo : .secondary)
        .frame(maxWidth: .infinity, minHeight: 58)
        .cardSurface(radius: 16)
    }

    private func neighbor(_ e: FEvent, _ dir: String) -> some View {
        NavigationLink { EventClipView(ev: e) } label: {
            HStack(spacing: 12) {
                Text(dir).font(.footnote.weight(.semibold)).foregroundStyle(.indigo).frame(width: 66, alignment: .leading)
                Circle().fill(FLabel.color(e.label)).frame(width: 8, height: 8)
                Text(FLabel.name(e.label)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(FFmt.ago(e.start)).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - G · Einstellungen pro Kamera

struct CameraSettingsView: View {
    @Environment(AppStore.self) private var store
    @State var selected: String?
    private var fm: FrigateModel { .shared }
    @State private var numberDraft: [String: Double] = [:]

    var body: some View {
        let cam = fm.cameras.first { $0.id == selected } ?? fm.cameras.first
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let cam {
                    header(cam)
                    let switches = cam.switches.filter { store.states[$0] != nil }
                    if !switches.isEmpty {
                        groupTitle("Erkennung & Aufnahme")
                        VStack(spacing: 0) {
                            ForEach(switches, id: \.self) { id in
                                switchRow(id)
                                if id != switches.last { Divider().padding(.leading, 16) }
                            }
                        }
                        .cardSurface()
                    }
                    let numbers = cam.numbers.filter { store.states[$0] != nil }
                    if !numbers.isEmpty {
                        groupTitle("Empfindlichkeit")
                        VStack(spacing: 0) {
                            ForEach(numbers, id: \.self) { id in
                                numberRow(id)
                                if id != numbers.last { Divider().padding(.leading, 16) }
                            }
                        }
                        .cardSurface()
                    }
                    let sensors = cam.sensors.filter { store.states[$0] != nil }
                    if !sensors.isEmpty {
                        groupTitle("Werte")
                        VStack(spacing: 0) {
                            ForEach(sensors, id: \.self) { id in
                                let st = store.states[id]!
                                HStack {
                                    Text(shortName(st.name, cam)).font(.body)
                                    Spacer()
                                    Text(value(st)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.horizontal, 16).frame(minHeight: 46)
                                if id != sensors.last { Divider().padding(.leading, 16) }
                            }
                        }
                        .cardSurface()
                    }
                } else if fm.loadedOnce {
                    Text("Keine Frigate-Kameras gefunden.").foregroundStyle(.secondary).padding()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await fm.load(store, force: true); await store.refreshStates() }
        .task { await fm.load(store) }
    }

    private func header(_ cam: FCam) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 96, height: 54)
                    .overlay { CamSnapshot(cam: cam, interval: 10) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cam.name).font(.headline)
                    let n = fm.events(of: cam).filter { Calendar.current.isDateInToday($0.start) }.count
                    Text("\(fm.isOnline(cam, store) ? "online" : "offline") · \(n == 1 ? "1 Ereignis" : "\(n) Ereignisse") heute")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if fm.cameras.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(fm.cameras) { c in
                            FilterChip(title: c.name, on: c.id == cam.id) { selected = c.id }
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassSurface()
    }

    private func groupTitle(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.horizontal, 16).padding(.top, 8)
    }

    private func switchRow(_ id: String) -> some View {
        let st = store.states[id]
        let d = FSwitch.describe(id, fallback: st?.name ?? id)
        let unavailable = st?.state == "unavailable"
        return Toggle(isOn: Binding(get: { st?.state == "on" }, set: { v in Task { await setSwitch(store, id, v) } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(d.title)
                if let info = d.info { Text(info).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .tint(.green)
        .disabled(unavailable)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func numberRow(_ id: String) -> some View {
        let st = store.states[id]!
        let minV = st.attributes["min"]?.double ?? 0
        let maxV = st.attributes["max"]?.double ?? 100
        let step = st.attributes["step"]?.double ?? 1
        let cur = numberDraft[id] ?? Double(st.state) ?? minV
        let cam = fm.cameras.first { $0.id == selected } ?? fm.cameras.first
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(cam.map { shortName(st.name, $0) } ?? st.name)
                Spacer()
                Text(step < 1 ? String(format: "%.2f", cur) : "\(Int(cur))").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { cur }, set: { numberDraft[id] = $0 }), in: minV...max(maxV, minV + step), step: step, onEditingChanged: { editing in
                guard !editing, let v = numberDraft[id] else { return }
                Task {
                    do { try await store.client.call("number", "set_value", ["entity_id": id, "value": v]) }
                    catch { store.report(error) }
                    await store.refreshStates()
                    numberDraft[id] = nil
                }
            })
            .tint(.indigo)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// „Haustür Kamera FPS“ → „Kamera FPS“
    private func shortName(_ n: String, _ cam: FCam) -> String {
        n.hasPrefix(cam.name + " ") ? String(n.dropFirst(cam.name.count + 1)) : n
    }

    private func value(_ st: HAState) -> String {
        let unit = st.attributes["unit_of_measurement"]?.string
        switch st.state {
        case "on": return "an"
        case "off": return "aus"
        case "unavailable", "unknown": return "–"
        default: return unit.map { "\(st.state) \($0)" } ?? st.state
        }
    }
}
