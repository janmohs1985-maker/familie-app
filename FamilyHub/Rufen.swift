import SwiftUI

// MARK: - „Essen ist fertig!“ – alle zu Hause rufen
//
// Family Hub schickt allen, die gerade zu Hause sind, eine Mitteilung (lange drücken: „Komme!“, „5 Minuten“,
// eigene Antwort) und zeigt den Text als Lauftext auf der Awtrix-Uhr. Antworten kommen beim Rufer an.

struct CallAnswer: Identifiable, Hashable {
    let person: String
    let text: String
    var id: String { person }
}

struct CallStatus {
    var id: String
    var text: String
    var recipients: [String]
    var answers: [String: String]
}

enum CallBridge {
    static func client() -> HAClient {
        HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
    }
    static var token: String { UserDefaults.standard.string(forKey: "pushToken") ?? "" }

    static func send(_ data: [String: Any]) async throws -> JSONValue {
        var d = data
        d["token"] = token
        let r = try await client().callWithResponse("rest_command", "familie_rufen", ["daten": d], timeout: 45)
        let c = r["content"] ?? r
        if c["ok"]?.string != "true" { throw HAError.unexpected(c["error"]?.string ?? "Family Hub nicht erreichbar") }
        return c
    }

    /// Antwort aus der Mitteilung (App läuft evtl. nur im Hintergrund)
    static func answer(id: String, text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !t.isEmpty else { return }
        _ = try? await send(["aktion": "antwort", "id": id, "antwort": t])
    }

    static func status(_ id: String) async -> CallStatus? {
        guard let c = try? await send(["aktion": "status", "id": id]), let r = c["ruf"], r["id"]?.string != nil else { return nil }
        var answers: [String: String] = [:]
        if case .object(let o)? = r["antworten"] {
            for (k, v) in o { answers[k] = v["text"]?.string ?? "" }
        }
        return CallStatus(id: r["id"]?.string ?? id, text: r["text"]?.string ?? "",
                          recipients: (r["an"]?.array ?? []).compactMap(\.string), answers: answers)
    }
}

struct CallButton: View {
    @State private var show = false
    var body: some View {
        Button { show = true } label: { Image(systemName: "megaphone.fill") }
            .accessibilityLabel("Alle rufen")
            .sheet(isPresented: $show) { CallSheet().presentationDetents([.medium, .large]) }
    }
}

struct CallSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var everyone = false
    @State private var sending = false
    @State private var error: String?
    @State private var status: CallStatus?

    private let presets: [(String, String)] = [
        ("🍽", "Essen ist fertig!"),
        ("🚗", "Abfahrt in 10 Minuten!"),
        ("👋", "Kommt bitte mal runter!"),
        ("🪥", "Zähne putzen und ab ins Bett!"),
    ]

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    statusSection(status)
                } else {
                    Section {
                        ForEach(presets, id: \.1) { p in
                            Button { Task { await call(p.1) } } label: {
                                HStack(spacing: 12) {
                                    Text(p.0).font(.title2)
                                    Text(p.1).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "paperplane.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .disabled(sending)
                        }
                    } footer: {
                        Text(everyone ? "Geht an alle." : "Geht an alle, die gerade zu Hause sind – auf die Handys und die Awtrix-Uhr.")
                    }
                    Section {
                        HStack {
                            TextField("Eigener Text …", text: $custom)
                                .submitLabel(.send)
                                .onSubmit { Task { await call(custom) } }
                            Button { Task { await call(custom) } } label: { Image(systemName: "paperplane.fill") }
                                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                        }
                        Toggle("Auch wer unterwegs ist", isOn: $everyone)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle(status == nil ? "Alle rufen" : "Gerufen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .task(id: status?.id) { await poll() }
        }
    }

    @ViewBuilder private func statusSection(_ s: CallStatus) -> some View {
        Section {
            Text(s.text).font(.title3.weight(.bold))
            if s.recipients.isEmpty {
                Text("Gerade ist sonst niemand zu Hause.").foregroundStyle(.secondary)
            }
            ForEach(s.recipients, id: \.self) { p in
                HStack(spacing: 12) {
                    let person = FamilyConfig.parent(p)?.person ?? FamilyConfig.kid(p)?.person ?? ""
                    let info = FamilyConfig.people.first { $0.id == person }
                    Avatar(image: store.pictures[person], name: info?.name ?? p, color: info?.color ?? .gray,
                           initialFont: .headline, ring: 0)
                        .frame(width: 34, height: 34)
                    Text(info?.name ?? p.capitalized).font(.body.weight(.medium))
                    Spacer()
                    if let a = s.answers[p] {
                        Text(a).font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    } else {
                        Text("noch keine Antwort").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Antworten kommen hier und als Mitteilung an.")
        }
        Section {
            Button("Nochmal rufen") { Task { await call(s.text) } }
        }
    }

    private func call(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            let c = try await CallBridge.send(["text": t, "alle": everyone])
            status = CallStatus(id: c["id"]?.string ?? "", text: t,
                                recipients: (c["an"]?.array ?? []).compactMap(\.string), answers: [:])
            custom = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Antworten nachladen, solange das Blatt offen ist
    private func poll() async {
        guard let id = status?.id, !id.isEmpty else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if let s = await CallBridge.status(id) { status?.answers = s.answers }
        }
    }
}
