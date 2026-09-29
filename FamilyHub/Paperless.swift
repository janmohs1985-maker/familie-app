import SwiftUI
import PDFKit

// MARK: - Paperless-ngx
//
// Die App spricht nie direkt mit Paperless: script.familie_paperless → Family Hub (Add-on) → Paperless im Heimnetz.
// Den API-Token kennt nur Family Hub (Add-on-Einstellung paperless_token).

struct PaperlessTag: Identifiable, Hashable {
    let id: Int
    let name: String
    let color: Color
    let inbox: Bool
    let count: Int
}

struct PaperlessItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let count: Int
}

struct PaperlessDocTag: Hashable {
    let name: String
    let color: Color
}

struct PaperlessDoc: Identifiable, Hashable {
    let id: Int
    var title: String
    var created: Date?
    var correspondent: String
    var type: String
    var tags: [PaperlessDocTag]
    var tagIDs: [Int]
    var correspondentID: Int?
    var typeID: Int?
    var inbox: Bool
    var pages: Int?
    var snippet: String
    var thumbnail: Data?

    static func == (a: PaperlessDoc, b: PaperlessDoc) -> Bool { a.id == b.id && a.title == b.title && a.tagIDs == b.tagIDs }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PaperlessStatus {
    var configured = false
    var reachable = false
    var count = 0
    var inbox = 0
    var error: String?
    var ready: Bool { configured && reachable && error == nil }
}

struct PaperlessMeta {
    var tags: [PaperlessTag] = []
    var correspondents: [PaperlessItem] = []
    var types: [PaperlessItem] = []
    var inboxTag: PaperlessTag? { tags.first { $0.inbox } }
}

struct PaperlessTask {
    let status: String          // PENDING, STARTED, SUCCESS, FAILURE
    let documentID: Int?
    let message: String
}

/// KI-Vorschlag von Paperless (über Ollama) – vorhandene Einträge mit id, neue nur mit Namen
struct PaperlessAIItem: Hashable {
    let id: Int?
    let name: String
}

struct PaperlessAISuggestion {
    var title: String
    var correspondents: [PaperlessAIItem]
    var types: [PaperlessAIItem]
    var tags: [PaperlessAIItem]
}

struct PaperlessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PaperlessColor {
    /// "#a6cee3" → Color
    static func from(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

@MainActor
extension AppStore {
    var canUsePaperless: Bool { isParent && activeKid == nil }

    func paperless(_ data: [String: Any], timeout: TimeInterval = 60) async throws -> JSONValue {
        let raw = try await client.callWithResponse("script", "familie_paperless", ["daten": data], timeout: timeout)
        let r: JSONValue = raw["ok"] != nil ? raw : (raw["content"] ?? raw)
        guard r["ok"]?.string == "true" else {
            throw PaperlessError(message: r["error"]?.string ?? "Paperless antwortet nicht.")
        }
        return r
    }

    func paperlessStatus() async -> PaperlessStatus {
        var s = PaperlessStatus()
        do {
            let r = try await paperless(["aktion": "status"], timeout: 20)
            s.configured = r["eingerichtet"]?.string == "true"
            s.reachable = r["erreichbar"]?.string == "true"
            s.count = r["anzahl"]?.int ?? 0
            s.inbox = r["posteingang"]?.int ?? 0
            s.error = r["error"]?.string
        } catch {
            s.error = error.localizedDescription
        }
        return s
    }

    func paperlessMeta() async throws -> PaperlessMeta {
        let r = try await paperless(["aktion": "meta"])
        var m = PaperlessMeta()
        m.tags = (r["tags"]?.array ?? []).compactMap { t in
            guard let id = t["id"]?.int, let name = t["name"]?.string else { return nil }
            return PaperlessTag(id: id, name: name, color: PaperlessColor.from(t["color"]?.string ?? ""),
                                inbox: t["inbox"]?.string == "true", count: t["anzahl"]?.int ?? 0)
        }
        m.correspondents = Self.plItems(r["korrespondenten"])
        m.types = Self.plItems(r["typen"])
        return m
    }

    private static func plItems(_ v: JSONValue?) -> [PaperlessItem] {
        (v?.array ?? []).compactMap { c in
            guard let id = c["id"]?.int, let name = c["name"]?.string else { return nil }
            return PaperlessItem(id: id, name: name, count: c["anzahl"]?.int ?? 0)
        }
    }

    private static func plDoc(_ d: JSONValue) -> PaperlessDoc? {
        guard let id = d["id"]?.int else { return nil }
        let tags: [PaperlessDocTag] = (d["tags"]?.array ?? []).compactMap { t in
            guard let n = t["name"]?.string else { return nil }
            return PaperlessDocTag(name: n, color: PaperlessColor.from(t["color"]?.string ?? ""))
        }
        let tagIDs: [Int] = (d["tag_ids"]?.array ?? []).compactMap { $0.int }
        let thumb: Data? = d["vorschau"]?.string.flatMap { Data(base64Encoded: $0) }
        let snippet: String = (d["auszug"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        return PaperlessDoc(id: id, title: d["titel"]?.string ?? "Dokument",
                            created: HADate.day.date(from: d["datum"]?.string ?? ""),
                            correspondent: d["korrespondent"]?.string ?? "", type: d["typ"]?.string ?? "",
                            tags: tags, tagIDs: tagIDs,
                            correspondentID: d["korrespondent_id"]?.int, typeID: d["typ_id"]?.int,
                            inbox: d["posteingang"]?.string == "true",
                            pages: d["seiten"]?.int, snippet: snippet, thumbnail: thumb)
    }

    func paperlessSearch(text: String, tag: Int?, correspondent: Int?, type: Int?, inbox: Bool, page: Int) async throws -> (docs: [PaperlessDoc], total: Int, more: Bool) {
        var q: [String: Any] = ["aktion": "suche", "seite": page, "anzahl": 25]
        if !text.isEmpty { q["text"] = text }
        if let tag { q["tag"] = String(tag) }
        if let correspondent { q["korrespondent"] = String(correspondent) }
        if let type { q["typ"] = String(type) }
        if inbox { q["posteingang"] = true }
        let r = try await paperless(q, timeout: 90)
        let docs: [PaperlessDoc] = (r["dokumente"]?.array ?? []).compactMap { Self.plDoc($0) }
        return (docs, r["anzahl"]?.int ?? docs.count, r["weiter"]?.string == "true")
    }

    func paperlessDocument(_ id: Int) async throws -> PaperlessDoc {
        let r = try await paperless(["aktion": "dokument", "id": id])
        guard let d = r["dokument"], let doc = Self.plDoc(d) else { throw PaperlessError(message: "Dokument nicht gefunden.") }
        return doc
    }

    /// Titel, Datum, Absender, Art und Tags in Paperless ändern
    func paperlessUpdate(_ doc: PaperlessDoc) async throws -> PaperlessDoc {
        var q: [String: Any] = ["aktion": "aendern", "id": doc.id, "titel": doc.title, "tags": doc.tagIDs.map { String($0) }]
        q["korrespondent"] = doc.correspondentID.map { String($0) } ?? ""
        q["typ"] = doc.typeID.map { String($0) } ?? ""
        if let c = doc.created { q["datum"] = HADate.day.string(from: c) }
        let r = try await paperless(q)
        guard let d = r["dokument"], var updated = Self.plDoc(d) else { return doc }
        updated.thumbnail = doc.thumbnail
        return updated
    }

    /// Neuen Tag / Absender / Art anlegen (kind: "neu_tag", "neu_korrespondent", "neu_typ")
    func paperlessCreate(_ kind: String, name: String) async throws -> Int {
        let r = try await paperless(["aktion": kind, "name": name])
        guard let id = r["id"]?.int else { throw PaperlessError(message: "Konnte nicht angelegt werden.") }
        return id
    }

    func paperlessTask(_ id: String) async throws -> PaperlessTask {
        let r = try await paperless(["aktion": "aufgabe", "aufgabe": id], timeout: 20)
        return PaperlessTask(status: r["status"]?.string ?? "PENDING", documentID: r["dokument"]?.int,
                             message: r["meldung"]?.string ?? "")
    }

    /// KI-Vorschläge – laufen in Family Hub im Hintergrund; status: laeuft | fertig | fehler
    func paperlessAI(_ id: Int, restart: Bool = false) async throws -> (status: String, seconds: Int, suggestion: PaperlessAISuggestion?, error: String?) {
        var q: [String: Any] = ["aktion": "vorschlaege", "id": id]
        if restart { q["neu"] = true }
        let r = try await paperless(q, timeout: 30)
        let status: String = r["status"]?.string ?? "fehler"
        var sug: PaperlessAISuggestion?
        if let v = r["vorschlaege"], v.object != nil {
            sug = PaperlessAISuggestion(title: v["titel"]?.string ?? "",
                                        correspondents: Self.aiItems(v["absender"]),
                                        types: Self.aiItems(v["typen"]),
                                        tags: Self.aiItems(v["tags"]))
        }
        return (status, r["sekunden"]?.int ?? 0, sug, r["fehler"]?.string)
    }

    private static func aiItems(_ v: JSONValue?) -> [PaperlessAIItem] {
        (v?.array ?? []).compactMap { x in
            guard let n = x["name"]?.string, !n.isEmpty else { return nil }
            return PaperlessAIItem(id: x["id"]?.int, name: n)
        }
    }

    /// Dokument löschen – Paperless legt es in den Papierkorb (dort wiederherstellbar)
    func paperlessDelete(_ id: Int) async throws {
        _ = try await paperless(["aktion": "loeschen", "id": id])
    }

    func paperlessFile(_ id: Int) async throws -> Data {
        let r = try await paperless(["aktion": "datei", "id": id], timeout: 120)
        guard let b64 = r["data"]?.string, let d = Data(base64Encoded: b64) else {
            throw PaperlessError(message: "Das Dokument konnte nicht geladen werden.")
        }
        return d
    }

    /// Scan über die Paperless-API hochladen – liefert die Aufgaben-ID zum Nachverfolgen
    func uploadScanToPaperless(_ scan: ScanFile, title: String, tags: [Int], correspondent: Int?, type: Int?) async throws -> String {
        var q: [String: Any] = ["aktion": "hochladen", "file": scan.file, "titel": title, "tags": tags.map { String($0) }]
        if let correspondent { q["korrespondent"] = String(correspondent) }
        if let type { q["typ"] = String(type) }
        let r = try await paperless(q, timeout: 150)
        sentScans.insert(scan.file)
        return r["aufgabe"]?.string ?? ""
    }
}

// MARK: - Übersicht & Suche (im Bereich „Dokumente“)

struct PaperlessView: View {
    @Environment(AppStore.self) private var store
    @State private var status: PaperlessStatus?
    @State private var meta = PaperlessMeta()
    @State private var docs: [PaperlessDoc] = []
    @State private var total = 0
    @State private var more = false
    @State private var page = 1
    @State private var loading = false
    @State private var error: String?
    @State private var text = ""
    @State private var tag: Int?
    @State private var correspondent: Int?
    @State private var type: Int?
    @State private var inboxOnly = false

    private var ready: Bool { status?.ready == true }
    private var filtered: Bool {
        if !text.isEmpty || inboxOnly { return true }
        return tag != nil || correspondent != nil || type != nil
    }

    var body: some View {
        List {
            if let status, !ready {
                PaperlessSetupSection(status: status)
            } else if status == nil {
                ProgressView("Frage Paperless …").frame(maxWidth: .infinity)
            } else {
                filterSection
                resultsSection
            }
        }
        .searchable(text: $text, prompt: "Volltext, Titel, Absender …")
        .onSubmit(of: .search) { Task { await reload() } }
        .onChange(of: text) { _, t in if t.isEmpty { Task { await reload() } } }
        .refreshable { await start() }
        .task { if status == nil { await start() } }
    }

    private func removed(_ id: Int) {
        docs.removeAll { $0.id == id }
        total = max(0, total - 1)
    }

    private func updated(_ changed: PaperlessDoc) {
        if let i = docs.firstIndex(where: { $0.id == changed.id }) { docs[i] = changed }
    }

    private func start() async {
        status = await store.paperlessStatus()
        guard ready else { return }
        if let m = try? await store.paperlessMeta() { meta = m }
        await reload()
    }

    private func reload() async {
        page = 1
        await load(append: false)
    }

    private func load(append: Bool) async {
        loading = true
        error = nil
        do {
            let r = try await store.paperlessSearch(text: text.trimmingCharacters(in: .whitespaces), tag: tag,
                                                    correspondent: correspondent, type: type, inbox: inboxOnly, page: page)
            docs = append ? docs + r.docs : r.docs
            total = r.total
            more = r.more
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    // MARK: Filter

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if meta.inboxTag != nil {
                        chip("Posteingang (\(status?.inbox ?? 0))", systemImage: "tray.full.fill", active: inboxOnly) {
                            inboxOnly.toggle()
                            Task { await reload() }
                        }
                    }
                    filterMenu("Tag", systemImage: "tag", selection: $tag,
                               items: meta.tags.map { PaperlessItem(id: $0.id, name: $0.name, count: $0.count) })
                    filterMenu("Absender", systemImage: "person.crop.rectangle", selection: $correspondent, items: meta.correspondents)
                    filterMenu("Art", systemImage: "doc.text", selection: $type, items: meta.types)
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } footer: {
            if let s = status { Text("\(s.count) Dokumente in Paperless") }
        }
    }

    private func chip(_ title: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func filterMenu(_ title: String, systemImage: String, selection: Binding<Int?>, items: [PaperlessItem]) -> some View {
        let current: String? = items.first { $0.id == selection.wrappedValue }?.name
        let active: Bool = current != nil
        return Menu {
            Button("Alle") { selection.wrappedValue = nil; Task { await reload() } }
            Divider()
            ForEach(items.filter { $0.count > 0 }) { it in
                Button("\(it.name) (\(it.count))") { selection.wrappedValue = it.id; Task { await reload() } }
            }
        } label: {
            Label(current ?? title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
    }

    // MARK: Ergebnisse

    private var resultsSection: some View {
        Section {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.subheadline)
            }
            if docs.isEmpty && !loading && error == nil {
                Text("Keine Dokumente gefunden").foregroundStyle(.secondary)
            }
            ForEach(docs) { d in
                NavigationLink {
                    PaperlessDocView(doc: d, meta: meta, changed: { changed in updated(changed) },
                                     deleted: { id in removed(id) })
                } label: {
                    PaperlessDocRow(doc: d)
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if more {
                Button("Weitere laden") {
                    page += 1
                    Task { await load(append: true) }
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            Text(filtered ? "\(total) Treffer" : "Neueste")
        }
    }
}

struct PaperlessSetupSection: View {
    let status: PaperlessStatus

    var body: some View {
        Section {
            Label(status.reachable ? "Paperless ist erreichbar" : "Paperless nicht erreichbar",
                  systemImage: status.reachable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(status.reachable ? Color.green : Color.red)
            if let e = status.error { Text(e).font(.subheadline).foregroundStyle(.secondary) }
            Text("Einrichten (einmalig, nur Jan): In Paperless unter „Mein Profil“ einen API-Token erzeugen und in Home Assistant bei Add-ons → Family Hub → Konfiguration → paperless_token eintragen.")
                .font(.caption)
        } header: { Text("Paperless-ngx") }
    }
}

struct PaperlessDocRow: View {
    let doc: PaperlessDoc

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PaperlessThumb(data: doc.thumbnail)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(doc.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if doc.inbox {
                        Image(systemName: "tray.full.fill").font(.caption2).foregroundStyle(.orange)
                            .accessibilityLabel("im Posteingang")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !doc.snippet.isEmpty {
                    Text(doc.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                PaperlessTagLine(tags: doc.tags, limit: 3)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let c = doc.created { parts.append(c.formatted(date: .abbreviated, time: .omitted)) }
        if !doc.correspondent.isEmpty { parts.append(doc.correspondent) }
        if !doc.type.isEmpty { parts.append(doc.type) }
        return parts.joined(separator: " · ")
    }
}

struct PaperlessThumb: View {
    let data: Data?

    var body: some View {
        if let d = data, let img = UIImage(data: d) {
            Image(uiImage: img)
                .resizable().scaledToFill()
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 0.5))
        } else {
            Image(systemName: "doc.text.fill")
                .font(.title2).foregroundStyle(.secondary)
                .frame(width: 48, height: 64)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct PaperlessTagLine: View {
    let tags: [PaperlessDocTag]
    var limit = 99

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(tags.prefix(limit)), id: \.self) { t in
                    Text(t.name)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(t.color.opacity(0.25), in: Capsule())
                }
                if tags.count > limit {
                    Text("+\(tags.count - limit)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Dokument ansehen

struct PaperlessDocView: View {
    @Environment(AppStore.self) private var store
    @State var doc: PaperlessDoc
    let meta: PaperlessMeta
    var changed: (PaperlessDoc) -> Void = { _ in }
    var deleted: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var data: Data?
    @State private var shareURL: URL?
    @State private var error: String?
    @State private var exporting = false
    @State private var editing = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let data, PDFDocument(data: data) != nil {
                    PDFPreview(data: data)
                } else if let error {
                    ContentUnavailableView("Nicht möglich", systemImage: "doc.questionmark", description: Text(error))
                } else {
                    ProgressView("Lade Dokument …").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            info
        }
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Einordnen") { editing = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("„\(doc.title)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Das Dokument kommt in den Papierkorb von Paperless und kann dort 30 Tage lang wiederhergestellt werden.")
        }
        .fileExporter(isPresented: $exporting, document: data.map { PDFFile(data: $0) },
                      contentType: .pdf, defaultFilename: doc.title) { _ in }
        .sheet(isPresented: $editing) {
            NavigationStack {
                PaperlessEditForm(doc: doc, meta: meta, header: nil) { saved in
                    doc = saved
                    changed(saved)
                    editing = false
                }
                .navigationTitle("Einordnen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { editing = false } } }
            }
        }
        .task { await load() }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let c = doc.created {
                    Label(c.formatted(date: .long, time: .omitted), systemImage: "calendar")
                }
                Spacer()
                if let p = doc.pages { Text("\(p) \(p == 1 ? "Seite" : "Seiten")").foregroundStyle(.secondary) }
            }
            .font(.caption)
            if !doc.correspondent.isEmpty || !doc.type.isEmpty {
                Label([doc.correspondent, doc.type].filter { !$0.isEmpty }.joined(separator: " · "), systemImage: "person.crop.rectangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) { PaperlessTagLine(tags: doc.tags) }
            HStack(spacing: 10) {
                if doc.inbox, let inbox = meta.inboxTag {
                    Button { Task { await done(inbox.id) } } label: {
                        Label("Erledigt", systemImage: "tray.and.arrow.down.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button { exporting = true } label: {
                    Label("Sichern", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(data == nil)
            }
        }
        .padding()
        .background(.bar)
    }

    private func remove() async {
        busy = true
        do {
            try await store.paperlessDelete(doc.id)
            deleted(doc.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    /// Posteingang-Tag entfernen
    private func done(_ inboxID: Int) async {
        busy = true
        var d = doc
        d.tagIDs.removeAll { $0 == inboxID }
        if let saved = try? await store.paperlessUpdate(d) {
            doc = saved
            changed(saved)
        }
        busy = false
    }

    private func load() async {
        guard data == nil else { return }
        do {
            let d = try await store.paperlessFile(doc.id)
            data = d
            let safe = doc.title.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe + ".pdf")
            try? d.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Einordnen: Titel, Datum, Absender, Art, Tags (auch neue anlegen)

struct PaperlessEditForm: View {
    @Environment(AppStore.self) private var store
    let original: PaperlessDoc
    @State private var meta: PaperlessMeta
    let header: String?
    let saved: (PaperlessDoc) -> Void

    @State private var title: String
    @State private var date: Date
    @State private var correspondent: Int?
    @State private var type: Int?
    @State private var tags: Set<Int>
    @State private var saving = false
    @State private var error: String?
    @State private var creating: String?          // "neu_tag" | "neu_korrespondent" | "neu_typ"
    @State private var newName = ""
    @State private var aiStatus = "aus"             // aus | laeuft | fertig | fehler
    @State private var aiSeconds = 0
    @State private var ai: PaperlessAISuggestion?
    @State private var aiError: String?
    @State private var applying = false

    init(doc: PaperlessDoc, meta: PaperlessMeta, header: String?, saved: @escaping (PaperlessDoc) -> Void) {
        original = doc
        _meta = State(initialValue: meta)
        self.header = header
        self.saved = saved
        _title = State(initialValue: doc.title)
        _date = State(initialValue: doc.created ?? Date())
        _correspondent = State(initialValue: doc.correspondentID)
        _type = State(initialValue: doc.typeID)
        _tags = State(initialValue: Set(doc.tagIDs))
    }

    private var inboxID: Int? { meta.inboxTag?.id }

    var body: some View {
        Form {
            if let header {
                Section { Text(header).font(.subheadline).foregroundStyle(.secondary) }
            }
            aiSection
            Section("Titel") {
                TextField("Titel", text: $title)
                DatePicker("Datum", selection: $date, displayedComponents: .date)
            }
            Section {
                Picker("Absender", selection: $correspondent) {
                    Text("–").tag(Int?.none)
                    ForEach(meta.correspondents) { c in Text(c.name).tag(Int?.some(c.id)) }
                }
                Button { startCreate("neu_korrespondent") } label: { Label("Neuer Absender", systemImage: "plus") }
                Picker("Art", selection: $type) {
                    Text("–").tag(Int?.none)
                    ForEach(meta.types) { c in Text(c.name).tag(Int?.some(c.id)) }
                }
                Button { startCreate("neu_typ") } label: { Label("Neue Dokumentart", systemImage: "plus") }
            } header: { Text("Zuordnung") }
            if inboxID != nil {
                Section {
                    Toggle("Im Posteingang", isOn: inboxBinding)
                } footer: {
                    Text("Aus – das Dokument ist fertig eingeordnet.")
                }
            }
            Section {
                ForEach(meta.tags.filter { !$0.inbox }) { t in
                    Button { toggle(t.id) } label: {
                        HStack {
                            Circle().fill(t.color).frame(width: 10, height: 10)
                            Text(t.name).foregroundStyle(.primary)
                            Spacer()
                            if tags.contains(t.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                }
                Button { startCreate("neu_tag") } label: { Label("Neuer Tag", systemImage: "plus") }
            } header: { Text("Tags") }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("Sichern") }
                }
                .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { await loadAI(restart: false) }
        .alert(createTitle, isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) { creating = nil }
            Button("Anlegen") { Task { await create() } }
        } message: {
            Text("Paperless lernt danach selbst, welche Dokumente dazugehören.")
        }
    }

    private var createTitle: String {
        switch creating {
        case "neu_korrespondent": return "Neuer Absender"
        case "neu_typ": return "Neue Dokumentart"
        default: return "Neuer Tag"
        }
    }

    private var inboxBinding: Binding<Bool> {
        Binding(get: { inboxID.map { tags.contains($0) } ?? false },
                set: { on in if let id = inboxID { if on { tags.insert(id) } else { tags.remove(id) } } })
    }

    private func toggle(_ id: Int) {
        if tags.contains(id) { tags.remove(id) } else { tags.insert(id) }
    }

    private func startCreate(_ kind: String) {
        newName = ""
        creating = kind
    }

    private func create() async {
        guard let kind = creating else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        creating = nil
        guard !name.isEmpty else { return }
        _ = await createItem(kind, name: name)
    }

    /// Absender / Art / Tag anlegen, in die Listen aufnehmen und gleich auswählen
    @discardableResult
    private func createItem(_ kind: String, name: String) async -> Int? {
        do {
            let id = try await store.paperlessCreate(kind, name: name)
            let item = PaperlessItem(id: id, name: name, count: 0)
            switch kind {
            case "neu_korrespondent":
                meta.correspondents.append(item)
                meta.correspondents.sort { $0.name.lowercased() < $1.name.lowercased() }
                correspondent = id
            case "neu_typ":
                meta.types.append(item)
                meta.types.sort { $0.name.lowercased() < $1.name.lowercased() }
                type = id
            default:
                meta.tags.append(PaperlessTag(id: id, name: name, color: .gray, inbox: false, count: 0))
                meta.tags.sort { $0.name.lowercased() < $1.name.lowercased() }
                tags.insert(id)
            }
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: KI-Vorschläge

    @ViewBuilder private var aiSection: some View {
        if aiStatus != "aus" {
        Section {
            switch aiStatus {
            case "laeuft":
                HStack(spacing: 10) {
                    ProgressView()
                    Text("KI liest das Dokument … \(aiSeconds) s").foregroundStyle(.secondary)
                }
            case "fertig":
                if let ai { aiContent(ai) }
            case "fehler":
                VStack(alignment: .leading, spacing: 6) {
                    Label(aiError ?? "KI nicht erreichbar", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
                    Button("Nochmal versuchen") { Task { await loadAI(restart: true) } }
                }
            default:
                EmptyView()
            }
        } header: {
            Label("KI-Vorschläge", systemImage: "sparkles")
        }
        }
    }

    @ViewBuilder private func aiContent(_ ai: PaperlessAISuggestion) -> some View {
        if !ai.title.isEmpty && ai.title != title {
            Button { title = ai.title } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Titel").font(.caption).foregroundStyle(.secondary)
                    Text(ai.title).foregroundStyle(.primary)
                }
            }
        }
        aiChips("Absender", ai.correspondents, kind: "neu_korrespondent") { $0 == correspondent }
        aiChips("Art", ai.types, kind: "neu_typ") { $0 == type }
        aiChips("Tags", ai.tags, kind: "neu_tag") { tags.contains($0) }
        Button {
            Task { await applyAll(ai) }
        } label: {
            HStack {
                if applying { ProgressView().padding(.trailing, 4) }
                Label("Alle Vorschläge übernehmen", systemImage: "wand.and.stars")
            }
        }
        .disabled(applying)
    }

    private func aiChips(_ label: String, _ items: [PaperlessAIItem], kind: String, selected: @escaping (Int) -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("kein Vorschlag").font(.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items, id: \.self) { it in
                            aiChip(it, kind: kind, isOn: it.id.map(selected) ?? false)
                        }
                    }
                }
            }
        }
    }

    private func aiChip(_ it: PaperlessAIItem, kind: String, isOn: Bool) -> some View {
        Button {
            Task { await apply(it, kind: kind) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : (it.id == nil ? "plus" : "arrow.down.circle"))
                    .font(.caption2.weight(.bold))
                Text(it.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(it.id == nil ? "\(it.name) neu anlegen und übernehmen" : "\(it.name) übernehmen")
    }

    /// Einen Vorschlag übernehmen (neue Einträge werden in Paperless angelegt)
    private func apply(_ it: PaperlessAIItem, kind: String) async {
        guard let id = it.id else {
            await createItem(kind, name: it.name)
            return
        }
        switch kind {
        case "neu_korrespondent": correspondent = id
        case "neu_typ": type = id
        default: if tags.contains(id) { tags.remove(id) } else { tags.insert(id) }
        }
    }

    private func applyAll(_ ai: PaperlessAISuggestion) async {
        applying = true
        if !ai.title.isEmpty { title = ai.title }
        if let c = ai.correspondents.first { await apply(c, kind: "neu_korrespondent") }
        if let t = ai.types.first { await apply(t, kind: "neu_typ") }
        for t in ai.tags {
            if let id = t.id { tags.insert(id) } else { await createItem("neu_tag", name: t.name) }
        }
        applying = false
    }

    private func loadAI(restart: Bool) async {
        aiError = nil
        var first = true
        for _ in 0..<120 {
            guard let r = try? await store.paperlessAI(original.id, restart: restart && first) else {
                if first { aiStatus = "aus" }          // KI nicht eingerichtet – Abschnitt ausblenden
                return
            }
            first = false
            aiStatus = r.status
            aiSeconds = r.seconds
            if r.status == "fertig" { ai = r.suggestion; return }
            if r.status == "fehler" {
                aiError = (r.error ?? "").contains("503") ? "Die KI hat nicht rechtzeitig geantwortet." : r.error
                return
            }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
        }
    }

    private func save() async {
        saving = true
        error = nil
        var d = original
        d.title = title.trimmingCharacters(in: .whitespaces)
        d.created = date
        d.correspondentID = correspondent
        d.typeID = type
        d.tagIDs = Array(tags).sorted()
        do {
            let result = try await store.paperlessUpdate(d)
            saved(result)
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

// MARK: - Scan an Paperless schicken

struct PaperlessUploadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let scan: ScanFile
    let done: (String) -> Void

    enum Phase { case loading, form, processing, review, failed }

    @State private var phase: Phase = .loading
    @State private var status: PaperlessStatus?
    @State private var meta = PaperlessMeta()
    @State private var title = ""
    @State private var tags: Set<Int> = []
    @State private var correspondent: Int?
    @State private var type: Int?
    @State private var sending = false
    @State private var error: String?
    @State private var newDoc: PaperlessDoc?
    @State private var info = ""
    @State private var confirmDelete = false

    private var apiReady: Bool { status?.ready == true }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(phase == .review ? "Eingeordnet" : "An Paperless")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(closeTitle) { dismiss() }
                    }
                    if phase == .review && newDoc != nil {
                        ToolbarItem(placement: .bottomBar) {
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Label("Dokument wieder löschen", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
                .confirmationDialog("Dokument in Paperless löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Löschen", role: .destructive) { Task { await removeNew() } }
                } message: {
                    Text("Es kommt in den Papierkorb von Paperless (30 Tage wiederherstellbar). Der Scan in der App bleibt erhalten.")
                }
        }
        .task { await prepare() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .form:
            form
        case .processing:
            VStack(spacing: 14) {
                ProgressView()
                Text("Paperless liest das Dokument …").font(.headline)
                Text("Texterkennung und automatische Zuordnung – dauert meist 10–30 Sekunden. Du kannst das Fenster auch schließen.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            if let d = newDoc {
                PaperlessEditForm(doc: d, meta: meta, header: "So hat Paperless das Dokument eingeordnet. Die KI-Vorschläge kommen gleich darunter – antippen übernimmt sie. Danach „Sichern“, oder „Passt so“.") { _ in
                    done("In Paperless eingeordnet.")
                    dismiss()
                }
            }
        case .failed:
            ContentUnavailableView("Nicht übernommen", systemImage: "exclamationmark.triangle",
                                   description: Text(error ?? "Paperless hat das Dokument abgelehnt."))
        }
    }

    private var form: some View {
        Form {
            if apiReady {
                Section("Titel") {
                    TextField("Titel", text: $title)
                }
                Section {
                    Picker("Absender", selection: $correspondent) {
                        Text("automatisch").tag(Int?.none)
                        ForEach(meta.correspondents) { c in Text(c.name).tag(Int?.some(c.id)) }
                    }
                    Picker("Art", selection: $type) {
                        Text("automatisch").tag(Int?.none)
                        ForEach(meta.types) { c in Text(c.name).tag(Int?.some(c.id)) }
                    }
                } header: { Text("Zuordnen") } footer: {
                    Text("„automatisch“ – Paperless entscheidet selbst. Danach siehst du das Ergebnis und kannst es korrigieren.")
                }
                Section("Tags") {
                    ForEach(meta.tags.filter { !$0.inbox }) { t in
                        Button { toggle(t.id) } label: {
                            HStack {
                                Circle().fill(t.color).frame(width: 10, height: 10)
                                Text(t.name).foregroundStyle(.primary)
                                Spacer()
                                if tags.contains(t.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("Die Paperless-Schnittstelle antwortet gerade nicht. Der Scan geht deshalb über die Netzwerkfreigabe – Paperless holt ihn sich von dort.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section {
                Button { Task { await send() } } label: {
                    HStack {
                        Spacer()
                        if sending { ProgressView().padding(.trailing, 6) }
                        Text("An Paperless senden").bold()
                        Spacer()
                    }
                }
                .disabled(sending)
            }
        }
    }

    private func removeNew() async {
        guard let d = newDoc else { return }
        do {
            try await store.paperlessDelete(d.id)
            store.sentScans.remove(scan.file)
            done("In Paperless wieder gelöscht.")
            dismiss()
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    private var closeTitle: String {
        switch phase {
        case .review: return "Passt so"
        case .processing, .failed: return "Schließen"
        default: return "Abbrechen"
        }
    }

    private func toggle(_ id: Int) {
        if tags.contains(id) { tags.remove(id) } else { tags.insert(id) }
    }

    private func prepare() async {
        guard phase == .loading else { return }
        title = scan.title
        status = await store.paperlessStatus()
        if apiReady, let m = try? await store.paperlessMeta() { meta = m }
        if apiReady {
            // gleich hochladen – Paperless ordnet selbst ein, danach nur noch prüfen und ggf. korrigieren
            phase = .processing
            await send()
            if phase == .processing && error != nil { phase = .failed }
        } else {
            phase = .form
        }
    }

    private func send() async {
        sending = true
        error = nil
        do {
            if apiReady {
                let task = try await store.uploadScanToPaperless(scan, title: title.trimmingCharacters(in: .whitespaces),
                                                                 tags: Array(tags), correspondent: correspondent, type: type)
                done("An Paperless geschickt.")
                phase = .processing
                await follow(task)
            } else {
                try await store.sendToPaperless(scan)
                done("Liegt jetzt in der Paperless-Freigabe auf dem NAS.")
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }

    /// Auf Paperless warten und dann zeigen, wie es eingeordnet wurde
    private func follow(_ task: String) async {
        guard !task.isEmpty else { dismiss(); return }
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            guard let t = try? await store.paperlessTask(task) else { continue }
            if t.status == "SUCCESS", let id = t.documentID {
                if let d = try? await store.paperlessDocument(id) {
                    newDoc = d
                    phase = .review
                    done("In Paperless übernommen.")
                } else {
                    dismiss()
                }
                return
            }
            if t.status == "FAILURE" {
                error = t.message.contains("duplicate") || t.message.contains("Duplikat")
                    ? "Dieses Dokument ist schon in Paperless."
                    : (t.message.isEmpty ? "Paperless hat das Dokument abgelehnt." : t.message)
                phase = .failed
                return
            }
        }
        done("An Paperless geschickt – wird noch verarbeitet.")
        dismiss()
    }
}
