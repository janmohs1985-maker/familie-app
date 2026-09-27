import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Modell

struct ScanFile: Identifiable, Hashable {
    let file: String          // z. B. "2026-09-27_15-20-01_Rechnung.pdf"
    let size: Int
    let time: Date
    var id: String { file }

    /// Anzeigename ohne Datums-Präfix und Endung
    var title: String {
        var n = file
        if n.hasSuffix(".pdf") { n.removeLast(4) }
        if n.count > 20, n.prefix(4).allSatisfy(\.isNumber) { n = String(n.dropFirst(20)) }
        return n.isEmpty ? "Scan" : n
    }
    var path: String { "/media/local/scans/" + (file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

enum ScanMode: String, CaseIterable, Identifiable {
    case color = "Color", gray = "Grayscale", mono = "Monochrome"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: return "Farbe"
        case .gray: return "Graustufen"
        case .mono: return "S/W"
        }
    }
}

struct ScannerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Store

extension AppStore {
    /// Scannen dürfen nur Eltern
    var canScan: Bool { isParent }

    private func scanner(_ aktion: String, _ extra: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> JSONValue {
        var data = extra
        data["aktion"] = aktion
        let r = try await client.callWithResponse("script", FamilyConfig.scannerScript, data, timeout: timeout)
        guard r["ok"]?.string == "true" else {
            var msg = r["error"]?.string ?? "Unbekannter Fehler vom Scanner."
            if msg.contains("device I/O") || msg.contains("No route") {
                msg = "Scanner nicht erreichbar. Ist der ES-60W eingeschaltet und im WLAN? (Er schaltet sich nach einiger Zeit selbst aus.)"
            }
            throw ScannerError(message: msg)
        }
        return r
    }

    func refreshScans() async {
        guard canScan else { return }
        do {
            let r = try await scanner("list")
            scans = (r["files"]?.array ?? []).compactMap { f in
                guard let name = f["file"]?.string else { return nil }
                return ScanFile(file: name, size: f["size"]?.int ?? 0,
                                time: Date(timeIntervalSince1970: f["time"]?.double ?? 0))
            }
        } catch { report(error) }
    }

    /// Startet einen Scan am Epson und liefert die neue PDF-Datei
    func scan(name: String, mode: ScanMode, resolution: Int) async throws -> ScanFile {
        scanning = true
        defer { scanning = false }
        let r = try await scanner("scan", ["name": name, "mode": mode.rawValue, "resolution": resolution], timeout: 330)
        guard let file = r["file"]?.string else { throw ScannerError(message: "Scan ohne Ergebnis.") }
        await refreshScans()
        return scans.first { $0.file == file } ?? ScanFile(file: file, size: 0, time: Date())
    }

    func sendToPaperless(_ scan: ScanFile) async throws {
        _ = try await scanner("send", ["file": scan.file], timeout: 130)
        sentScans.insert(scan.file)
    }

    func deleteScan(_ scan: ScanFile) async {
        do {
            _ = try await scanner("delete", ["file": scan.file])
            scans.removeAll { $0.file == scan.file }
            scanCache[scan.file] = nil
        } catch { report(error) }
    }

    func renameScan(_ scan: ScanFile, to name: String) async throws -> ScanFile {
        let r = try await scanner("rename", ["file": scan.file, "name": name])
        let new = r["file"]?.string ?? scan.file
        if let d = scanCache[scan.file] { scanCache[new] = d; scanCache[scan.file] = nil }
        if sentScans.remove(scan.file) != nil { sentScans.insert(new) }
        await refreshScans()
        return scans.first { $0.file == new } ?? ScanFile(file: new, size: scan.size, time: scan.time)
    }

    func pdfData(_ scan: ScanFile) async throws -> Data {
        if let d = scanCache[scan.file] { return d }
        let d = try await client.download(path: scan.path)
        scanCache[scan.file] = d
        return d
    }
}

// MARK: - Liste & neuer Scan

struct DocumentsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("scanMode") private var modeRaw = ScanMode.color.rawValue
    @AppStorage("scanResolution") private var resolution = 300
    @State private var name = ""
    @State private var error: String?
    @State private var opened: ScanFile?

