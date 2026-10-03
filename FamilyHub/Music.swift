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

    /// Titel aus einer Liste abspielen und danach weiterlaufen lassen:
    /// – Playlist/Album (als Ganzes abspielbar): alles laden und ab diesem Titel starten (Sonos-Warteschlange)
    /// – sonst (z. B. Lieblingssongs): diesen Titel spielen und die nächsten Titel hinten anstellen
    func playFrom(_ list: [MediaItem], index: Int, container: MediaItem, on speaker: String) async {
        guard list.indices.contains(index) else { return }
        let track = list[index]
        do {
            if container.canPlay {
                try await client.call("media_player", "play_media", ["entity_id": speaker, "media_content_id": container.contentID,
                                                                     "media_content_type": container.contentType, "enqueue": "replace"])
                try? await Task.sleep(for: .seconds(1.5))
                try await client.call("sonos", "play_queue", ["entity_id": speaker, "queue_position": index])
            } else {
                try await client.call("media_player", "play_media", ["entity_id": speaker, "media_content_id": track.contentID,
                                                                     "media_content_type": track.contentType, "enqueue": "replace"])
                // Rest im Hintergrund anstellen, damit der erste Titel sofort läuft
                let rest = Array(list.dropFirst(index + 1).filter { $0.canPlay && !$0.canExpand }.prefix(40))
                let client: HAClient = self.client
                Task.detached {
                    for t in rest {
                        try? await client.call("media_player", "play_media", ["entity_id": speaker, "media_content_id": t.contentID,
                                                                              "media_content_type": t.contentType, "enqueue": "add"])
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        started = hit.uri
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

// MARK: - Durchblättern (Playlists, Alben, Radio …)

struct BrowseView: View {
    @Environment(AppStore.self) private var store
    let speaker: String
    let item: MediaItem
    @State private var result: BrowseResult?
    @State private var error: String?
    @State private var filter = ""
    @State private var started: String?
    @State private var pending: String?

    private func tap(_ child: MediaItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) { pending = child.id }
        Task {
            let all = result?.items ?? []
            if let i = all.firstIndex(of: child) {
                await store.playFrom(all, index: i, container: item, on: speaker)
            } else {
                await store.play(child, on: speaker)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { started = child.id; pending = nil }
        }
    }

    private var items: [MediaItem] {
        let all = result?.items ?? []
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        List {
            if item.canPlay {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    pending = item.id
                    Task {
                        await store.play(item, on: speaker)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        started = item.id; pending = nil
                    }
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
                        tap(child)
                    } label: {
                        HStack {
                            MediaRow(item: child)
                            if pending == child.id {
                                ProgressView()
                            } else if started == child.id {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!child.canPlay || pending != nil)
                    .listRowBackground(pending == child.id || started == child.id ? Color.accentColor.opacity(0.12) : nil)
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
