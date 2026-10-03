import SwiftUI
import UIKit

// MARK: - Musik-Player „Cover-Glas“ (Entwurf 1B)
//
// Vollbild-Player: großes Cover, dahinter leuchten die Farben des Covers. Bibliothek, Suche und
// Konto (Jan / Vanessa) öffnen sich als Blatt von unten (Knopf oben in der Mitte).

struct MusicView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("musicSpeaker") private var speaker = FamilyConfig.speakers.first?.id ?? ""
    @AppStorage("spotifyAccount") private var accountTitle = ""
    @State private var showLibrary = false
    @State private var palette = CoverPalette.standard
    @State private var cover: UIImage?
    @State private var volume: Double = 0
    @State private var editingVolume = false
    @State private var myTab = ""

    private var s: HAState? { store.speakerState(speaker) }
    private var playing: Bool { s?.state == "playing" }
    private var offline: Bool { s == nil || s?.state == "unavailable" }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 48, 340)
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                coverView.frame(width: side, height: side)
                Spacer(minLength: 16)
                VStack(spacing: 18) {
                    titleBlock
                    progress
                    controls
                    volumeRow
                    SpeakerPicker(selection: $speaker)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background(CoverGlow(palette: palette).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLibrary) {
            MusicLibrarySheet(speaker: speaker, accountTitle: $accountTitle)
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(palette.base.opacity(0.94))
                .environment(\.colorScheme, .dark)
        }
        .onAppear { myTab = store.selectedTab; TabBarVisibility.shared.hide(myTab) }
        .onDisappear { TabBarVisibility.shared.show(myTab) }
        .task(id: s?.attr("entity_picture")?.string) { await loadCover() }
        .onAppear { volume = s?.attr("volume_level")?.double ?? 0 }
        .onChange(of: s?.attr("volume_level")?.double) { _, v in
            if !editingVolume, let v { volume = v }
        }
    }

    // MARK: Teile

    private var header: some View {
        HStack {
            circleButton("chevron.left", label: "Zurück") { dismiss() }
            Spacer()
            Button { showLibrary = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                    Text(accountTitle.isEmpty ? "Bibliothek" : "Bibliothek · \(accountTitle)").lineLimit(1)
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 16).frame(height: 44)
                .background(.white.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            }
            .buttonStyle(.plain)
            Spacer()
            circleButton("magnifyingglass", label: "Suchen") { showLibrary = true }
        }
        .padding(.top, 8)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var coverView: some View {
        ZStack {
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [palette.c1, palette.c3], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: offline ? "speaker.slash.fill" : "music.note")
                    .font(.system(size: 60, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
        .scaleEffect(playing ? 1 : 0.88)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: playing)
    }

    private var titleBlock: some View {
        let title = s?.attr("media_title")?.string
        let artist = s?.attr("media_artist")?.string ?? s?.attr("media_album_name")?.string
        return VStack(alignment: .leading, spacing: 4) {
            Text(title ?? (offline ? "Lautsprecher offline" : "Nichts ausgewählt"))
                .font(.title2.weight(.bold)).lineLimit(1)
            Text(artist ?? (offline ? "" : "Bibliothek öffnen und etwas auswählen"))
                .font(.body).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let dur = s?.attr("media_duration")?.double ?? 0
            let pos = currentPosition(at: ctx.date)
            VStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: dur > 0 ? g.size.width * min(1, pos / dur) : 0)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(Self.time(pos))
                    Spacer()
                    Text(dur > 0 ? "-" + Self.time(max(0, dur - pos)) : "")
                }
                .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            .opacity(dur > 0 ? 1 : 0.4)
        }
    }

    private func currentPosition(at now: Date) -> Double {
        let pos = s?.attr("media_position")?.double ?? 0
        guard playing, let up = HADate.parse(s?.attr("media_position_updated_at")?.string) else { return pos }
        let dur = s?.attr("media_duration")?.double ?? .infinity
        return min(dur, pos + now.timeIntervalSince(up))
    }

    private static func time(_ t: Double) -> String {
        let s = Int(t.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    private var controls: some View {
        let shuffle = s?.attr("shuffle")?.string == "true"
        let rep = s?.attr("repeat")?.string ?? "off"
        return HStack {
            Button { Task { await store.media("shuffle_set", speaker, ["shuffle": !shuffle]) } } label: {
                Image(systemName: "shuffle").font(.title3).frame(width: 44, height: 44)
                    .opacity(shuffle ? 1 : 0.6)
                    .overlay(alignment: .bottom) { if shuffle { Circle().frame(width: 4, height: 4).offset(y: 2) } }
            }
            .accessibilityLabel("Zufall")
            Spacer()
            Button { Task { await store.media("media_previous_track", speaker) } } label: {
                Image(systemName: "backward.fill").font(.system(size: 28)).frame(width: 52, height: 52)
            }
            .accessibilityLabel("Zurück")
            Spacer()
            Button { Task { await store.media("media_play_pause", speaker) } } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(palette.base)
                    .frame(width: 78, height: 78)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 15, y: 12)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playing ? "Pause" : "Abspielen")
            Spacer()
            Button { Task { await store.media("media_next_track", speaker) } } label: {
                Image(systemName: "forward.fill").font(.system(size: 28)).frame(width: 52, height: 52)
            }
            .accessibilityLabel("Weiter")
            Spacer()
            Button {
                let next = ["off": "all", "all": "one", "one": "off"][rep] ?? "off"
                Task { await store.media("repeat_set", speaker, ["repeat": next]) }
            } label: {
                Image(systemName: rep == "one" ? "repeat.1" : "repeat").font(.title3).frame(width: 44, height: 44)
                    .opacity(rep != "off" ? 1 : 0.6)
                    .overlay(alignment: .bottom) { if rep != "off" { Circle().frame(width: 4, height: 4).offset(y: 2) } }
            }
            .accessibilityLabel("Wiederholen")
        }
        .buttonStyle(.plain)
        .disabled(offline)
        .opacity(offline ? 0.5 : 1)
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption)
            Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                editingVolume = editing
                if !editing { Task { await store.media("volume_set", speaker, ["volume_level": volume]) } }
            })
            .tint(.white)
            Text("\(Int((volume * 100).rounded()))").font(.caption).monospacedDigit().frame(width: 28, alignment: .trailing)
        }
        .disabled(offline)
    }

    private func loadCover() async {
        guard let pic = s?.attr("entity_picture")?.string, s?.attr("media_title") != nil else {
            withAnimation(.easeInOut(duration: 0.8)) { cover = nil; palette = .standard }
            return
        }
        guard let img = await store.client.image(path: pic) else { return }
        let p = CoverPalette(img) ?? .standard
        withAnimation(.easeInOut(duration: 0.8)) {
            cover = img
            palette = p
        }
    }
}

