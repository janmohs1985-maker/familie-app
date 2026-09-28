import SwiftUI

// MARK: - Heute: Reihenfolge und sichtbare Karten (pro Handy gespeichert)

enum TodayCardKind: String, CaseIterable, Identifiable {
    case weather, mailbox, doorbell, laundry, parentTodos, music, vacuum, people, school, freizeit, meal, waste, upcoming
    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: "Wetter"
        case .mailbox: "Briefkasten"
        case .doorbell: "Klingel (nur nach dem Klingeln)"
        case .laundry: "Wäsche (nur wenn sie läuft)"
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
        case .weather: "cloud.sun.fill"
        case .mailbox: "envelope.fill"
        case .doorbell: "bell.fill"
        case .laundry: "washer.fill"
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
        case .weather: .blue
        case .mailbox: .brown
        case .doorbell: .yellow
        case .laundry: .teal
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
        out += allCases.filter { !seen.contains($0) }
        return out
    }
}

@MainActor
extension AppStore {
    /// Karten, die für diese Person überhaupt in Frage kommen
    func todayCardAvailable(_ k: TodayCardKind) -> Bool {
        let parent = isParent && activeKid == nil
        switch k {
        case .parentTodos, .vacuum: return parent
        case .doorbell: return allows(.haustuer)
        case .laundry: return allows(.waesche)
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
    @AppStorage("todayOrder") private var orderRaw = ""
    @AppStorage("todayHidden") private var hiddenRaw = ""
    @State private var order: [TodayCardKind] = []

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

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
                    Text("Mit ≡ rechts ziehen zum Sortieren, mit dem Auge ein- oder ausblenden. Gilt nur für dieses Handy.")
                }
                Section {
                    Button("Standard wiederherstellen", role: .destructive) {
                        orderRaw = ""; hiddenRaw = ""
                        order = TodayCardKind.ordered("")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Heute anordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .onAppear { order = TodayCardKind.ordered(orderRaw) }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        // Verschieben bezieht sich auf die sichtbare (gefilterte) Liste
        var shown = order.filter { store.todayCardAvailable($0) }
        shown.move(fromOffsets: source, toOffset: destination)
        let others = order.filter { !store.todayCardAvailable($0) }
        order = shown + others
        orderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    private func toggle(_ k: TodayCardKind) {
        var h = hidden
        if h.contains(k.rawValue) { h.remove(k.rawValue) } else { h.insert(k.rawValue) }
        hiddenRaw = h.sorted().joined(separator: ",")
    }
}
