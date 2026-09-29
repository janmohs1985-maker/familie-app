import SwiftUI

// MARK: - Klassenarbeiten (Proben, Schulaufgaben, Exen, Tests …)
//
// Gespeichert in Home Assistant (Family Hub → /homeassistant/familie_klassenarbeiten.json):
// Lesen über script.familie_klassenarbeiten, Schreiben über rest_command.familie_klassenarbeit_set.

struct Exam: Identifiable, Hashable {
    var id: String
    var kid: String
    var subject: String
    var kind: String
    var day: String          // yyyy-MM-dd
    var topic: String
    var grade: String
    var prepared: Bool
    var by: String

    var date: Date { HADate.day.date(from: day) ?? Date.distantPast }

    /// Tage bis zur Arbeit (0 = heute, negativ = vorbei)
    var daysLeft: Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }
    var upcoming: Bool { daysLeft >= 0 }

    var title: String { kind.isEmpty ? subject : "\(subject) · \(kind)" }
}

enum ExamConfig {
    static let kinds = ["Probe", "Schulaufgabe", "Ex", "Kurzarbeit", "Test", "Referat", "Abfrage"]
    static let grades = ["1", "1-", "2+", "2", "2-", "3+", "3", "3-", "4+", "4", "4-", "5+", "5", "5-", "6"]

    /// Fächer aus dem Stundenplan (ohne Pause, „Deutsch / Sport (14-tägig)“ aufgeteilt)
    static func subjects(kid: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for day in Timetables.plan(for: kid) {
            for l in day where !l.isBreak {
                let clean = l.subject.replacingOccurrences(of: "(14-tägig)", with: "").trimmingCharacters(in: .whitespaces)
                let parts: [String] = clean.contains("Religion") ? [clean] : clean.components(separatedBy: " / ")
                for p in parts {
                    let s = p.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty, s != "Förder", s != "Flex", seen.insert(s).inserted { out.append(s) }
                }
            }
        }
        return out.isEmpty ? ["Deutsch", "Mathe", "Englisch", "HSU"] : out
    }

    /// Note als Zahl für den Durchschnitt (2+ = 1,75 · 2- = 2,25)
    static func value(_ grade: String) -> Double? {
        guard let first = grade.first, let base = Double(String(first)) else { return nil }
        if grade.hasSuffix("+") { return base - 0.25 }
        if grade.hasSuffix("-") { return base + 0.25 }
        return base
    }

    static func countdown(_ days: Int) -> String {
        switch days {
        case 0: return "heute"
        case 1: return "morgen"
        case 2...13: return "in \(days) Tagen"
        default: return days < 0 ? "vorbei" : "in \(days / 7) Wochen"
        }
    }

    static func urgency(_ days: Int) -> Color {
        if days <= 2 { return .red }
        if days <= 7 { return .orange }
        return .secondary
    }
}

@MainActor @Observable
final class ExamsModel {
    static let shared = ExamsModel()
    var items: [Exam] = []
    var loaded = false
    var loading = false

    func exams(kid: String) -> [Exam] { items.filter { $0.kid == kid } }
    func upcoming(kid: String) -> [Exam] {
        exams(kid: kid).filter(\.upcoming).sorted { $0.day < $1.day }
    }
    func past(kid: String) -> [Exam] {
        exams(kid: kid).filter { !$0.upcoming }.sorted { $0.day > $1.day }
    }

    func load(_ store: AppStore) async {
        loading = true
        defer { loading = false }
        guard let r = try? await store.client.callWithResponse("script", "familie_klassenarbeiten", [:], timeout: 30) else { return }
        let c = r["content"] ?? r
        let list: [Exam] = (c["arbeiten"]?.array ?? []).compactMap { a in
            guard let id = a["id"]?.string, let kid = a["kind"]?.string, let day = a["datum"]?.string else { return nil }
            return Exam(id: id, kid: kid, subject: a["fach"]?.string ?? "", kind: a["art"]?.string ?? "",
                        day: day, topic: a["thema"]?.string ?? "", grade: a["note"]?.string ?? "",
                        prepared: a["gelernt"]?.string == "true", by: a["von"]?.string ?? "")
        }
        items = list
        loaded = true
    }

    func save(_ e: Exam, store: AppStore) async {
        let data: [String: Any] = [
            "id": e.id, "kind": e.kid, "fach": e.subject, "art": e.kind, "datum": e.day,
            "thema": e.topic, "note": e.grade, "gelernt": e.prepared ? "true" : "false", "von": e.by,
        ]
        // sofort anzeigen, dann speichern
        if let i = items.firstIndex(where: { $0.id == e.id }) { items[i] = e } else { items.append(e) }
        do {
            try await store.client.call("rest_command", "familie_klassenarbeit_set", ["daten": data])
        } catch { store.report(error) }
        await load(store)
    }