// MARK: - Lautsprecher (Küche / Move 2) als Glas-Knöpfe

/// Einer = nur dort. Einen zweiten antippen = beide spielen dasselbe (Sonos-Gruppe). Nochmal antippen nimmt ihn raus.
struct SpeakerPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String
    @State private var busy: String?

    private var active: Set<String> { Set([selection] + store.speakerGroup(selection)) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(FamilyConfig.speakers) { sp in chip(sp) }
        }
    }

    private func chip(_ sp: FamilyConfig.Speaker) -> some View {
        let online = store.speakerOnline(sp.id)
        let on = active.contains(sp.id)
        return Button { tap(sp.id) } label: {
            HStack(spacing: 8) {
                ZStack {
                    if busy == sp.id {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else if on {
                        Circle().fill(.white).overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black.opacity(0.75)))
                    } else {
                        Circle().strokeBorder(.white, lineWidth: 1.5).overlay(Image(systemName: "plus").font(.system(size: 10, weight: .heavy)))
                    }
                }
                .frame(width: 20, height: 20)
                Text(sp.name).font(.subheadline.weight(.semibold))
                if !online { Text("offline").font(.caption2).opacity(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.white.opacity(on ? 0.2 : 0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.28)))
        }
        .buttonStyle(.plain)
        .disabled(!online || busy != nil)
        .opacity(online ? 1 : 0.5)
        .accessibilityLabel(sp.name + (on ? ", spielt" : ", dazunehmen"))
    }

    private func tap(_ id: String) {
        let members = active
        if !members.contains(id) {
            if store.speakerState(selection)?.state == "playing" {
                busy = id
                Task { await store.setSpeaker(id, joined: true, to: selection); busy = nil }
            } else {
                selection = id          // nichts läuft: einfach zu diesem Lautsprecher wechseln
            }
        } else if members.count > 1 {
            busy = id
            if id == selection, let next = members.subtracting([id]).sorted().first { selection = next }
            Task { await store.setSpeaker(id, joined: false, to: selection); busy = nil }
        }
    }
}

