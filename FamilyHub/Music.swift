import SwiftUI

// MARK: - Musik (Sonos + Spotify über Home Assistant)
//
// Lautsprecher: FamilyConfig.speakers. Durchblättern über media_player/browse_media (WebSocket),
// Abspielen über media_player.play_media – die Sonos-Integration spielt Spotify-Inhalte direkt ab.

struct MediaItem: Identifiable, Hashable {
    let title: String
    let contentID: String
    let contentType: String
    let mediaClass: String
    let canPlay: Bool
    let canExpand: Bool
    let thumbnail: String?
    var id: String { contentType + "|" + contentID + "|" + title }

    init(_ j: JSONValue) {
        title = j["title"]?.string ?? "–"
        contentID = j["media_content_id"]?.string ?? ""
        contentType = j["media_content_type"]?.string ?? ""
        mediaClass = j["media_class"]?.string ?? ""
        canPlay = j["can_play"]?.string == "true"
        canExpand = j["can_expand"]?.string == "true"
        thumbnail = j["thumbnail"]?.string
    }

    var symbol: String {
        switch mediaClass {
        case "playlist": return "music.note.list"
        case "album": return "square.stack"
        case "artist": return "music.mic"
        case "track": return "music.note"
        case "podcast", "episode": return "mic.fill"
        case "channel": return "radio"
        case "directory": return "folder.fill"
        default: return contentType.contains("spotify") ? "music.note.house" : "music.note"
        }
    }
}

struct BrowseResult {
    let title: String
    let items: [MediaItem]
}

@MainActor
extension AppStore {

    func speakerState(_ id: String) -> HAState? { states[id] }

    /// Lautsprecher, die mit diesem zusammen spielen (Sonos-Gruppe, ohne ihn selbst)
    func speakerGroup(_ id: String) -> [String] {
        (states[id]?.attr("group_members")?.array ?? []).compactMap(\.string).filter { $0 != id }
    }

    /// Anderen Lautsprecher dazunehmen oder wieder trennen
    func setSpeaker(_ other: String, joined: Bool, to leader: String) async {
        do {
            if joined {
                try await client.call("media_player", "join", ["entity_id": leader, "group_members": [other]])
            } else {
                try await client.call("media_player", "unjoin", ["entity_id": other])
            }
            try? await Task.sleep(for: .seconds(1))
            await refreshStates()
        } catch { report(error) }
    }
    func speakerOnline(_ id: String) -> Bool {
        guard let s = states[id] else { return false }
        return !s.isUnavailable
    }

    /// Einträge, die zum Musikhören nichts beitragen (Kameras, Bilder, Sprachausgabe …)
    private static let hiddenSources = ["media-source://camera", "media-source://frigate", "media-source://image",
                                        "media-source://image_upload", "media-source://ai_task", "media-source://reolink",
                                        "media-source://tts", "media-source://media_source"]

    func browse(_ speaker: String, _ item: MediaItem? = nil) async throws -> BrowseResult {
        var cmd: [String: Any] = ["type": "media_player/browse_media", "entity_id": speaker]
        if let item {
            cmd["media_content_id"] = item.contentID
            cmd["media_content_type"] = item.contentType
        }
        let r = try await client.websocket(cmd)
        var items = (r["children"]?.array ?? []).map(MediaItem.init)
        if item == nil { items.removeAll { Self.hiddenSources.contains($0.contentID) } }
        return BrowseResult(title: r["title"]?.string ?? item?.title ?? "Musik", items: items)
    }

    func play(_ item: MediaItem, on speaker: String) async {
        do {
            try await client.call("media_player", "play_media", ["entity_id": speaker,
                                                                 "media_content_id": item.contentID,
                                                                 "media_content_type": item.contentType])
            try? await Task.sleep(for: .seconds(1.5))
            await refreshStates()
        } catch { report(error) }
    }

