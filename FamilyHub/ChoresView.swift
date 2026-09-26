import SwiftUI

struct ChoresView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if !store.roleKnown {
                    if store.userLookupFailed {
                        ContentUnavailableView {
                            Label("Benutzer nicht erkannt", systemImage: "person.crop.circle.badge.questionmark")
                        } description: {
                            Text("Die App konnte nicht feststellen, wer angemeldet ist.")
                        } actions: {
                            Button("Erneut versuchen") { Task { await store.loadCurrentUser() } }
                        }
                    } else {
                        ProgressView("Lade …")
                    }
                } else if let id = store.activeKid, let kid = FamilyConfig.kid(id) {
                    KidChoresView(kid: kid)
                } else {
                    ParentChoresView()
                }
            }
            .safeAreaInset(edge: .top) { ErrorBanner().padding(.horizontal) }
            .navigationTitle("Aufgaben")
            .task { await store.loadCurrentUser(); await store.refreshChores() }
        }
    }
}

// MARK: - Kinder-Ansicht

struct KidChoresView: View {
    @Environment(AppStore.self) private var store
    let kid: FamilyConfig.Kid

    private var mine: [Chore] { store.chores[kid.id] ?? [] }
    private var open: [Chore] { mine.filter { !$0.done } }
    private var waiting: [Chore] { mine.filter(\.done) }
    private var myRequests: [RewardRequest] { store.rewardRequests.filter { $0.kid == kid.id } }

    var body: some View {
        List {
            Section {
                PointsBanner(name: kid.name, points: store.points(kid.id), color: kid.color)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Meine Aufgaben") {
                if open.isEmpty && waiting.isEmpty {
                    Label("Alles erledigt – super!", systemImage: "party.popper.fill")
                        .foregroundStyle(.secondary)
                }
                ForEach(open) { c in
                    ChoreRow(chore: c) {
                        Button {
                            Task { await store.setChore(c, done: true) }
                        } label: {
                            Label("Erledigt", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.subheadline.bold())
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                    }
                }
                ForEach(waiting) { c in
                    ChoreRow(chore: c, subtitle: "Wartet auf Bestätigung") {
                        Button("Doch nicht") { Task { await store.setChore(c, done: false) } }
                            .buttonStyle(.bordered).font(.caption)
                    }
                    .opacity(0.7)
                }
            }

            Section {
                if store.rewards.isEmpty {
                    Text("Noch keine Belohnungen festgelegt.").foregroundStyle(.secondary)
                }
                ForEach(store.rewards) { r in
                    let enough = store.availablePoints(kid.id) >= r.points
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.body.weight(.medium))
                            Label(ChoreText.pointsText(r.points), systemImage: "star.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Einlösen") { Task { await store.requestReward(r, kid: kid.id) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!enough)
                    }
                }
                ForEach(myRequests) { r in
                    HStack {
                        Image(systemName: "hourglass").foregroundStyle(.orange)
                        Text(r.title.replacingOccurrences(of: "\(kid.name): ", with: ""))
                        Spacer()
                        Button("Zurückziehen") { Task { await store.cancelRequest(r) } }
                            .font(.caption).buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Belohnungen")
            } footer: {
                if !myRequests.isEmpty { Text("Angefragte Belohnungen müssen noch von Mama oder Papa bestätigt werden.") }
            }
        }
        .refreshable { await store.refreshAll() }
    }
}

// MARK: - Eltern-Ansicht

struct ParentChoresView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false

    var body: some View {
        List {
            if !store.pendingChores.isEmpty || !store.rewardRequests.isEmpty {
                Section("Zu bestätigen") {
                    ForEach(store.pendingChores) { c in
                        HStack(spacing: 12) {
                            KidDot(kid: c.kid)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.body.weight(.medium))
                                Text("\(FamilyConfig.kid(c.kid)?.name ?? c.kid) · \(ChoreText.pointsText(c.points))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { Task { await store.rejectChore(c) } } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill").font(.title)
                            }
                            .buttonStyle(.borderless).tint(.orange)
                            Button { Task { await store.confirmChore(c) } } label: {
                                Image(systemName: "checkmark.circle.fill").font(.title)
                            }
                            .buttonStyle(.borderless).tint(.green)
                        }
                    }
                    ForEach(store.rewardRequests) { r in
                        HStack(spacing: 12) {
                            Image(systemName: "gift.fill").foregroundStyle(.purple).frame(width: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.body.weight(.medium))
                                Text("möchte einlösen · −\(ChoreText.pointsText(r.points))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { Task { await store.cancelRequest(r) } } label: {
                                Image(systemName: "xmark.circle.fill").font(.title)
                            }
                            .buttonStyle(.borderless).tint(.red)
                            Button { Task { await store.confirmRequest(r) } } label: {
                                Image(systemName: "checkmark.circle.fill").font(.title)
                            }
                            .buttonStyle(.borderless).tint(.green)
                        }
                    }
                }
            }

            Section("Kinder") {
                ForEach(FamilyConfig.kids) { kid in
                    let list = store.chores[kid.id] ?? []
                    NavigationLink {
                        KidDetailView(kid: kid)
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(image: store.pictures[kid.person], name: kid.name, color: kid.color)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kid.name).font(.headline)
                                Text("\(list.filter { !$0.done }.count) offen").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("\(store.points(kid.id))", systemImage: "star.fill")
                                .font(.headline).foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section("Verwalten") {
                NavigationLink { TemplatesView() } label: {
                    LabeledContent {
                        Text("\(store.choreTemplates.filter(\.active).count)")
                    } label: {
                        Label("Wiederkehrende Aufgaben", systemImage: "repeat")
                    }
                }
                NavigationLink { RewardsManageView() } label: {
                    LabeledContent {
                        Text("\(store.rewards.count)")
                    } label: {
                        Label("Belohnungen", systemImage: "gift")
                    }
                }
            }
        }
        .refreshable { await store.refreshAll() }
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showAdd) { AddChoreView() }
    }
}

