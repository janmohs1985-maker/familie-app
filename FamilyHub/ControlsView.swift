import SwiftUI

struct ControlsView: View {
    @Environment(AppStore.self) private var store
    @State private var pending: FamilyConfig.Control?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                ErrorBanner().padding(.horizontal)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(FamilyConfig.controls) { c in
                        ControlTile(control: c, state: store.states[c.id], busy: store.busy.contains(c.id)) {
                            if c.confirm { pending = c } else { Task { await store.perform(c) } }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await store.refreshStates() }
            .navigationTitle("Steuern")
            .confirmationDialog(pending.map { confirmTitle($0) } ?? "",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible) {
                if let c = pending {
                    Button(actionTitle(c)) { Task { await store.perform(c) } }
                    Button("Abbrechen", role: .cancel) { }
                }
            }
        }
    }

    private func isOn(_ c: FamilyConfig.Control) -> Bool {
        c.onStates.contains(store.states[c.id]?.state ?? "")
    }
    private func confirmTitle(_ c: FamilyConfig.Control) -> String {
        "\(c.name) wirklich \(isOn(c) ? "schließen" : "öffnen")?"
    }
    private func actionTitle(_ c: FamilyConfig.Control) -> String {
        switch c.kind {
        case .lock: return isOn(c) ? "Verriegeln" : "Entriegeln"
        default: return isOn(c) ? "Schließen" : "Öffnen"
        }
    }
}

struct ControlTile: View {
    let control: FamilyConfig.Control
    let state: HAState?
    let busy: Bool
    let action: () -> Void

    private var on: Bool { control.onStates.contains(state?.state ?? "") }
    private var unavailable: Bool { state == nil || state!.state == "unavailable" }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: on ? control.symbolOn : control.symbolOff)
                        .font(.title2)
                        .foregroundStyle(on ? Color.white : Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(on ? Color.accentColor : Color.accentColor.opacity(0.12), in: Circle())
                    Spacer()
                    if busy { ProgressView() }
                }
                Text(control.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(stateText).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(on ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(busy || unavailable)
        .opacity(unavailable ? 0.5 : 1)
        .sensoryFeedback(.impact, trigger: state?.state)
    }

    private var stateText: String {
        guard let s = state?.state else { return "Nicht gefunden" }
        switch s {
        case "on": return "An"
        case "off": return "Aus"
        case "locked": return "Verriegelt"
        case "unlocked": return "Entriegelt"
        case "locking": return "Verriegelt …"
        case "unlocking": return "Entriegelt …"
        case "open": return "Offen"
        case "closed": return "Geschlossen"
        case "unavailable": return "Nicht erreichbar"
        case "unknown": return "Unbekannt"
        default: return s
        }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var serverStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Verbindung") {
                    LabeledContent("Server", value: store.credentials?.server ?? "–")
                    LabeledContent("Anmeldung", value: store.credentials?.longLivedToken != nil ? "Token" : "Benutzer")
                    LabeledContent("Status", value: serverStatus ?? "prüfe …")
                    if let t = store.lastUpdate {
                        LabeledContent("Letztes Update", value: t.formatted(date: .omitted, time: .standard))
                    }
                }
                Section("Gefunden") {
                    LabeledContent("Kalender", value: "\(store.calendars.count)")
                    LabeledContent("Listen", value: "\(store.todoLists.count)")
                }
                Section {
                    Button("Abmelden", role: .destructive) {
                        Task { await store.logout(); dismiss() }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .task {
                do { serverStatus = try await store.client.ping() == "API running." ? "Verbunden" : "OK" }
                catch { serverStatus = error.localizedDescription }
            }
        }
    }
}
