import SwiftUI

// MARK: - Schule & Kinder: Stundenplan, Freizeit, Schulmappe und Aufgaben an einem Ort

struct KidsHubView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let own = store.activeKid, let kid = FamilyConfig.kid(own) {
            KidHubDetail(kid: kid)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(FamilyConfig.kids) { kid in
                        NavigationLink { KidHubDetail(kid: kid) } label: { KidSummaryCard(kid: kid) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Schule & Kinder")
        }
    }
}

/// Kurzüberblick je Kind: heute Schule bis …, Freizeit, offene Aufgaben, Punkte
struct KidSummaryCard: View {
    @Environment(AppStore.self) private var store
    let kid: FamilyConfig.Kid

    private var today: Int { ChoreText.todayIndex }
    private var openChores: Int { (store.chores[kid.id] ?? []).filter { !$0.done }.count }

    private var schoolLine: String {
        guard today <= 4, let end = Timetables.schoolEnd(kid: kid.id, day: today) else { return "Heute keine Schule" }
        return "Schule bis \(end) Uhr"
    }

    var body: some View {
        HStack(spacing: 14) {
            Avatar(image: store.pictures[kid.person], name: kid.name, color: kid.color)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(kid.name).font(.headline)
                Label(schoolLine, systemImage: "graduationcap").font(.caption).foregroundStyle(.secondary)
                let free = store.activities(kid: kid.id, day: today)
                if !free.isEmpty {
                    Label(free.map { "\($0.title) \($0.start)" }.joined(separator: ", "), systemImage: "figure.run")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Label("\(store.points(kid.id))", systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(openChores == 0 ? "alles erledigt" : "\(openChores) offen").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct KidHubDetail: View {
    @Environment(AppStore.self) private var store
    let kid: FamilyConfig.Kid

    private var today: Int { ChoreText.todayIndex }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                KidSummaryCard(kid: kid)
                todayCard
                LazyVGrid(columns: columns, spacing: 12) {
                    if store.allows(.stundenplan) {
                        NavigationLink { TimetableView(kid: kid.id) } label: {
                            HubTile(title: "Stundenplan & Freizeit", symbol: "calendar.day.timeline.left", color: .teal)
                        }
                    }
                    if store.allows(.schulmappe) {
                        NavigationLink { SchoolDocsView(kid: kid.id) } label: {
                            HubTile(title: "Schulmappe", symbol: "folder.fill", color: .cyan)
                        }
                    }
                    if store.activeKid == nil {
                        NavigationLink { KidDetailView(kid: kid) } label: {
                            HubTile(title: "Aufgaben & Punkte", symbol: "checkmark.circle.fill", color: .orange)
                        }
                    } else {
                        Button { store.selectedTab = "aufgaben" } label: {
                            HubTile(title: "Meine Aufgaben", symbol: "checkmark.circle.fill", color: .orange)
                        }
                    }
                    if store.activeKid == nil && store.canEditFreizeit {
                        NavigationLink { FreizeitManageView() } label: {
                            HubTile(title: "Freizeit bearbeiten", symbol: "figure.run", color: .purple)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(kid.name)
    }

    /// Heute: Fächer, Schulschluss, Freizeit
    private var todayCard: some View {
        let subjects = today <= 4 ? Timetables.subjects(kid: kid.id, day: today) : []
        let free = store.activities(kid: kid.id, day: today)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Heute").font(.headline)
            if subjects.isEmpty {
                Text("Keine Schule").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(subjects, id: \.self) { sub in
                            Text(sub)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(Timetables.color(sub))
                                .background(Timetables.color(sub).opacity(0.14), in: Capsule())
                        }
                    }
                }
            }
            ForEach(free) { a in ActivityRow(activity: a) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Verwaltung: was die Kinder schalten und sehen dürfen (nur Jan)

struct KidsAdminView: View {
    @Environment(AppStore.self) private var store
    @State private var showReorder = false

    var body: some View {
        Form {
            Section {
                NavigationLink { ControlsManageView() } label: {
                    LabeledContent {
                        Text("\(store.appControls.count)")
                    } label: {
                        Label("Schalter für die Kinder", systemImage: "switch.2")
                    }
                }
                if store.appControls.count > 1 {
                    Button { showReorder = true } label: {
                        Label("Reihenfolge ändern", systemImage: "arrow.up.arrow.down")
                    }
                }
            } footer: {
                Text("Welche Geräte die Kinder unter „Zuhause“ schalten dürfen – pro Kind und auf Wunsch nur zu bestimmten Zeiten. Geräte kommen auch über „Räume“ → lange drücken → „Für die Kinder“ dazu.")
            }
            Section {
                NavigationLink { KidPermissionsView() } label: {
                    Label("Was die Kinder sehen dürfen", systemImage: "eye")
                }
            }
            Section {
                Picker("App ansehen als", selection: Bindable(store).viewAs) {
                    Text("Mich").tag("auto")
                    ForEach(FamilyConfig.kids) { k in Text(k.name).tag(k.id) }
                }
            } footer: {
                Text("Zum Ausprobieren, wie die App für die Kinder aussieht.")
            }
        }
        .navigationTitle("Für die Kinder")
        .sheet(isPresented: $showReorder) { ControlsReorderView() }
        .task { await store.refreshControls() }
    }
}