    func media(_ service: String, _ speaker: String, _ extra: [String: Any] = [:]) async {
        var data = extra
        data["entity_id"] = speaker
        do {
            try await client.call("media_player", service, data)
            try? await Task.sleep(for: .milliseconds(600))
            await refreshStates()
        } catch { report(error) }
    }
}

// MARK: - Suche über Music Assistant (ganzer Spotify-Katalog)

struct SearchHit: Identifiable, Hashable {
    let name: String
    let uri: String
    let type: String          // track, artist, album, playlist, radio
    let subtitle: String
    let image: String?
    var id: String { uri }

    init(_ j: JSONValue, type: String) {
        name = j["name"]?.string ?? "–"
        uri = j["uri"]?.string ?? ""
        self.type = j["media_type"]?.string ?? type
        let artists = (j["artists"]?.array ?? []).compactMap { $0["name"]?.string }.joined(separator: ", ")
        let album = j["album"]?["name"]?.string
        subtitle = [artists, album ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        image = j["image"]?.string ?? j["image"]?["path"]?.string
    }
}

@MainActor
extension AppStore {
    func assistantPlayer(for speaker: String) -> String? {
        guard let sp = FamilyConfig.speakers.first(where: { $0.id == speaker }),
              let s = states[sp.assistant], !s.isUnavailable else { return nil }
        return sp.assistant
    }

    func searchMusic(_ query: String) async throws -> [(String, [SearchHit])] {
        let r = try await client.callWithResponse("music_assistant", "search",
                                                  ["config_entry_id": FamilyConfig.musicAssistantEntry,
                                                   "name": query, "limit": 8], timeout: 40)
        let groups: [(String, String, String)] = [("tracks", "track", "Titel"), ("artists", "artist", "Künstler"),
                                                  ("albums", "album", "Alben"), ("playlists", "playlist", "Playlists"),
                                                  ("radio", "radio", "Radio"), ("podcasts", "podcast", "Podcasts")]
        return groups.compactMap { key, type, label in
            let hits = (r[key]?.array ?? []).map { SearchHit($0, type: type) }.filter { !$0.uri.isEmpty }
            return hits.isEmpty ? nil : (label, hits)
        }
    }

