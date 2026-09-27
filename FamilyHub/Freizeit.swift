import SwiftUI

// MARK: - Freizeitaktivitäten
//
// todo.freizeit: Aktivität = Name, Beschreibung JSON {"kind":"emma","tag":0,"von":"16:00","bis":"17:30","ort":"…"}
// Tag 0 = Montag … 6 = Sonntag. Bearbeiten dürfen nur Eltern, Kinder sehen ihre eigenen Termine.

struct Activity: Identifiable, Hashable {
    let uid: String
    var title: String
    var kid: String
    var day: Int
    var start: String
    var end: String
    var place: String
    var id: String { uid }
    var timeText: String { end.isEmpty ? start : "\(start)–\(end)" }
    var kidName: String { FamilyConfig.kid(kid)?.name ?? kid }
    var kidColor: Color { FamilyConfig.kid(kid)?.color ?? .gray }
}

@MainActor
extension AppStore {

    var canEditFreizeit: Bool { isParent && activeKid == nil }

    func refreshFreizeit() async {
        guard isLoggedIn else { return }
        do {
            let r = try await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.freizeitList,
                                                                           "status": ["needs_action", "completed"]])
            activities = (r[FamilyConfig.freizeitList]?["items"]?.array ?? []).compactMap { i in
                guard let uid = i["uid"]?.string, let title = i["summary"]?.string,
                      let cfg = ChoreText.json(i["description"]?.string) else { return nil }
                return Activity(uid: uid, title: title, kid: cfg["kind"]?.string ?? "", day: cfg["tag"]?.int ?? 0,
                                start: cfg["von"]?.string ?? "", end: cfg["bis"]?.string ?? "",
                                place: cfg["ort"]?.string ?? "")
            }
            .sorted { ($0.day, $0.start, $0.kid) < ($1.day, $1.start, $1.kid) }
        } catch { report(error) }
    }

    /// Termine eines Kindes an einem Wochentag, nach Uhrzeit
    func activities(kid: String, day: Int) -> [Activity] {
        activities.filter { $0.kid == kid && $0.day == day }.sorted { $0.start < $1.start }
    }

    private func activityJSON(_ a: Activity) -> String {
        ChoreText.jsonString(["kind": a.kid, "tag": a.day, "von": a.start, "bis": a.end, "ort": a.place])
    }

    /// Liefert nil bei Erfolg, sonst eine Fehlermeldung für die Anzeige
    func saveActivity(_ a: Activity, isNew: Bool) async -> String? {
        guard canEditFreizeit else {
            return isParent ? "Du siehst die App gerade als Kind (Einstellungen → „Aufgaben ansehen als“)."
                            : "Nur Eltern können Freizeit eintragen (Rolle nicht erkannt)."
        }
        do {
            if isNew {
                try await client.call("todo", "add_item", ["entity_id": FamilyConfig.freizeitList, "item": a.title,
                                                           "description": activityJSON(a)])
            } else {
                try await client.call("todo", "update_item", ["entity_id": FamilyConfig.freizeitList, "item": a.uid,
                                                              "rename": a.title, "description": activityJSON(a)])
            }
        } catch {
            return "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
        await refreshFreizeit()
        if isNew && !activities.contains(where: { $0.title == a.title && $0.kid == a.kid && $0.day == a.day }) {
            return "Gespeichert, aber beim Neuladen nicht gefunden. Bitte nach unten ziehen zum Aktualisieren."
        }
        return nil
    }

    func deleteActivity(_ a: Activity) async {
        guard canEditFreizeit else { return }
        activities.removeAll { $0.uid == a.uid }
        do { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.freizeitList, "item": a.uid]) }
        catch { report(error) }
    }
}

// MARK: - Verwaltung (nur Eltern)