struct KidDetailView: View {
    @Environment(AppStore.self) private var store
    let kid: FamilyConfig.Kid
    @State private var delta = 5
    @State private var reason = ""

    private var list: [Chore] { store.chores[kid.id] ?? [] }

    var body: some View {
        List {
            Section {
                PointsBanner(name: kid.name, points: store.points(kid.id), color: kid.color)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Offene Aufgaben") {
                if list.filter({ !$0.done }).isEmpty { Text("Keine offenen Aufgaben").foregroundStyle(.secondary) }
                ForEach(list.filter { !$0.done }) { c in ChoreRow(chore: c) { EmptyView() } }
                    .onDelete { idx in
                        let open = list.filter { !$0.done }
                        Task { for i in idx { await store.deleteChore(open[i]) } }
                    }
            }
            if list.contains(where: \.done) {
                Section("Erledigt – wartet auf Bestätigung") {
                    ForEach(list.filter(\.done)) { c in
                        ChoreRow(chore: c) {
                            Button { Task { await store.confirmChore(c) } } label: {
                                Image(systemName: "checkmark.circle.fill").font(.title2)
                            }
                            .buttonStyle(.borderless).tint(.green)
                        }
                    }
                }
            }

            Section {
                Stepper("\(delta > 0 ? "+" : "")\(delta) Punkte", value: $delta, in: -500...500, step: 1)
                TextField("Grund (optional)", text: $reason)
                Button {
                    let d = delta, r = reason
                    reason = ""
                    Task { await store.adjustPoints(kid: kid.id, delta: d, reason: r) }
                } label: {
                    Label(delta >= 0 ? "Gutschreiben" : "Abziehen", systemImage: delta >= 0 ? "plus.circle" : "minus.circle")
                }
                .disabled(delta == 0)
            } header: {
                Text("Punkte von Hand anpassen")
            } footer: {
                Text("Z. B. für Extra-Hilfe oder als Abzug. Wird im Logbuch von Home Assistant festgehalten.")
            }
        }
        .navigationTitle(kid.name)
        .refreshable { await store.refreshAll() }
    }
}

// MARK: - Neue Aufgabe