    private var mode: Binding<ScanMode> {
        Binding(get: { ScanMode(rawValue: modeRaw) ?? .color }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        List {
            Section {
                TextField("Name (z. B. Rechnung Strom)", text: $name)
                    .textInputAutocapitalization(.sentences)
                Picker("Farbe", selection: mode) {
                    ForEach(ScanMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                Picker("Auflösung", selection: $resolution) {
                    Text("150 dpi").tag(150)
                    Text("300 dpi").tag(300)
                    Text("600 dpi").tag(600)
                }
                Button(action: startScan) {
                    HStack {
                        Spacer()
                        if store.scanning {
                            ProgressView().padding(.trailing, 6)
                            Text("Scanne …")
                        } else {
                            Label("Scannen", systemImage: "scanner")
                        }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(store.scanning)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Neuer Scan · Epson ES-60W")
            } footer: {
                Text("Blatt mit der Vorderseite nach oben einschieben, bis der Scanner es leicht anzieht. Mehrere Seiten nacheinander nachlegen – alles landet in einer PDF.")
            }

            Section("Gescannte Dokumente") {
                if store.scans.isEmpty {
                    Text("Noch keine Scans").foregroundStyle(.secondary)
                }
                ForEach(store.scans) { s in
                    NavigationLink(value: s) { ScanRow(scan: s, sent: store.sentScans.contains(s.file)) }
                }
                .onDelete { idx in
                    let list = idx.map { store.scans[$0] }
                    Task { for s in list { await store.deleteScan(s) } }
                }
            }
        }
        .navigationTitle("Dokumente")
        .navigationDestination(for: ScanFile.self) { ScanDetailView(scan: $0) }
        .navigationDestination(item: $opened) { ScanDetailView(scan: $0) }
        .refreshable { await store.refreshScans() }
        .task { await store.refreshScans() }
    }

    private func startScan() {
        error = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let s = try await store.scan(name: n.isEmpty ? "Scan" : n, mode: mode.wrappedValue, resolution: resolution)
                name = ""
                opened = s
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ScanRow: View {
    let scan: ScanFile
    let sent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext.fill").font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(scan.time.formatted(date: .abbreviated, time: .shortened)) · \(scan.sizeText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if sent {
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
            }
        }
    }
}

// MARK: - Vorschau & Aktionen

struct ScanDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var scan: ScanFile
    @State private var data: Data?
    @State private var shareURL: URL?
    @State private var loadError: String?
    @State private var exporting = false
    @State private var sending = false
    @State private var message: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var sent: Bool { store.sentScans.contains(scan.file) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let data {
                    PDFPreview(data: data)
                } else if let loadError {
                    ContentUnavailableView("Vorschau nicht möglich", systemImage: "doc.questionmark",
                                           description: Text(loadError))
                } else {
                    ProgressView("Lade Vorschau …").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))

            actionBar
        }
        .navigationTitle(scan.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { newName = scan.title; renaming = true } label: { Label("Umbenennen", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .task(id: scan.file) { await load() }
        .fileExporter(isPresented: $exporting, document: data.map { PDFFile(data: $0) },
                      contentType: .pdf, defaultFilename: scan.title) { result in
            if case .success = result { message = "In „Dateien“ gespeichert." }
        }
        .alert("Umbenennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                Task {
                    do { scan = try await store.renameScan(scan, to: newName) }
                    catch { message = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Scan löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task { await store.deleteScan(scan); dismiss() }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button { exporting = true } label: {
                    Label("Auf iPhone", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(data == nil)

                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {} label: { Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).disabled(true)
                }
            }
            Button(action: send) {
                HStack {
                    if sending { ProgressView().tint(.white) }
                    Label(sent ? "An Paperless gesendet" : "An Paperless senden",
                          systemImage: sent ? "checkmark.circle.fill" : "externaldrive.connected.to.line.below")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(sent ? Color.green : Color.accentColor)
            .disabled(sending)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private func load() async {
        loadError = nil
        do {
            let d = try await store.pdfData(scan)
            data = d
            // Kopie mit sprechendem Namen für „Teilen“
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(scan.title + ".pdf")
            try? d.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func send() {
        sending = true
        message = nil
        Task {
            do {
                try await store.sendToPaperless(scan)
                message = "Liegt jetzt in der Paperless-Freigabe auf dem NAS."
            } catch {
                message = error.localizedDescription
            }
            sending = false
        }
    }
}

struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.document = PDFDocument(data: data)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if v.document == nil { v.document = PDFDocument(data: data) }
    }
}

struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - Karte auf „Heute“

struct ScanCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.canScan {
            NavigationLink { DocumentsView() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "scanner.fill")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dokument scannen").font(.headline).foregroundStyle(.primary)
                        Text(store.scanning ? "Scan läuft …" : "Vorschau, speichern, an Paperless senden")
                            .font(.caption).foregroundStyle(.secondary)
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
