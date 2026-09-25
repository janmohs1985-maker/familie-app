import SwiftUI

struct ListsView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String = ""
    @State private var newItem = ""
    @FocusState private var inputFocused: Bool

    private var listID: String { selected.isEmpty ? (store.todoLists.first?.entity_id ?? "") : selected }
    private var items: [TodoItem] { store.todoItems[listID] ?? [] }
    private var open: [TodoItem] { items.filter { !$0.done } }
    private var done: [TodoItem] { items.filter { $0.done } }

    var body: some View {
        NavigationStack {
            Group {
                if store.todoLists.isEmpty {
                    ContentUnavailableView("Keine Listen", systemImage: "checklist",
                                           description: Text("In Home Assistant gibt es noch keine To-do-Liste."))
                } else {
                    List {
                        if store.todoLists.count > 1 {
                            Picker("Liste", selection: Binding(get: { listID }, set: { selected = $0 })) {
                                ForEach(store.todoLists) { l in Text(l.name).tag(l.entity_id) }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }

                        Section {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.tint).font(.title3)
                                TextField("Hinzufügen …", text: $newItem)
                                    .focused($inputFocused)
                                    .submitLabel(.done)
                                    .onSubmit(add)
                            }
                            ForEach(open) { item in row(item) }
                                .onDelete { idx in delete(idx.map { open[$0] }) }
                        }

                        if !done.isEmpty {
                            Section {
                                ForEach(done) { item in row(item) }
                                    .onDelete { idx in delete(idx.map { done[$0] }) }
                            } header: {
                                HStack {
                                    Text("Erledigt (\(done.count))")
                                    Spacer()
                                    Button("Alle löschen") { Task { await store.clearCompleted(in: listID) } }
                                        .font(.caption).textCase(nil)
                                }
                            }
                        }
                    }
                    .animation(.default, value: items)
                }
            }
            .safeAreaInset(edge: .top) { ErrorBanner().padding(.horizontal) }
            .refreshable { await store.refreshTodos() }
            .navigationTitle(store.todoLists.first { $0.entity_id == listID }?.name ?? "Listen")
        }
    }

    private func row(_ item: TodoItem) -> some View {
        Button {
            Task { await store.setTodo(item, done: !item.done, in: listID) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                Text(item.summary)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add() {
        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newItem = ""
        inputFocused = true          // Tastatur offen lassen für den nächsten Eintrag
        Task { await store.addTodo(text, to: listID) }
    }

    private func delete(_ list: [TodoItem]) {
        Task { for i in list { await store.removeTodo(i, from: listID) } }
    }
}