struct AddChoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var selectedKids: Set<String> = [FamilyConfig.kids.first?.id ?? ""]
    @State private var points = 10
    @State private var repeats = false
    @State private var days: Set<Int> = Set(0...6)
    @State private var hasDue = false
    @State private var due = Date()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Aufgabe") {
                    TextField("z. B. Zimmer aufräumen", text: $title)
                }
                Section("Für") {
                    ForEach(FamilyConfig.kids) { k in
                        Toggle(isOn: Binding(
                            get: { selectedKids.contains(k.id) },
                            set: { on in if on { selectedKids.insert(k.id) } else { selectedKids.remove(k.id) } })) {
                            Label { Text(k.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(k.color) }
                        }
                    }
                }
                Section("Belohnung") {
                    Stepper(value: $points, in: 1...500) {
                        Label(ChoreText.pointsText(points), systemImage: "star.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        ForEach([5, 10, 20, 50], id: \.self) { p in
                            Button("\(p)") { points = p }
                                .buttonStyle(.bordered)
                                .tint(points == p ? .orange : .gray)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                Section {
                    Toggle("Wiederholen", isOn: $repeats.animation())
                    if repeats {
                        WeekdayPicker(days: $days)
                    } else {
                        Toggle("Fällig am", isOn: $hasDue.animation())
                        if hasDue { DatePicker("Datum", selection: $due, displayedComponents: .date) }
                    }
                } footer: {
                    if repeats {
                        Text("Die Aufgabe wird an jedem gewählten Tag morgens um 5 Uhr neu angelegt – ist sie heute dran, sofort.")
                    }
                }
            }
            .navigationTitle("Neue Aufgabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }.disabled(!valid)
                    }
                }
            }
        }
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !selectedKids.isEmpty && (!repeats || !days.isEmpty)
    }

    private func save() async {
        saving = true
        let t = title.trimmingCharacters(in: .whitespaces)
        for kid in FamilyConfig.kids.map(\.id) where selectedKids.contains(kid) {
            if repeats {
                await store.addTemplate(kid: kid, title: t, points: points, days: Array(days))
            } else {
                await store.addChore(kid: kid, title: t, points: points, due: hasDue ? due : nil)
            }
        }
        saving = false
        dismiss()
    }
}

struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(ChoreText.dayNames[d])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Verwalten

struct TemplatesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            if store.choreTemplates.isEmpty {
                ContentUnavailableView("Keine wiederkehrenden Aufgaben", systemImage: "repeat",
                                       description: Text("Lege über + auf der Aufgaben-Seite eine Aufgabe mit „Wiederholen“ an."))
            }
            ForEach(FamilyConfig.kids) { kid in
                let list = store.choreTemplates.filter { $0.kid == kid.id }
                if !list.isEmpty {
                    Section(kid.name) {
                        ForEach(list) { t in
                            Toggle(isOn: Binding(get: { t.active }, set: { on in Task { await store.setTemplate(t, active: on) } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title)
                                    Text("\(ChoreText.pointsText(t.points)) · \(ChoreText.weekdays(t.days))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in Task { for i in idx { await store.deleteTemplate(list[i]) } } }
                    }
                }
            }
        }
        .navigationTitle("Wiederkehrend")
    }
}

struct RewardsManageView: View {
    @Environment(AppStore.self) private var store
    @State private var title = ""
    @State private var points = 50

    var body: some View {
        List {
            Section("Neue Belohnung") {
                TextField("z. B. 30 Min. Tablet", text: $title)
                Stepper(value: $points, in: 1...5000, step: 5) {
                    Label(ChoreText.pointsText(points), systemImage: "star.fill").foregroundStyle(.orange)
                }
                Button {
                    let t = title.trimmingCharacters(in: .whitespaces), p = points
                    title = ""
                    Task { await store.addReward(title: t, points: p) }
                } label: { Label("Hinzufügen", systemImage: "plus.circle.fill") }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("Belohnungen") {
                if store.rewards.isEmpty { Text("Noch keine").foregroundStyle(.secondary) }
                ForEach(store.rewards) { r in
                    LabeledContent(r.title, value: ChoreText.pointsText(r.points))
                }
                .onDelete { idx in
                    let list = store.rewards
                    Task { for i in idx { await store.deleteReward(list[i]) } }
                }
            }
        }
        .navigationTitle("Belohnungen")
    }
}

// MARK: - Bausteine

struct PointsBanner: View {
    let name: String
    let points: Int
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "star.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .shadow(color: .orange.opacity(0.5), radius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(points)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(points == 1 ? "Punkt" : "Punkte").font(.subheadline).foregroundStyle(.white.opacity(0.9))
            }
            .foregroundStyle(.white)
            Spacer()
            Text(name).font(.title3.bold()).foregroundStyle(.white.opacity(0.9))
        }
        .padding(20)
        .background(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20))
        .animation(.default, value: points)
    }
}

struct ChoreRow<Trailing: View>: View {
    let chore: Chore
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chore.title).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Label("\(chore.points)", systemImage: "star.fill").foregroundStyle(.orange)
                    if chore.recurring { Image(systemName: "repeat").foregroundStyle(.secondary) }
                    if let due = chore.due {
                        Label(DayText.label(due), systemImage: "calendar")
                            .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) ? Color.red : Color.secondary)
                    }
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }
}

struct KidDot: View {
    let kid: String
    var body: some View {
        Circle().fill(FamilyConfig.kid(kid)?.color ?? .gray).frame(width: 12, height: 12)
    }
}
