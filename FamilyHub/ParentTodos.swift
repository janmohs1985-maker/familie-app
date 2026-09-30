import SwiftUI

// MARK: - Aufgaben für Jan & Vanessa (ohne Punkte)
//
// todo.eltern_aufgaben: Titel = Name, Fälligkeit = Datum (optional), Status = offen/erledigt,
//   Beschreibung JSON {"fuer":"jan|vanessa|beide","von":"jan|vanessa","notiz":"…"}
// Wer dem anderen etwas zuteilt, schickt ihm eine Mitteilung.

struct ParentTodo: Identifiable, Hashable {
    let uid: String
    var title: String
    var done: Bool
    var due: Date?
    var assignee: String        // "jan", "vanessa" oder "beide"
    var from: String
    var note: String
    var id: String { uid }

    var isOverdue: Bool {
        guard let due, !done else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }
    var isToday: Bool { due.map { Calendar.current.isDateInToday($0) } ?? false }
}

@MainActor
extension AppStore {

    /// Jan oder Vanessa – über die Verknüpfung Person ↔ HA-Benutzer
    var myParentID: String? {
        guard let uid = currentUserID, isParent else { return nil }
        return FamilyConfig.parents.first { states[$0.person]?.attr("user_id")?.string == uid }?.id
    }
    var partnerID: String? {
        guard let me = myParentID else { return nil }
        return FamilyConfig.parents.first { $0.id != me }?.id
    }
    var canUseParentTodos: Bool { isParent && activeKid == nil }

    func parentTodos(for filter: String) -> [ParentTodo] {
        switch filter {
        case "alle": return parentTodos
        default: return parentTodos.filter { $0.assignee == filter || $0.assignee == "beide" }
        }
    }

    /// Offene Aufgaben für mich (inkl. „beide“) – für „Heute“ und das Badge
    var myOpenTodos: [ParentTodo] {
        guard let me = myParentID else { return [] }
        return parentTodos.filter { !$0.done && ($0.assignee == me || $0.assignee == "beide") }
    }

    func refreshParentTodos() async {
        guard isLoggedIn else { return }
        do {
            let r = try await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.parentTodoList,
                                                                           "status": ["needs_action", "completed"]])
            parentTodos = (r[FamilyConfig.parentTodoList]?["items"]?.array ?? []).compactMap { i in
                guard let uid = i["uid"]?.string, let title = i["summary"]?.string else { return nil }
                let cfg = ChoreText.json(i["description"]?.string)
                let due = (i["due"]?.string).flatMap { HADate.day.date(from: String($0.prefix(10))) }
                return ParentTodo(uid: uid, title: title, done: i["status"]?.string == "completed", due: due,
                                  assignee: cfg?["fuer"]?.string ?? "beide", from: cfg?["von"]?.string ?? "",
                                  note: cfg?["notiz"]?.string ?? "")
            }
            .sorted(by: Self.todoOrder)
        } catch { report(error) }
    }

    /// Offene zuerst; darin Überfälliges/Datum aufsteigend, ohne Datum dahinter
    nonisolated static func todoOrder(_ a: ParentTodo, _ b: ParentTodo) -> Bool {
        if a.done != b.done { return !a.done }
        switch (a.due, b.due) {
        case let (x?, y?): return x != y ? x < y : a.title < b.title
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.title.localizedCompare(b.title) == .orderedAscending
        }
    }

    private func todoJSON(_ t: ParentTodo) -> String {
        ChoreText.jsonString(["fuer": t.assignee, "von": t.from, "notiz": t.note])
    }

    /// nil = gespeichert, sonst Fehlermeldung
    func saveParentTodo(_ t: ParentTodo, previous: ParentTodo? = nil) async -> String? {
        guard canUseParentTodos else { return "Nur für Eltern." }
        var t = t
        if t.from.isEmpty { t.from = myParentID ?? "" }
        do {
            var data: [String: Any] = ["entity_id": FamilyConfig.parentTodoList, "description": todoJSON(t)]
            if let due = t.due { data["due_date"] = HADate.day.string(from: due) }
            if t.uid.isEmpty {
                data["item"] = t.title
                try await client.call("todo", "add_item", data)
            } else {
                data["item"] = t.uid
                data["rename"] = t.title
                if t.due == nil, previous?.due != nil { data["due_date"] = NSNull() }   // Datum entfernen
                try await client.call("todo", "update_item", data)
            }
        } catch {
            return "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
        // Partner benachrichtigen, wenn ihm (neu) etwas zugeteilt wurde
        if let me = myParentID, t.assignee != me, previous?.assignee != t.assignee || previous == nil {
            let myName = FamilyConfig.parent(me)?.name ?? "Jemand"
            let target = t.assignee == "beide" ? (partnerID ?? "") : t.assignee
            if !target.isEmpty {
                var msg = t.title
                if let due = t.due { msg += " · bis \(DayText.label(due))" }
                await notify(target, "📝 Aufgabe von \(myName)", msg)
            }
        }
        await refreshParentTodos()
        return nil
    }

    func setParentTodo(_ t: ParentTodo, done: Bool) async {
        if let i = parentTodos.firstIndex(where: { $0.uid == t.uid }) {
            parentTodos[i].done = done
            parentTodos.sort(by: Self.todoOrder)
        }
        do {
            try await client.call("todo", "update_item", ["entity_id": FamilyConfig.parentTodoList, "item": t.uid,
                                                          "status": done ? "completed" : "needs_action"])
        } catch { report(error) }
        // dem anderen Bescheid geben, wenn er die Aufgabe verteilt hat
        if done, let me = myParentID, !t.from.isEmpty, t.from != me {
            let myName = FamilyConfig.parent(me)?.name ?? "Jemand"
            await notify(t.from, "✅ \(myName) hat erledigt", t.title)
        }
        await refreshParentTodos()
    }

    func deleteParentTodo(_ t: ParentTodo) async {
        parentTodos.removeAll { $0.uid == t.uid }
        do { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.parentTodoList, "item": t.uid]) }
        catch { report(error) }
    }

    func clearDoneParentTodos() async {
        do { try await client.call("todo", "remove_completed_items", ["entity_id": FamilyConfig.parentTodoList]) }
        catch { report(error) }
        await refreshParentTodos()
    }
}