    /// enqueue: "play" (sofort), "next" (als Nächstes), "add" (hinten anstellen), "replace"
    func playHit(_ hit: SearchHit, on speaker: String, enqueue: String = "play") async -> String? {
        guard let player = assistantPlayer(for: speaker) else {
            return "Dieser Lautsprecher ist in Music Assistant gerade nicht verfügbar."
        }
        do {
            try await client.call("music_assistant", "play_media", ["entity_id": player, "media_id": hit.uri,
                                                                     "media_type": hit.type,
                                                                     "enqueue": hit.type == "track" ? enqueue : (enqueue == "play" ? "replace" : enqueue)])
            try? await Task.sleep(for: .seconds(1.5))
            await refreshStates()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct MusicSearchView: View {
    @Environment(AppStore.self) private var store
    let speaker: String
    @State private var query = ""
    @State private var results: [(String, [SearchHit])] = []
    @State private var searching = false
    @State private var message: String?
    @State private var started: String?

    var body: some View {
        List {
            if let message {
                Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if searching {
                HStack { ProgressView(); Text("Suche …").foregroundStyle(.secondary) }
            }
            if !searching && results.isEmpty && !query.isEmpty && message == nil {
                Text("Keine Treffer").foregroundStyle(.secondary)
            }
            ForEach(results, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { hit in
                        Button { play(hit, "play") } label: {
                            HStack(spacing: 12) {
                                Group {
                                    if let img = hit.image, img.hasPrefix("http") {
                                        AsyncImage(url: URL(string: img)) { $0.resizable().scaledToFill() } placeholder: { Color(.tertiarySystemFill) }
                                    } else {
                                        Image(systemName: hit.type == "artist" ? "music.mic" : hit.type == "radio" ? "radio" : "music.note")
                                            .foregroundStyle(.tint)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(Color(.tertiarySystemFill))
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: hit.type == "artist" ? 22 : 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.name).lineLimit(1)
                                    if !hit.subtitle.isEmpty {
                                        Text(hit.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if started == hit.uri {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { play(hit, "play") } label: { Label("Jetzt abspielen", systemImage: "play.fill") }
                            Button { play(hit, "next") } label: { Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            Button { play(hit, "add") } label: { Label("Hinten anstellen", systemImage: "text.append") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Suchen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titel, Künstler, Album …")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(600))          // erst suchen, wenn man kurz aufhört zu tippen
            guard !Task.isCancelled else { return }
            searching = true
            message = nil
            do {
                results = try await store.searchMusic(q)
                if results.isEmpty { message = "Keine Treffer. Direkt nach dem Einrichten bremst Spotify manchmal – dann in ein paar Minuten nochmal versuchen." }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
            searching = false
        }
        .safeAreaInset(edge: .bottom) { MiniPlayer(speaker: speaker) }
    }

    private func play(_ hit: SearchHit, _ how: String) {
        Task {
            if let err = await store.playHit(hit, on: speaker, enqueue: how) {
                message = err
            } else {
                started = hit.uri
                message = how == "play" ? nil : (how == "next" ? "Kommt als Nächstes." : "Hinten angestellt.")
            }
        }
    }
}

// MARK: - Hauptansicht

struct MusicView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("musicSpeaker") private var speaker = FamilyConfig.speakers.first?.id ?? ""
    @AppStorage("spotifyAccount") private var accountTitle = ""
    @State private var root: BrowseResult?
    @State private var library: BrowseResult?
    @State private var error: String?

    /// Jedes in Home Assistant angemeldete Spotify-Konto ist ein eigener Eintrag
    private var accounts: [MediaItem] { (root?.items ?? []).filter { $0.contentType == "spotify://library" } }
    private var others: [MediaItem] { (root?.items ?? []).filter { $0.contentType != "spotify://library" } }
    private var account: MediaItem? { accounts.first { $0.title == accountTitle } ?? accounts.first }

    var body: some View {
        List {
            Section {
                SpeakerPicker(selection: $speaker)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if FamilyConfig.speakers.count > 1 {
                    SpeakerGroupRow(leader: speaker)
                }
            }
            Section {
                NowPlayingView(speaker: speaker)
            }
            Section {
                NavigationLink {
                    MusicSearchView(speaker: speaker)
                } label: {
                    Label("Titel, Künstler oder Album suchen", systemImage: "magnifyingglass")
                        .font(.headline)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
            }
            if root == nil && error == nil {
                HStack { ProgressView(); Text("Lade …").foregroundStyle(.secondary) }
            }

            // Spotify – Konto wählen (Jan / Vanessa …)
            if let account {
                Section {
                    if accounts.count > 1 {
                        Picker("Konto", selection: Binding(get: { account.title }, set: { accountTitle = $0 })) {
                            ForEach(accounts) { a in Text(a.title).tag(a.title) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let library {
                        ForEach(library.items) { item in
                            NavigationLink {
                                BrowseView(speaker: speaker, item: item)
                            } label: {
                                MediaRow(item: item)
                            }
                        }
                    } else {
                        HStack { ProgressView(); Text("Lade Bibliothek …").foregroundStyle(.secondary) }
                    }
                } header: {
                    Label(accounts.count > 1 ? "Spotify" : "Spotify · \(account.title)", systemImage: "music.note.house")
                }
            }

            if !others.isEmpty {
                Section("Weitere Quellen") {
                    ForEach(others) { item in
                        NavigationLink {
                            BrowseView(speaker: speaker, item: item)
                        } label: {
                            MediaRow(item: item)
                        }
                    }
                }
            }
        }
        .navigationTitle("Musik")
        .task(id: speaker) { await loadRoot() }
        .task(id: account?.title) { await loadLibrary() }
        .refreshable { await store.refreshStates(); await loadRoot(); await loadLibrary() }
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

struct SpeakerPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FamilyConfig.speakers) { sp in
                    let online = store.speakerOnline(sp.id)
                    let playing = store.speakerState(sp.id)?.state == "playing"
                    Button { selection = sp.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: playing ? "speaker.wave.2.fill" : "hifispeaker.fill")
                                .symbolEffect(.variableColor.iterative, isActive: playing)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sp.name).font(.subheadline.weight(.semibold))
                                Text(online ? (store.speakerGroup(sp.id).isEmpty ? (playing ? "spielt" : "bereit")
                                                                                  : "verbunden") : "offline").font(.caption2)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(selection == sp.id ? .white : (online ? .primary : .secondary))
                        .background(selection == sp.id ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .opacity(online ? 1 : 0.6)
                }
            }
        }
    }
}

/// „Auch auf … abspielen“ – Sonos-Lautsprecher zusammenschalten
struct SpeakerGroupRow: View {
    @Environment(AppStore.self) private var store
    let leader: String
    @State private var busy: String?

    private var others: [FamilyConfig.Speaker] { FamilyConfig.speakers.filter { $0.id != leader } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Zusammen abspielen", systemImage: "link").font(.subheadline.weight(.semibold))
            ForEach(others) { sp in
                let joined = store.speakerGroup(leader).contains(sp.id)
                Toggle(isOn: Binding(get: { joined }, set: { on in
                    busy = sp.id
                    Task { await store.setSpeaker(sp.id, joined: on, to: leader); busy = nil }
                })) {
                    HStack(spacing: 6) {
                        Text("Auch auf \(sp.name)")
                        if busy == sp.id { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!store.speakerOnline(sp.id) || busy != nil)
            }
            Text("Die Musik vom gewählten Lautsprecher läuft dann gleichzeitig auf den anderen. Lautstärke bleibt je Lautsprecher einstellbar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Läuft gerade

struct NowPlayingView: View {
    @Environment(AppStore.self) private var store
    let speaker: String
    @State private var volume: Double = 0
    @State private var editingVolume = false

    private var s: HAState? { store.speakerState(speaker) }

    var body: some View {
        let state = s?.state ?? "unavailable"
        let title = s?.attr("media_title")?.string
        let artist = s?.attr("media_artist")?.string ?? s?.attr("media_album_name")?.string
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if let pic = s?.attr("entity_picture")?.string, title != nil {
                        HAImage(path: pic)
                    } else {
                        Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.tertiarySystemFill))
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title ?? (state == "unavailable" ? "Offline" : "Nichts ausgewählt"))
                        .font(.headline).lineLimit(2)
                    if let artist { Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    if let src = s?.attr("source")?.string, !src.isEmpty {
                        Text(src).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 30) {
                Button { Task { await store.media("shuffle_set", speaker, ["shuffle": !(s?.attr("shuffle")?.string == "true")]) } } label: {
                    Image(systemName: "shuffle").foregroundStyle(s?.attr("shuffle")?.string == "true" ? Color.accentColor : .secondary)
                }
                Button { Task { await store.media("media_previous_track", speaker) } } label: {
                    Image(systemName: "backward.fill")
                }
                Button { Task { await store.media("media_play_pause", speaker) } } label: {
                    Image(systemName: state == "playing" ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 46))
                }
                Button { Task { await store.media("media_next_track", speaker) } } label: {
                    Image(systemName: "forward.fill")
                }
                Button {
                    let next = ["off": "all", "all": "one", "one": "off"][s?.attr("repeat")?.string ?? "off"] ?? "off"
                    Task { await store.media("repeat_set", speaker, ["repeat": next]) }
                } label: {
                    Image(systemName: s?.attr("repeat")?.string == "one" ? "repeat.1" : "repeat")
                        .foregroundStyle((s?.attr("repeat")?.string ?? "off") != "off" ? Color.accentColor : .secondary)
                }
            }
            .font(.title3)
            .buttonStyle(.borderless)
            .disabled(state == "unavailable")

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                    editingVolume = editing
                    if !editing { Task { await store.media("volume_set", speaker, ["volume_level": volume]) } }
                })
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(state == "unavailable")
        }
        .padding(.vertical, 6)
        .onAppear { volume = s?.attr("volume_level")?.double ?? 0 }
        .onChange(of: s?.attr("volume_level")?.double) { _, v in
            if !editingVolume, let v { volume = v }
        }
    }
}

// MARK: - Durchblättern (Playlists, Alben, Radio …)

struct BrowseView: View {
    @Environment(AppStore.self) private var store
    let speaker: String
    let item: MediaItem
    @State private var result: BrowseResult?
    @State private var error: String?
    @State private var filter = ""
    @State private var started: String?

    private var items: [MediaItem] {
        let all = result?.items ?? []
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        List {
            if item.canPlay {
                Button {
                    Task { await store.play(item, on: speaker); started = item.id }
                } label: {
                    Label(started == item.id ? "Läuft" : "Alles abspielen",
                          systemImage: started == item.id ? "speaker.wave.2.fill" : "play.fill")
                        .font(.headline)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
            }
            if result == nil && error == nil {
                HStack { ProgressView(); Text("Lade …").foregroundStyle(.secondary) }
            }
            ForEach(items) { child in
                if child.canExpand {
                    NavigationLink {
                        BrowseView(speaker: speaker, item: child)
                    } label: {
                        MediaRow(item: child)
                    }
                } else {
                    Button {
                        Task { await store.play(child, on: speaker); started = child.id }
                    } label: {
                        HStack {
                            MediaRow(item: child)
                            if started == child.id {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!child.canPlay)
                }
            }
        }
        .navigationTitle(result?.title ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "In dieser Liste suchen")
        .task {
            do { result = try await store.browse(speaker, item) }
            catch { self.error = error.localizedDescription }
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayer(speaker: speaker)
        }
    }
}

struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let t = item.thumbnail, t.hasPrefix("http") {
                    AsyncImage(url: URL(string: t)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color(.tertiarySystemFill)
                    }
                } else if let t = item.thumbnail, t.hasPrefix("/") {
                    HAImage(path: t)
                } else {
                    Image(systemName: item.symbol).foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: item.mediaClass == "artist" ? 22 : 8))
            Text(item.title).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

/// Kleine Leiste unten: was läuft + Play/Pause
struct MiniPlayer: View {
    @Environment(AppStore.self) private var store
    let speaker: String

    var body: some View {
        let s = store.speakerState(speaker)
        if let s, let title = s.attr("media_title")?.string {
            HStack(spacing: 12) {
                if let pic = s.attr("entity_picture")?.string {
                    HAImage(path: pic).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(s.attr("media_artist")?.string ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { Task { await store.media("media_play_pause", speaker) } } label: {
                    Image(systemName: s.state == "playing" ? "pause.fill" : "play.fill").font(.title3)
                }
                Button { Task { await store.media("media_next_track", speaker) } } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Karte auf „Heute“, wenn Musik läuft

struct MusicTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let sp = FamilyConfig.speakers.first(where: { store.speakerState($0.id)?.state == "playing" }) {
            NavigationLink { MusicView() } label: {
                Card(title: "Musik · \(sp.name)", symbol: "hifispeaker.fill") {
                    HStack(spacing: 12) {
                        if let pic = store.speakerState(sp.id)?.attr("entity_picture")?.string {
                            HAImage(path: pic).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.speakerState(sp.id)?.attr("media_title")?.string ?? "Läuft").font(.headline).lineLimit(1)
                            Text(store.speakerState(sp.id)?.attr("media_artist")?.string ?? "")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { Task { await store.media("media_play_pause", sp.id) } } label: {
                            Image(systemName: "pause.circle.fill").font(.system(size: 34))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
