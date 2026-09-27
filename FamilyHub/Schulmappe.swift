import SwiftUI
import PhotosUI
import VisionKit

// MARK: - Schulmappe
//
// Fotos von Klassenarbeiten, Elternbriefen, Zeugnissen … je Kind.
// todo.schulmappe: Titel = Name, Datum = Fälligkeitsdatum,
//   Beschreibung JSON {"kind":"emma","art":"klassenarbeit","bilder":["s….jpg"],"notiz":"Note 2+"}
// Die Fotos lädt das Scanner-Add-on nach /media/schulmappe (stückweise, siehe AppStore.uploadSchoolImage).
// Eltern verwalten alles, Kinder sehen ihre eigenen Dokumente.

enum SchoolDocKind: String, CaseIterable, Identifiable {
    case klassenarbeit, elternbrief, zeugnis, sonstiges
    var id: String { rawValue }
    var label: String {
        switch self {
        case .klassenarbeit: return "Klassenarbeit"
        case .elternbrief: return "Elternbrief"
        case .zeugnis: return "Zeugnis"
        case .sonstiges: return "Sonstiges"
        }
    }
    var plural: String {
        switch self {
        case .klassenarbeit: return "Klassenarbeiten"
        case .elternbrief: return "Elternbriefe"
        case .zeugnis: return "Zeugnisse"
        case .sonstiges: return "Sonstiges"
        }
    }
    var symbol: String {
        switch self {
        case .klassenarbeit: return "pencil.and.list.clipboard"
        case .elternbrief: return "envelope.fill"
        case .zeugnis: return "rosette"
        case .sonstiges: return "doc.fill"
        }
    }
    var color: Color {
        switch self {
        case .klassenarbeit: return .blue
        case .elternbrief: return .orange
        case .zeugnis: return .purple
        case .sonstiges: return .gray
        }
    }
    var titleHint: String {
        switch self {
        case .klassenarbeit: return "z. B. Mathe – Bruchrechnung"
        case .elternbrief: return "z. B. Wandertag Klasse 5"
        case .zeugnis: return "z. B. Halbjahreszeugnis 5. Klasse"
        case .sonstiges: return "Titel"
        }
    }
}

struct SchoolDoc: Identifiable, Hashable {
    let uid: String
    var title: String
    var kid: String
    var kind: SchoolDocKind
    var date: Date
    var files: [String]
    var note: String
    var id: String { uid }
    static func path(_ file: String) -> String { "/media/local/schulmappe/\(file)" }
}

@MainActor
extension AppStore {

    var canEditSchool: Bool { isParent && activeKid == nil }

    func refreshSchool() async {
        guard isLoggedIn else { return }
        do {
            let r = try await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.schoolDocsList,
                                                                           "status": ["needs_action", "completed"]])
            schoolDocs = (r[FamilyConfig.schoolDocsList]?["items"]?.array ?? []).compactMap { i in
                guard let uid = i["uid"]?.string, let title = i["summary"]?.string,
                      let cfg = ChoreText.json(i["description"]?.string) else { return nil }
                let date = HADate.day.date(from: String((i["due"]?.string ?? "").prefix(10))) ?? Date()
                return SchoolDoc(uid: uid, title: title, kid: cfg["kind"]?.string ?? "",
                                 kind: SchoolDocKind(rawValue: cfg["art"]?.string ?? "") ?? .sonstiges,
                                 date: date, files: cfg["bilder"]?.array?.compactMap(\.string) ?? [],
                                 note: cfg["notiz"]?.string ?? "")
            }
            .sorted { $0.date > $1.date }
        } catch { report(error) }
    }

    /// Sichtbare Dokumente: Kinder nur ihre eigenen
    func schoolDocs(kid: String?) -> [SchoolDoc] {
        let own = activeKid ?? kid
        return schoolDocs.filter { own == nil || $0.kid == own }
    }

    /// Foto verkleinern, als JPEG in Stücken über das Add-on hochladen, liefert den Dateinamen
    func uploadSchoolImage(_ image: UIImage, progress: (Double) -> Void) async throws -> String {
        let img = image.scaled(maxSide: 2000)
        guard let jpeg = img.jpegData(compressionQuality: 0.6) else { throw ScannerError(message: "Foto konnte nicht umgewandelt werden.") }
        let b64 = jpeg.base64EncodedString()
        let id = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let size = 180_000                    // Home Assistant erlaubt max. 256 KB pro Vorlage
        let total = max(1, (b64.count + size - 1) / size)
        var file: String?
        for idx in 0..<total {
            let start = b64.index(b64.startIndex, offsetBy: idx * size)
            let end = b64.index(start, offsetBy: min(size, b64.count - idx * size))
            let raw = try await client.callWithResponse("script", FamilyConfig.scannerScript,
                                                        ["aktion": "upload", "file": id, "idx": idx, "total": total,
                                                         "data": String(b64[start..<end])], timeout: 60)
            guard raw["ok"]?.string == "true" else {
                throw ScannerError(message: raw["error"]?.string ?? "Hochladen fehlgeschlagen.")
            }
            file = raw["file"]?.string ?? file
            progress(Double(idx + 1) / Double(total))
        }
        guard let file else { throw ScannerError(message: "Hochladen unvollständig.") }
        return file
    }

    private func schoolJSON(_ d: SchoolDoc) -> String {
        ChoreText.jsonString(["kind": d.kid, "art": d.kind.rawValue, "bilder": d.files, "notiz": d.note])
    }

    func saveSchoolDoc(_ d: SchoolDoc, isNew: Bool) async throws {
        guard canEditSchool else { return }
        if isNew {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.schoolDocsList, "item": d.title,
                                                       "due_date": HADate.day.string(from: d.date),
                                                       "description": schoolJSON(d)])
        } else {
            try await client.call("todo", "update_item", ["entity_id": FamilyConfig.schoolDocsList, "item": d.uid,
                                                          "rename": d.title, "due_date": HADate.day.string(from: d.date),
                                                          "description": schoolJSON(d)])
        }
        await refreshSchool()
    }

    func deleteSchoolDoc(_ d: SchoolDoc) async {
        guard canEditSchool else { return }
        schoolDocs.removeAll { $0.uid == d.uid }
        do {
            _ = try await client.callWithResponse("script", FamilyConfig.scannerScript, ["aktion": "schul_delete", "files": d.files])
            try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.schoolDocsList, "item": d.uid])
        } catch { report(error) }
    }
}