// MARK: - Liste

struct ParentTodosView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("elternFilter") private var filter = "mich"
    @State private var newTitle = ""
    @State private var newAssignee = ""
    @State private var editing: ParentTodo?
    @State private var showDone = false
    @FocusState private var inputFocused: Bool

    private var me: String { store.myParentID ?? "" }
    private var partner: String { store.partnerID ?? "" }
    private var effectiveFilter: String { filter == "mich" ? me : filter == "partner" ? partner : "alle" }
    private var list: [ParentTodo] { store.parentTodos(for: effectiveFilter) }
    private var open: [ParentTodo] { list.filter { !$0.done } }
    private var done: [ParentTodo] { list.filter(\.done) }

    var body: some View {
        List {
            Picker("Anzeigen", selection: $filter) {
                Text("Für mich (\(store.parentTodos(for: me).filter { !$0.done }.count))").tag("mich")
                Text("\(FamilyConfig.parent(partner)?.name ?? "Partner") (\(store.parentTodos(for: partner).filter { !$0.done }.count))").tag("partner")
                Text("Alle").tag("alle")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            // Schnell hinzufügen
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.tint)
                    TextField("Neue Aufgabe …", text: $newTitle)
                        .focused($inputFocused)
                        .submitLabel(.done)
                        .onSubmit(quickAdd)
                    Menu {
                        ForEach(FamilyConfig.parents) { p in
                            Button { newAssignee = p.id } label: {
                                Label(p.id == me ? "Für mich" : "Für \(p.name)", systemImage: newAssignee == p.id ? "checkmark" : "person")
                            }
                        }
                        Button { newAssignee = "beide" } label: {
                            Label("Für uns beide", systemImage: newAssignee == "beide" ? "checkmark" : "person.2")
                        }
                    } label: {
                        AssigneeChip(assignee: newAssignee.isEmpty ? me : newAssignee, me: me)
                    }
                }
            } footer: {
                Text("Tippen auf den Namen: wem die Aufgabe gehört. Der andere bekommt eine Mitteilung.")
            }

            Section {
                if open.isEmpty {
                    Label("Nichts offen", systemImage: "checkmark.seal.fill").foregroundStyle(.secondary)
                }
                ForEach(open) { t in row(t) }
            }

            if !done.isEmpty {
                Section {
                    if showDone {
                        ForEach(done) { t in row(t) }
                    }
                } header: {
                    HStack {
                        Button {
                            withAnimation { showDone.toggle() }
                        } label: {
                            Label("Erledigt (\(done.count))", systemImage: showDone ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if showDone {
                            Button("Löschen") { Task { await store.clearDoneParentTodos() } }
                                .font(.caption)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .animation(.default, value: store.parentTodos)
        .sheet(item: $editing) { t in ParentTodoEditView(todo: t) }
        .refreshable { await store.refreshParentTodos() }
        .task { await store.refreshParentTodos() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = ParentTodo(uid: "", title: "", done: false, due: nil,
                                         assignee: effectiveFilter == "alle" ? me : effectiveFilter, from: me, note: "")
                } label: { Image(systemName: "square.and.pencil") }
            }
        }
    }

    private func row(_ t: ParentTodo) -> some View {
        ParentTodoRow(todo: t, me: me) {
            Task { await store.setParentTodo(t, done: !t.done) }
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = t }
        .swipeActions(edge: .trailing) {
            Button("Löschen", role: .destructive) { Task { await store.deleteParentTodo(t) } }
        }
        .swipeActions(edge: .leading) {
            if !t.done, !partner.isEmpty {
                let target = t.assignee == partner ? me : partner
                Button {
                    var n = t
                    n.assignee = target
                    Task { _ = await store.saveParentTodo(n, previous: t) }
                } label: {
                    Label(target == me ? "Übernehmen" : "An \(FamilyConfig.parent(target)?.name ?? "")",
                          systemImage: "arrow.left.arrow.right")
                }
                .tint(FamilyConfig.parent(target)?.color ?? .indigo)
            }
        }
    }

    private func quickAdd() {
        let text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newTitle = ""
        inputFocused = true
        let who = newAssignee.isEmpty ? (effectiveFilter == "alle" ? me : effectiveFilter) : newAssignee
        let t = ParentTodo(uid: "", title: text, done: false, due: nil, assignee: who, from: me, note: "")
        Task {
            if let err = await store.saveParentTodo(t) { store.lastError = err }
        }
    }
}

struct AssigneeChip: View {
    @Environment(AppStore.self) private var store
    let assignee: String
    let me: String

    private var faces: [FamilyConfig.Parent] {
        assignee == "beide" ? FamilyConfig.parents : FamilyConfig.parent(assignee).map { [$0] } ?? []
    }

    var body: some View {
        let p = FamilyConfig.parent(assignee)
        HStack(spacing: 5) {
            HStack(spacing: -6) {
                ForEach(faces) { f in
                    Avatar(image: store.pictures[f.person], name: f.name, color: f.color,
                           initialFont: .system(size: 9, weight: .bold), ring: 1.5)
                        .frame(width: 18, height: 18)
                }
            }
            Text(assignee == "beide" ? "Beide" : (assignee == me ? "Ich" : (p?.name ?? "–")))
                .font(.caption.weight(.semibold))
        }
        .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
        .foregroundStyle(p?.color ?? .indigo)
        .background((p?.color ?? .indigo).opacity(0.15), in: Capsule())
    }
}

struct ParentTodoRow: View {
    let todo: ParentTodo
    let me: String
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .strikethrough(todo.done)
                    .foregroundStyle(todo.done ? .secondary : .primary)
                HStack(spacing: 6) {
                    AssigneeChip(assignee: todo.assignee, me: me)
                    if let due = todo.due {
                        Label(DayText.label(due), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(todo.isOverdue ? Color.red : (todo.isToday ? Color.orange : Color.secondary))
                    }
                    if !todo.from.isEmpty, todo.from != me, todo.from != todo.assignee || todo.assignee == "beide" {
                        Text("von \(FamilyConfig.parent(todo.from)?.name ?? todo.from)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !todo.note.isEmpty {
                    Text(todo.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Bearbeiten

struct ParentTodoEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var todo: ParentTodo
    @State private var original: ParentTodo?
    @State private var hasDue = false
    @State private var dueDate = Date()
    @State private var saving = false
    @State private var saveError: String?

    private var isNew: Bool { todo.uid.isEmpty }
    private var me: String { store.myParentID ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was ist zu tun?", text: $todo.title, axis: .vertical)
                    Picker("Für", selection: $todo.assignee) {
                        ForEach(FamilyConfig.parents) { p in Text(p.id == me ? "Mich" : p.name).tag(p.id) }
                        Text("Beide").tag("beide")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("Bis wann", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("Datum", selection: $dueDate, displayedComponents: .date)
                        HStack {
                            ForEach([("Heute", 0), ("Morgen", 1), ("In 1 Woche", 7)], id: \.1) { item in
                                Button(item.0) {
                                    dueDate = Calendar.current.date(byAdding: .day, value: item.1, to: Date()) ?? Date()
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                Section("Notiz") {
                    TextField("optional", text: $todo.note, axis: .vertical)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                }
                if !isNew {
                    Section {
                        Button(todo.done ? "Wieder öffnen" : "Als erledigt markieren") {
                            let t = todo
                            Task { await store.setParentTodo(t, done: !t.done); dismiss() }
                        }
                        Button("Löschen", role: .destructive) {
                            let t = todo
                            Task { await store.deleteParentTodo(t); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Neue Aufgabe" : "Aufgabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Sichern") {
                            var t = todo
                            t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            t.note = t.note.trimmingCharacters(in: .whitespacesAndNewlines)
                            t.due = hasDue ? dueDate : nil
                            saving = true
                            saveError = nil
                            Task {
                                let err = await store.saveParentTodo(t, previous: original)
                                saving = false
                                if let err { saveError = err } else { dismiss() }
                            }
                        }
                        .disabled(todo.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if original == nil && !isNew { original = todo }
                hasDue = todo.due != nil
                dueDate = todo.due ?? Date()
            }
        }
    }
}

// MARK: - Karte auf „Heute“

struct ParentTodosTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.canUseParentTodos, store.myParentID != nil {
            // Fällige (überfällig, heute, morgen) stehen schon unter „Aktuell“ – hier nur der Rest
            let cal = Calendar.current
            let limit = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: Date())) ?? Date()
            let open = store.myOpenTodos.filter { t in t.due.map { $0 >= limit } ?? true }
            let me = store.myParentID ?? ""
            if !open.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header(open.count)
                    ForEach(Array(open.prefix(3).enumerated()), id: \.element.id) { i, t in
                        Divider().padding(.leading, i == 0 ? 0 : 40)
                        TodayTodoRow(todo: t, me: me) {
                            Task { await store.setParentTodo(t, done: true) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
        }
    }

    private func header(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Weitere Aufgaben").font(.headline)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                store.aufgabenMode = "wir"
                store.selectedTab = "aufgaben"
            } label: {
                HStack(spacing: 3) {
                    Text(count > 3 ? "Alle \(count)" : "Liste")
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.bottom, 10)
    }
}

/// Kompakte Zeile für „Heute“: Kreis, Titel, darunter Fälligkeit/Absender – Gesichter nur bei „beide“
struct TodayTodoRow: View {
    @Environment(AppStore.self) private var store
    let todo: ParentTodo
    let me: String
    let done: () -> Void
    @State private var ticked = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { ticked = true }
                done()
            } label: {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(ticked ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.borderless)
            .sensoryFeedback(.success, trigger: ticked)
            .accessibilityLabel("\(todo.title) erledigt")

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(ticked)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(dueColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if todo.assignee == "beide" {
                HStack(spacing: -7) {
                    ForEach(FamilyConfig.parents) { f in
                        Avatar(image: store.pictures[f.person], name: f.name, color: f.color,
                               initialFont: .system(size: 10, weight: .bold), ring: 1.5)
                            .frame(width: 24, height: 24)
                    }
                }
                .accessibilityLabel("für beide")
            }
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let due = todo.due {
            parts.append(todo.isOverdue ? "überfällig seit \(DayText.label(due))" : DayText.label(due))
        }
        if !todo.from.isEmpty, todo.from != me {
            parts.append("von \(FamilyConfig.parent(todo.from)?.name ?? todo.from)")
        }
        if !todo.note.isEmpty { parts.append(todo.note) }
        return parts.joined(separator: " · ")
    }

    private var dueColor: Color {
        if todo.isOverdue { return .red }
        if todo.isToday { return .orange }
        return .secondary
    }
}