// MARK: - Bibliothek & Suche (Blatt von unten)

struct MusicLibrarySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let speaker: String
    @Binding var accountTitle: String
    @State private var root: BrowseResult?
    @State private var library: BrowseResult?
    @State private var error: String?

    /// Jedes in Home Assistant angemeldete Spotify-Konto ist ein eigener Eintrag
    private var accounts: [MediaItem] { (root?.items ?? []).filter { $0.contentType == "spotify://library" } }
    private var others: [MediaItem] { (root?.items ?? []).filter { $0.contentType != "spotify://library" } }
    private var account: MediaItem? { accounts.first { $0.title == accountTitle } ?? accounts.first }

    var body: some View {
        NavigationStack {
            List {
                if store.speakerState(speaker)?.attr("media_title") != nil {
                    MiniPlayer(speaker: speaker)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                Section {
                    NavigationLink {
                        MusicSearchView(speaker: speaker)
                    } label: {
                        Label("Titel, Künstler oder Album suchen", systemImage: "magnifyingglass").font(.headline)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                }
                if root == nil && error == nil {
                    HStack { ProgressView(); Text("Lade …").foregroundStyle(.secondary) }
                }
                if let account {
                    Section {
                        if accounts.count > 1 {
                            Picker("Konto", selection: Binding(get: { account.title }, set: { accountTitle = $0 })) {
                                ForEach(accounts) { a in Text(a.title).tag(a.title) }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                        if let library {
                            ForEach(library.items) { item in
                                NavigationLink { BrowseView(speaker: speaker, item: item) } label: { MediaRow(item: item) }
                            }
                        } else {
                            HStack { ProgressView(); Text("Lade Bibliothek …").foregroundStyle(.secondary) }
                        }
                    } header: {
                        Text(accounts.count > 1 ? "Spotify" : "Spotify · \(account.title)")
                    }
                }
                if !others.isEmpty {
                    Section("Weitere Quellen") {
                        ForEach(others) { item in
                            NavigationLink { BrowseView(speaker: speaker, item: item) } label: { MediaRow(item: item) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Bibliothek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .task(id: speaker) { await loadRoot() }
        .task(id: account?.title) { await loadLibrary() }
    }

    private func loadRoot() async {
        guard store.speakerOnline(speaker) || root == nil else { return }
        do {
            root = try await store.browse(speaker)
            error = nil
            // Standard: das Konto des angemeldeten Elternteils, sonst das erste
            if accountTitle.isEmpty, let me = store.myParentID, let name = FamilyConfig.parent(me)?.name,
               let mine = accounts.first(where: { $0.title.localizedCaseInsensitiveContains(name) }) {
                accountTitle = mine.title
            } else if accountTitle.isEmpty, let first = accounts.first {
                accountTitle = first.title
            }
        } catch {
            self.error = store.speakerOnline(speaker) ? error.localizedDescription
                                                       : "Dieser Lautsprecher ist gerade offline."
        }
    }

    private func loadLibrary() async {
        guard let account else { return }
        library = nil
        library = try? await store.browse(speaker, account)
    }
}

// MARK: - Farben aus dem Cover

struct CoverPalette: Equatable {
    var base: Color
    var c1: Color
    var c2: Color
    var c3: Color

    static let standard = CoverPalette(base: Color(red: 0.16, green: 0.09, blue: 0.25),
                                       c1: Color(red: 0.94, green: 0.54, blue: 0.29),
                                       c2: Color(red: 0.85, green: 0.23, blue: 0.47),
                                       c3: Color(red: 0.23, green: 0.16, blue: 0.55))

    init(base: Color, c1: Color, c2: Color, c3: Color) {
        self.base = base; self.c1 = c1; self.c2 = c2; self.c3 = c3
    }

    /// Cover auf 3×3 Punkte verkleinern und daraus drei leuchtende Farben + einen dunklen Grund ableiten
    init?(_ img: UIImage) {
        guard let cg = img.cgImage else { return nil }
        var buf = [UInt8](repeating: 0, count: 3 * 3 * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            return true
        }
        guard ok else { return nil }
        func px(_ x: Int, _ y: Int) -> UIColor {
            let o = (y * 3 + x) * 4
            return UIColor(red: CGFloat(buf[o]) / 255, green: CGFloat(buf[o + 1]) / 255, blue: CGFloat(buf[o + 2]) / 255, alpha: 1)
        }
        func glow(_ c: UIColor) -> Color {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: Double(h), saturation: Double(min(1, s * 1.35 + 0.08)), brightness: Double(min(0.92, max(0.5, b * 1.15))))
        }
        func dark(_ c: UIColor) -> Color {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: Double(h), saturation: Double(min(0.75, s * 1.1 + 0.15)), brightness: 0.2)
        }
        let center = px(1, 1)
        self.init(base: dark(center), c1: glow(px(0, 0)), c2: glow(px(2, 1)), c3: glow(px(1, 2)))
    }
}

/// Hintergrund: dunkler Grund mit drei weichen Farbflecken aus dem Cover
struct CoverGlow: View {
    let palette: CoverPalette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                palette.base
                Circle().fill(palette.c1).frame(width: w * 1.35, height: w * 1.35)
                    .blur(radius: 110).opacity(0.75)
                    .offset(x: -w * 0.3, y: -w * 0.2)
                Circle().fill(palette.c2).frame(width: w * 1.1, height: w * 1.1)
                    .blur(radius: 120).opacity(0.6)
                    .offset(x: w * 0.3, y: h * 0.32)
                Circle().fill(palette.c3).frame(width: w, height: w)
                    .blur(radius: 110).opacity(0.75)
                    .offset(x: -w * 0.15, y: h * 0.66)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
        }
    }
}

// MARK: - Tab-Leiste ausblenden (Vollbild-Seiten wie der Player)

/// Merkt sich, in welchem Tab gerade eine Vollbild-Seite offen ist – nur dort fehlt die Leiste
@MainActor @Observable
final class TabBarVisibility {
    static let shared = TabBarVisibility()
    /// Tab → Anzahl offener Vollbild-Seiten (zählt, damit beim Wechsel zwischen zwei solchen Seiten nichts aufblitzt)
    var hiddenTabs: [String: Int] = [:]

    func hide(_ tab: String) { hiddenTabs[tab, default: 0] += 1 }
    func show(_ tab: String) {
        let n = (hiddenTabs[tab] ?? 0) - 1
        hiddenTabs[tab] = n > 0 ? n : nil
    }
    func isHidden(_ tab: String) -> Bool { (hiddenTabs[tab] ?? 0) > 0 }
}

// Zurück-Wischen auch auf Seiten ohne Navigationsleiste
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