struct FreizeitManageView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Activity?
    @State private var isNew = false

    var body: some View {
        List {
            ForEach(FamilyConfig.kids) { kid in
                let list = store.activities.filter { $0.kid == kid.id }
                Section {
                    if list.isEmpty {
                        Text("Noch nichts eingetragen").foregroundStyle(.secondary)
                    }
                    ForEach(list) { a in
                        Button { isNew = false; editing = a } label: { ActivityRow(activity: a, showDay: true) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        let del = idx.map { list[$0] }
                        Task { for a in del { await store.deleteActivity(a) } }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(kid.color).frame(width: 8, height: 8)
                        Text(kid.name)
                    }
                }
            }
        }
        .navigationTitle("Freizeit")
        .toolbar {
            Button {
                isNew = true
                editing = Activity(uid: "", title: "", kid: FamilyConfig.kids.first?.id ?? "",
                                   day: min(ChoreText.todayIndex, 6), start: "16:00", end: "17:00", place: "")
            } label: { Image(systemName: "plus") }
        }
        .sheet(item: $editing) { a in ActivityEditView(activity: a, isNew: isNew) }
        .refreshable { await store.refreshFreizeit() }
    }
}

struct ActivityRow: View {
    let activity: Activity
    var showDay = false
    var showKid = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                if showDay {
                    Text(ChoreText.dayNames[activity.day]).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                Text(activity.start).font(.subheadline.monospacedDigit().weight(.semibold))
                if !activity.end.isEmpty {
                    Text(activity.end).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(activity.kidColor).frame(width: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(showKid ? "\(activity.kidName): \(activity.title)" : activity.title).font(.body.weight(.medium))
                if !activity.place.isEmpty {
                    Label(activity.place, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ActivityEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var activity: Activity
    let isNew: Bool
    @State private var from = Date()
    @State private var to = Date()
    @State private var hasEnd = true
    @State private var saving = false
    @State private var saveError: String?

    private static let suggestions = ["Turnen", "Fußball", "Basketball", "Schwimmen", "Tanzen", "Musikschule", "Reiten", "Handball"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $activity.kid) {
                        ForEach(FamilyConfig.kids) { k in Text(k.name).tag(k.id) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Aktivität (z. B. Turnen)", text: $activity.title)
                    if activity.title.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Self.suggestions, id: \.self) { s in
                                    Button(s) { activity.title = s }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                }
                Section("Wann") {
                    Picker("Tag", selection: $activity.day) {
                        ForEach(0..<7, id: \.self) { d in Text(Timetables.dayNamesLong[d]).tag(d) }
                    }
                    DatePicker("Beginn", selection: $from, displayedComponents: .hourAndMinute)
                    Toggle("Ende angeben", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Ende", selection: $to, displayedComponents: .hourAndMinute)
                    }
                }
                Section("Wo (optional)") {
                    TextField("z. B. Sporthalle Nord", text: $activity.place)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.footnote)
                }
                if !isNew {
                    Section {
                        Button("Löschen", role: .destructive) {
                            Task { await store.deleteActivity(activity); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Neue Aktivität" : "Aktivität")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Sichern") {
                            var a = activity
                            a.title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            a.place = a.place.trimmingCharacters(in: .whitespacesAndNewlines)
                            a.start = Self.hm(from)
                            a.end = hasEnd ? Self.hm(to) : ""
                            saving = true
                            saveError = nil
                            Task {
                                let err = await store.saveActivity(a, isNew: isNew)
                                saving = false
                                if let err { saveError = err } else { dismiss() }
                            }
                        }
                        .disabled(activity.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                from = Self.date(activity.start) ?? from
                to = Self.date(activity.end) ?? from.addingTimeInterval(3600)
                hasEnd = !activity.end.isEmpty || isNew
            }
        }
    }

    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func date(_ s: String) -> Date? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date())
    }
}

// MARK: - Karte auf „Heute“

struct FreizeitTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let today = ChoreText.todayIndex
        let kids = FamilyConfig.kids.filter { store.activeKid == nil || store.activeKid == $0.id }
        let list = kids.flatMap { store.activities(kid: $0.id, day: today) }.sorted { $0.start < $1.start }
        if !list.isEmpty {
            NavigationLink {
                TimetableView(kid: store.activeKid ?? list.first?.kid)
            } label: {
                Card(title: "Freizeit heute", symbol: "figure.run") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(list) { a in
                            HStack {
                                Circle().fill(a.kidColor).frame(width: 10, height: 10)
                                Text(store.activeKid == nil ? "\(a.kidName): \(a.title)" : a.title)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(a.timeText).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