extension UIImage {
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let factor = maxSide / longest
        let newSize = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - Übersicht

struct SchoolDocsView: View {
    @Environment(AppStore.self) private var store
    @State private var kid: String
    @State private var adding = false

    init(kid: String? = nil) {
        _kid = State(initialValue: kid ?? FamilyConfig.kids.first?.id ?? "")
    }

    var body: some View {
        let docs = store.schoolDocs(kid: kid)
        List {
            if store.activeKid == nil && FamilyConfig.kids.count > 1 {
                Picker("Kind", selection: $kid) {
                    ForEach(FamilyConfig.kids) { k in Text(k.name).tag(k.id) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if docs.isEmpty {
                ContentUnavailableView("Noch leer", systemImage: "folder",
                                       description: Text(store.canEditSchool
                                                         ? "Mit + ein Dokument fotografieren – z. B. eine Klassenarbeit oder einen Elternbrief."
                                                         : "Hier erscheinen deine Klassenarbeiten, Elternbriefe und Zeugnisse."))
                    .listRowBackground(Color.clear)
            }
            ForEach(SchoolDocKind.allCases) { kind in
                let list = docs.filter { $0.kind == kind }
                if !list.isEmpty {
                    Section(kind.plural) {
                        ForEach(list) { d in
                            NavigationLink(value: d) { SchoolDocRow(doc: d) }
                        }
                        .onDelete(perform: store.canEditSchool ? { (idx: IndexSet) in
                            let del = idx.map { list[$0] }
                            Task { for d in del { await store.deleteSchoolDoc(d) } }
                        } : nil)
                    }
                }
            }
        }
        .navigationTitle("Schulmappe")
        .navigationDestination(for: SchoolDoc.self) { SchoolDocDetailView(doc: $0) }
        .toolbar {
            if store.canEditSchool {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $adding) { SchoolDocEditView(kid: kid) }
        .refreshable { await store.refreshSchool() }
        .task { await store.refreshSchool() }
        .onAppear { if let own = store.activeKid { kid = own } }
    }
}

struct SchoolDocRow: View {
    let doc: SchoolDoc

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let first = doc.files.first {
                    HAImage(path: SchoolDoc.path(first))
                } else {
                    Image(systemName: doc.kind.symbol).foregroundStyle(doc.kind.color)
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(doc.date.formatted(date: .abbreviated, time: .omitted))
                    if doc.files.count > 1 { Text("· \(doc.files.count) Seiten") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !doc.note.isEmpty {
                    Text(doc.note).font(.caption.weight(.semibold)).foregroundStyle(doc.kind.color)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Ansicht eines Dokuments

struct SchoolDocDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let doc: SchoolDoc
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var zoomed: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(doc.kind.label, systemImage: doc.kind.symbol)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(doc.kind.color)
                    Spacer()
                    Text(doc.date.formatted(date: .long, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                }
                if !doc.note.isEmpty {
                    Text(doc.note).font(.headline)
                }
                ForEach(Array(doc.files.enumerated()), id: \.offset) { i, f in
                    VStack(alignment: .leading, spacing: 4) {
                        if doc.files.count > 1 {
                            Text("Seite \(i + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        HAImage(path: SchoolDoc.path(f), contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture { zoomed = f }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.canEditSchool {
                Menu {
                    Button { editing = true } label: { Label("Bearbeiten", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editing) { SchoolDocEditView(existing: doc) }
        .fullScreenCover(item: Binding(get: { zoomed.map { ZoomTarget(file: $0) } }, set: { zoomed = $0?.file })) { t in
            ZoomImageView(path: SchoolDoc.path(t.file))
        }
        .confirmationDialog("Dokument löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task { await store.deleteSchoolDoc(doc); dismiss() }
            }
        }
    }
}

struct ZoomTarget: Identifiable {
    let file: String
    var id: String { file }
}

/// Seite im Vollbild mit Zoomen per zwei Finger
struct ZoomImageView: View {
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                HAImage(path: path, contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * scale * pinch)
                    .gesture(MagnifyGesture()
                        .updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { v in scale = min(5, max(1, scale * v.magnification)) })
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            }
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }
}

// MARK: - Anlegen / Bearbeiten (nur Eltern)

struct SchoolDocEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let existing: SchoolDoc?
    @State private var doc: SchoolDoc
    @State private var newPages: [UIImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var saving = false
    @State private var progress = ""
    @State private var error: String?

    init(kid: String) {
        existing = nil
        _doc = State(initialValue: SchoolDoc(uid: "", title: "", kid: kid, kind: .klassenarbeit, date: Date(), files: [], note: ""))
    }

    init(existing: SchoolDoc) {
        self.existing = existing
        _doc = State(initialValue: existing)
    }

    private var isNew: Bool { existing == nil }
    private var pageCount: Int { doc.files.count + newPages.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $doc.kid) {
                        ForEach(FamilyConfig.kids) { k in Text(k.name).tag(k.id) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Art", selection: $doc.kind) {
                        ForEach(SchoolDocKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                    }
                    TextField(doc.kind.titleHint, text: $doc.title)
                    DatePicker("Datum", selection: $doc.date, displayedComponents: .date)
                    TextField(doc.kind == .klassenarbeit ? "Note (optional), z. B. 2+" : "Notiz (optional)", text: $doc.note)
                }

                Section {
                    if pageCount > 0 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(doc.files.enumerated()), id: \.offset) { i, f in
                                    pageThumb { HAImage(path: SchoolDoc.path(f)) } remove: { doc.files.remove(at: i) }
                                }
                                ForEach(Array(newPages.enumerated()), id: \.offset) { i, img in
                                    pageThumb { Image(uiImage: img).resizable().scaledToFill() } remove: { newPages.remove(at: i) }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if VNDocumentCameraViewController.isSupported {
                        Button { showCamera = true } label: {
                            Label("Mit der Kamera fotografieren", systemImage: "camera.viewfinder")
                        }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Label("Aus Fotos auswählen", systemImage: "photo.on.rectangle")
                    }
                } header: {
                    Text(pageCount == 0 ? "Seiten" : "Seiten (\(pageCount))")
                } footer: {
                    Text("Die Kamera erkennt das Blatt, schneidet es zu und richtet es gerade aus. Mehrere Seiten nacheinander fotografieren.")
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(isNew ? "Neues Dokument" : "Dokument bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        HStack(spacing: 6) { ProgressView(); Text(progress).font(.caption) }
                    } else {
                        Button("Sichern", action: save)
                            .disabled(doc.title.trimmingCharacters(in: .whitespaces).isEmpty || pageCount == 0)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocumentCamera { images in newPages += images }.ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                            newPages.append(img)
                        }
                    }
                    pickerItems = []
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func pageThumb<V: View>(@ViewBuilder _ content: () -> V, remove: @escaping () -> Void) -> some View {
        content()
            .frame(width: 70, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(3)
                .disabled(saving)
            }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                var d = doc
                d.title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
                d.note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
                for (i, img) in newPages.enumerated() {
                    progress = "Seite \(i + 1)/\(newPages.count)"
                    let file = try await store.uploadSchoolImage(img) { _ in }
                    d.files.append(file)
                }
                try await store.saveSchoolDoc(d, isNew: isNew)
                // entfernte Seiten auch auf dem Server löschen
                if let existing {
                    let removed = existing.files.filter { !d.files.contains($0) }
                    if !removed.isEmpty {
                        _ = try? await store.client.callWithResponse("script", FamilyConfig.scannerScript,
                                                                    ["aktion": "schul_delete", "files": removed])
                    }
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

// MARK: - Dokumentenkamera des iPhones

struct DocumentCamera: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCamera
        init(_ parent: DocumentCamera) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}

// MARK: - Karte auf „Heute“

struct SchoolDocsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let docs = store.schoolDocs(kid: nil)
        if store.canEditSchool || !docs.isEmpty {
            NavigationLink { SchoolDocsView(kid: store.activeKid) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schulmappe").font(.headline).foregroundStyle(.primary)
                        Text(docs.first.map { "Zuletzt: \($0.title)" } ?? "Klassenarbeiten, Elternbriefe, Zeugnisse")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }
}