    func delete(_ e: Exam, store: AppStore) async {
        items.removeAll { $0.id == e.id }
        do {
            try await store.client.call("rest_command", "familie_klassenarbeit_set", ["daten": ["id": e.id, "aktion": "loeschen"]])
        } catch { store.report(error) }
        await load(store)
    }
}

// MARK: - Karte in „Schule & Kinder“ beim Kind

struct ExamsCard: View {
    @Environment(AppStore.self) private var store
    let kid: FamilyConfig.Kid
    @State private var model = ExamsModel.shared
    @State private var adding = false

    var body: some View {
        let next: [Exam] = Array(model.upcoming(kid: kid.id).prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Klassenarbeiten", systemImage: "pencil.and.list.clipboard").font(.headline)
                Spacer()
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.subheadline.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Klassenarbeit eintragen")
            }
            if next.isEmpty {
                Text(model.loaded ? "Keine Arbeiten geplant" : "Wird geladen …")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(next) { e in ExamRow(exam: e, compact: true) }
            }
            NavigationLink { ExamsView(kid: kid) } label: {
                HStack {
                    Text("Alle Arbeiten & Noten").font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $adding) { ExamEditView(kid: kid, exam: nil) }
        .task { if !model.loaded { await model.load(store) } }
    }
}

/// Eine Zeile: Datum-Kachel, Fach und Art, Thema, Countdown bzw. Note
struct ExamRow: View {
    let exam: Exam
    var compact = false

    var body: some View {
        let color: Color = Timetables.color(exam.subject)
        let days: Int = exam.daysLeft
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(exam.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.semibold))
                Text(exam.date.formatted(.dateTime.day())).font(.title3.weight(.bold).monospacedDigit())
                Text(exam.date.formatted(.dateTime.month(.abbreviated))).font(.caption2)
            }
            .foregroundStyle(color)
            .frame(width: 48, height: 56)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(exam.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !exam.topic.isEmpty {
                    Text(exam.topic).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                }
                if exam.upcoming && exam.prepared {
                    Label("gelernt", systemImage: "checkmark.seal.fill").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 4)
            if exam.upcoming {
                Text(ExamConfig.countdown(days))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ExamConfig.urgency(days))
            } else if !exam.grade.isEmpty {
                Text(exam.grade)
                    .font(.title3.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(GradeColor.of(exam.grade).opacity(0.18), in: Circle())
                    .foregroundStyle(GradeColor.of(exam.grade))
            } else {
                Text("Note?").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }
}

enum GradeColor {
    static func of(_ grade: String) -> Color {
        guard let v = ExamConfig.value(grade) else { return .secondary }
        if v < 2.5 { return .green }
        if v < 3.5 { return .teal }
        if v < 4.5 { return .orange }
        return .red
    }
}

// MARK: - Alle Arbeiten eines Kindes

struct ExamsView: View {
    @Environment(AppStore.self) private var store
    let kid: FamilyConfig.Kid
    @State private var model = ExamsModel.shared
    @State private var adding = false
    @State private var editing: Exam?

    var body: some View {
        let upcoming: [Exam] = model.upcoming(kid: kid.id)
        let past: [Exam] = model.past(kid: kid.id)
        List {
            Section("Anstehend") {
                if upcoming.isEmpty {
                    Text("Nichts geplant").foregroundStyle(.secondary)
                }
                ForEach(upcoming) { e in
                    Button { editing = e } label: { ExamRow(exam: e) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) { preparedButton(e) }
                        .swipeActions(edge: .trailing) { deleteButton(e) }
                }
            }
            if !past.isEmpty {
                averagesSection(past)
                Section("Vorbei") {
                    ForEach(past) { e in
                        Button { editing = e } label: { ExamRow(exam: e) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) { deleteButton(e) }
                    }
                }
            }
        }
        .navigationTitle("Arbeiten · \(kid.name)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Klassenarbeit eintragen")
            }
        }
        .refreshable { await model.load(store) }
        .task { await model.load(store) }
        .sheet(isPresented: $adding) { ExamEditView(kid: kid, exam: nil) }
        .sheet(item: $editing) { e in ExamEditView(kid: kid, exam: e) }
    }

    private func preparedButton(_ e: Exam) -> some View {
        Button {
            var x = e
            x.prepared.toggle()
            Task { await model.save(x, store: store) }
        } label: {
            Label(e.prepared ? "Nicht gelernt" : "Gelernt", systemImage: "checkmark.seal")
        }
        .tint(.green)
    }

    private func deleteButton(_ e: Exam) -> some View {
        Button(role: .destructive) {
            Task { await model.delete(e, store: store) }
        } label: {
            Label("Löschen", systemImage: "trash")
        }
    }

    /// Notenschnitt je Fach
    private func averagesSection(_ past: [Exam]) -> some View {
        let graded: [Exam] = past.filter { ExamConfig.value($0.grade) != nil }
        let subjects: [String] = Array(Set(graded.map(\.subject))).sorted()
        return Group {
            if !subjects.isEmpty {
                Section("Notenschnitt") {
                    ForEach(subjects, id: \.self) { s in
                        averageRow(s, graded.filter { $0.subject == s })
                    }
                }
            }
        }
    }

    private func averageRow(_ subject: String, _ list: [Exam]) -> some View {
        let values: [Double] = list.compactMap { ExamConfig.value($0.grade) }
        let avg: Double = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let text: String = String(format: "%.1f", avg).replacingOccurrences(of: ".", with: ",")
        return HStack {
            Circle().fill(Timetables.color(subject)).frame(width: 8, height: 8)
            Text(subject)
            Spacer()
            Text("\(values.count) \(values.count == 1 ? "Note" : "Noten")").font(.caption).foregroundStyle(.secondary)
            Text("Ø \(text)").font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(GradeColor.of(String(Int(avg.rounded()))))
        }
    }
}

