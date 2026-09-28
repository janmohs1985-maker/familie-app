import SwiftUI

// MARK: - Heute: Reihenfolge und sichtbare Karten
//
// Für alle gleich: gespeichert in input_text.familie_heute_layout als "reihenfolge|ausgeblendet"
// (z. B. "weather,people,meal|music,vacuum"), "-" = Standard. Nur Jan kann es ändern.

enum TodayCardKind: String, CaseIterable, Identifiable {
    case safety, weather, mailbox, doorbell, laundry, kitchen, parentTodos, music, vacuum, people, school, freizeit, meal, waste, upcoming
    var id: String { rawValue }

    var title: String {
        switch self {
        case .safety: "Rauchmelder (nur bei Problemen)"
        case .weather: "Wetter"
        case .mailbox: "Briefkasten"
        case .doorbell: "Klingel (nur nach dem Klingeln)"
        case .laundry: "Wäsche (nur wenn sie läuft)"
        case .kitchen: "Küchengeräte (nur wenn sie laufen)"
        case .parentTodos: "Unsere Aufgaben"
        case .music: "Musik"
        case .vacuum: "Saugroboter"
        case .people: "Wer ist wo?"
        case .school: "Stundenplan heute"
        case .freizeit: "Freizeit heute"
        case .meal: "Essen heute"
        case .waste: "Müllabfuhr"
        case .upcoming: "Nächste Termine"
        }
    }
    var symbol: String {
        switch self {
        case .safety: "smoke.fill"
        case .weather: "cloud.sun.fill"
        case .mailbox: "envelope.fill"
        case .doorbell: "bell.fill"
        case .laundry: "washer.fill"
        case .kitchen: "oven.fill"
        case .parentTodos: "checklist"
        case .music: "hifispeaker.2.fill"
        case .vacuum: "fan.fill"
        case .people: "person.2.fill"
        case .school: "graduationcap.fill"
        case .freizeit: "figure.run"
        case .meal: "fork.knife"
        case .waste: "trash.fill"
        case .upcoming: "calendar"
        }
    }
    var color: Color {
        switch self {
        case .safety: .red
        case .weather: .blue
        case .mailbox: .brown
        case .doorbell: .yellow
        case .laundry: .teal
        case .kitchen: .orange
        case .parentTodos: .orange
        case .music: .pink
        case .vacuum: .mint
        case .people: .green
        case .school: .teal
        case .freizeit: .purple
        case .meal: .orange
        case .waste: .gray
        case .upcoming: .red
        }
    }

    /// Gespeicherte Reihenfolge; neue Karten werden hinten angehängt
    static func ordered(_ raw: String) -> [TodayCardKind] {
        var out = raw.split(separator: ",").compactMap { TodayCardKind(rawValue: String($0)) }
        var seen = Set<TodayCardKind>()
        out = out.filter { seen.insert($0).inserted }
        // Neue Karten hinten anhängen – Warnkarten (Rauchmelder) aber immer ganz nach oben
        let missing = allCases.filter { !seen.contains($0) }
        out = missing.filter { $0 == .safety } + out + missing.filter { $0 != .safety }
        return out
    }
}

@MainActor
extension AppStore {
    static let todayLayoutEntity = "input_text.familie_heute_layout"

    private var todayLayoutParts: [String] {
        let raw = states[Self.todayLayoutEntity]?.state ?? ""
        guard raw.contains(",") || raw.contains("|") else { return ["", ""] }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return [parts.first ?? "", parts.count > 1 ? parts[1] : ""]
    }
    var todayOrderRaw: String { todayLayoutParts[0] }
    var todayHidden: Set<String> { Set(todayLayoutParts[1].split(separator: ",").map(String.init)) }

    func saveTodayLayout(order: [TodayCardKind], hidden: Set<String>) async {
        let value = order.map(\.rawValue).joined(separator: ",") + "|" + hidden.sorted().joined(separator: ",")
        do {
            _ = try await client.call("input_text", "set_value", ["entity_id": Self.todayLayoutEntity, "value": value])
            try? await Task.sleep(for: .milliseconds(400))
            await refreshStates()
        } catch { report(error) }
    }

    func resetTodayLayout() async {
        do {
            _ = try await client.call("input_text", "set_value", ["entity_id": Self.todayLayoutEntity, "value": "-"])
            await refreshStates()
        } catch { report(error) }
    }

    /// Karten, die für diese Person überhaupt in Frage kommen
    func todayCardAvailable(_ k: TodayCardKind) -> Bool {
        let parent = isParent && activeKid == nil
        switch k {
        case .parentTodos, .vacuum: return parent
        case .doorbell: return allows(.haustuer)
        case .laundry, .kitchen: return allows(.waesche)
        case .safety: return allows(.rauchmelder)
        case .music: return allows(.musik)
        case .school, .freizeit: return allows(.stundenplan)
        case .meal: return allows(.essensplan)
        default: return true
        }
    }
}

struct TodayArrangeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var order: [TodayCardKind] = []
    @State private var hidden: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order.filter { store.todayCardAvailable($0) }) { k in
                        let visible = !hidden.contains(k.rawValue)
                        HStack(spacing: 12) {
                            Image(systemName: k.symbol)
                                .font(.subheadline).foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(visible ? AnyShapeStyle(k.color.gradient) : AnyShapeStyle(Color.gray.opacity(0.4)),
                                            in: RoundedRectangle(cornerRadius: 7))
                            Text(k.title).foregroundStyle(visible ? .primary : .secondary)
                            Spacer()
                            Button { toggle(k) } label: {
                                Image(systemName: visible ? "eye.fill" : "eye.slash")
                                    .foregroundStyle(visible ? Color.accentColor : Color.secondary)
                                    .frame(width: 36, height: 30)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Mit ≡ rechts ziehen zum Sortieren, mit dem Auge ein- oder ausblenden. Gilt für alle Handys – die Kinder sehen davon nur ihre Karten.")
                }
                Section {
                    Button("Standard wiederherstellen", role: .destructive) {
                        order = TodayCardKind.ordered("")
                        hidden = []
                        Task { await store.resetTodayLayout() }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Heute anordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .onAppear {
                order = TodayCardKind.ordered(store.todayOrderRaw)
                hidden = store.todayHidden
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        // Verschieben bezieht sich auf die sichtbare (gefilterte) Liste
        var shown = order.filter { store.todayCardAvailable($0) }
        shown.move(fromOffsets: source, toOffset: destination)
        let others = order.filter { !store.todayCardAvailable($0) }
        order = shown + others
        Task { await store.saveTodayLayout(order: order, hidden: hidden) }
    }

    private func toggle(_ k: TodayCardKind) {
        if hidden.contains(k.rawValue) { hidden.remove(k.rawValue) } else { hidden.insert(k.rawValue) }
        Task { await store.saveTodayLayout(order: order, hidden: hidden) }
    }
}