// MARK: - Eintragen / Bearbeiten

struct ExamEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let kid: FamilyConfig.Kid
    let exam: Exam?

    @State private var model = ExamsModel.shared
    @State private var subject = ""
    @State private var customSubject = ""
    @State private var kind = "Probe"
    @State private var date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var topic = ""
    @State private var grade = ""
    @State private var prepared = false
    @State private var addToCalendar = true
    @State private var saving = false
    @State private var confirmDelete = false

    private var subjects: [String] { ExamConfig.subjects(kid: kid.id) }
    private var finalSubject: String { subject == "__andere" ? customSubject.trimmingCharacters(in: .whitespaces) : subject }
    private var isPast: Bool { Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date()) }
    private var calendarEntity: String { "calendar.\(kid.id)" }
    private var canWriteCalendar: Bool { store.writableCalendars.contains { $0.entity_id == calendarEntity } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Fach") {
                    Picker("Fach", selection: $subject) {
                        ForEach(subjects, id: \.self) { s in Text(s).tag(s) }
                        Text("Anderes …").tag("__andere")
                    }
                    if subject == "__andere" {
                        TextField("Fach", text: $customSubject)
                    }
                    Picker("Art", selection: $kind) {
                        ForEach(ExamConfig.kinds, id: \.self) { k in Text(k).tag(k) }
                    }
                }
                Section("Wann") {
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "de_DE"))
                }
                Section("Thema") {
                    TextField("z. B. Einmaleins, Wortarten, Unit 3", text: $topic, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Toggle("Schon gelernt", isOn: $prepared)
                    if exam != nil || isPast {
                        Picker("Note", selection: $grade) {
                            Text("noch keine").tag("")
                            ForEach(ExamConfig.grades, id: \.self) { g in Text(g).tag(g) }
                        }
                    }
                }
                if exam == nil && canWriteCalendar {
                    Section {
                        Toggle("In \(kid.name)s Kalender eintragen", isOn: $addToCalendar)
                    } footer: {
                        Text("Als ganztägiger Termin, damit ihn alle im Kalender sehen.")
                    }
                }
                if exam != nil {
                    Section {
                        Button("Löschen", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(exam == nil ? "Neue Arbeit" : "Arbeit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { Task { await save() } }
                        .disabled(finalSubject.isEmpty || saving)
                }
            }
            .confirmationDialog("Arbeit löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    if let exam { Task { await model.delete(exam, store: store); dismiss() } }
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        if let e = exam {
            subject = subjects.contains(e.subject) ? e.subject : "__andere"
            customSubject = subjects.contains(e.subject) ? "" : e.subject
            kind = e.kind.isEmpty ? "Probe" : e.kind
            date = e.date
            topic = e.topic
            grade = e.grade
            prepared = e.prepared
        } else if subject.isEmpty {
            subject = subjects.first ?? "__andere"
        }
    }

    private func save() async {
        saving = true
        let e = Exam(id: exam?.id ?? UUID().uuidString, kid: kid.id, subject: finalSubject, kind: kind,
                     day: HADate.day.string(from: date), topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
                     grade: grade, prepared: prepared, by: exam?.by ?? (store.currentPersonName ?? ""))
        await model.save(e, store: store)
        if exam == nil && addToCalendar && canWriteCalendar {
            var title = "📝 \(e.subject) – \(e.kind)"
            if !e.topic.isEmpty { title += ": \(e.topic)" }
            try? await store.createEvent(calendar: calendarEntity, title: title, start: date, end: date, allDay: true, location: "")
        }
        saving = false
        dismiss()
    }
}
