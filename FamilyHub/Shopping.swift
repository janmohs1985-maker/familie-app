import SwiftUI

// MARK: - Einkaufsliste mit „wer hat's eingetragen / gekauft / haben wir noch“
//
// Die HA-Einkaufsliste (shopping_list) kann nur Text speichern. Die Zusatzinfos liegen deshalb in der
// versteckten Liste todo.einkauf_details: Name = uid des Einkaufs-Eintrags, Beschreibung = JSON (ShopMeta).

struct ShopMeta: Codable, Equatable {
    var von: String?        // wer hat's eingetragen (jan, vanessa, emma, leoni)
    var zeit: String?       // wann eingetragen (ISO)
    var status: String?     // "gekauft" | "vorhanden"
    var wer: String?        // wer hat abgehakt
    var wann: String?       // wann abgehakt (ISO)
}

struct ShopMetaEntry {
    let metaUID: String
    var meta: ShopMeta
}

enum ShopText {
    /// „2x Milch“, „Milch 2“, „3 Äpfel“ → (Menge, Name)
    static func split(_ s: String) -> (qty: String?, name: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(\d+[.,]?\d*)\s*(x|×|stk\.?|stück)?\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let q = t[r].trimmingCharacters(in: .whitespaces)
            let qty = q.replacingOccurrences(of: #"\s*(x|×|stk\.?|stück)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            return (qty, String(t[r.upperBound...]))
        }
        if let r = t.range(of: #"\s+(x|×)?\s*(\d+)$"#, options: .regularExpression) {
            let qty = t[r].filter(\.isNumber)
            return (String(qty), String(t[..<r.lowerBound]))
        }
        return (nil, t)
    }

    static func key(_ s: String) -> String { split(s).name.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Gänge im Supermarkt (in Laufreihenfolge)
    static let categories: [(name: String, emoji: String, words: [String])] = [
        ("Obst & Gemüse", "🥦", ["apfel", "äpfel", "banane", "birne", "orange", "mandarine", "zitrone", "limette", "tomate", "gurke", "salat",
                              "paprika", "zwiebel", "knoblauch", "kartoffel", "karotte", "möhre", "brokkoli", "zucchini", "pilz", "champignon",
                              "beere", "traube", "avocado", "obst", "gemüse", "kräuter", "petersilie", "schnittlauch", "basilikum", "spinat",
                              "lauch", "kohl", "melone", "kiwi", "ingwer", "radieschen", "mais", "sellerie", "aubergine"]),
        ("Brot & Backwaren", "🥖", ["brot", "brötchen", "toast", "brezel", "breze", "croissant", "semmel", "baguette", "kuchen", "wraps", "tortilla"]),
        ("Milch & Kühlregal", "🥛", ["milch", "joghurt", "jogurt", "quark", "käse", "butter", "sahne", "eier", "schmand", "frischkäse", "mozzarella",
                                  "margarine", "pudding", "skyr", "feta", "parmesan", "hefe"]),
        ("Fleisch & Fisch", "🥩", ["fleisch", "hack", "hähnchen", "huhn", "wurst", "schinken", "salami", "speck", "lachs", "fisch", "steak",
                                "schnitzel", "würstchen", "pute", "aufschnitt", "leberkäse"]),
        ("Vorrat", "🍝", ["nudel", "spaghetti", "pasta", "reis", "mehl", "zucker", "salz", "pfeffer", "öl", "essig", "soße", "sauce", "ketchup",
                        "senf", "mayo", "konserve", "dose", "tomatenmark", "passierte", "gewürz", "brühe", "müsli", "cornflakes",
                        "haferflocken", "honig", "marmelade", "nutella", "kaffee", "tee", "linsen", "bohnen", "backpulver"]),
        ("Tiefkühl", "🧊", ["tk", "tiefkühl", "pizza", "eis", "pommes", "fischstäbchen", "gefroren"]),
        ("Getränke", "🥤", ["wasser", "saft", "cola", "sprudel", "bier", "wein", "limo", "getränk", "schorle", "sprite", "fanta", "radler"]),
        ("Süßes & Snacks", "🍫", ["schokolade", "schoko", "chips", "keks", "gummibär", "süßigkeit", "snack", "riegel", "nüsse", "popcorn", "bonbon"]),
        ("Drogerie", "🧴", ["shampoo", "duschgel", "zahnpasta", "zahnbürste", "deo", "creme", "windel", "toilettenpapier", "klopapier",
                          "taschentücher", "seife", "rasier", "wattepads", "pflaster", "tampons", "binden", "sonnencreme"]),
        ("Haushalt", "🧽", ["spülmittel", "waschmittel", "müllbeutel", "mülltüte", "tüten", "schwamm", "küchenrolle", "alufolie",
                          "frischhaltefolie", "backpapier", "batterie", "glühbirne", "tabs", "reiniger", "weichspüler", "entkalker", "kerzen"]),
        ("Tiere", "🐾", ["futter", "katzen", "hunde", "streu"]),
    ]
    static let other = (name: "Sonstiges", emoji: "🛒")

    /// Reihenfolge zum Prüfen: Spezielles vor Allgemeinem (z. B. „Milchschokolade“ → Süßes)
    private static let matchOrder = ["Tiefkühl", "Süßes & Snacks", "Drogerie", "Haushalt", "Vorrat", "Getränke", "Tiere",
                                     "Milch & Kühlregal", "Fleisch & Fisch", "Brot & Backwaren", "Obst & Gemüse"]

    static func category(_ s: String) -> String {
        let words = split(s).name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        for catName in matchOrder {
            guard let cat = categories.first(where: { $0.name == catName }) else { continue }
            for w in words {
                for k in cat.words where w.hasPrefix(k) || (k.count >= 4 && w.contains(k)) {
                    return cat.name
                }
            }
        }
        return other.name
    }

    static func emoji(ofCategory name: String) -> String {
        categories.first { $0.name == name }?.emoji ?? other.emoji
    }
    static func order(ofCategory name: String) -> Int {
        categories.firstIndex { $0.name == name } ?? categories.count
    }
}

@MainActor
extension AppStore {
    /// Wer bin ich (jan, vanessa, emma, leoni)
    var myKey: String? { activeKid ?? myParentID }

    func personName(_ id: String?) -> String? {
        guard let id else { return nil }
        return FamilyConfig.kid(id)?.name ?? FamilyConfig.parent(id)?.name
    }

    func refreshShopMeta() async {
        guard let r = try? await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.shoppingMeta,
                                                                                 "status": ["needs_action", "completed"]]),
              let items = r[FamilyConfig.shoppingMeta]?["items"]?.array else { return }
        var out: [String: ShopMetaEntry] = [:]
        for i in items {
            guard let metaUID = i["uid"]?.string, let key = i["summary"]?.string else { continue }
            let meta = (i["description"]?.string?.data(using: .utf8)).flatMap { try? JSONDecoder().decode(ShopMeta.self, from: $0) } ?? ShopMeta()
            out[key] = ShopMetaEntry(metaUID: metaUID, meta: meta)
        }
        shopMeta = out

        // Aufräumen: Infos zu Einträgen, die es nicht mehr gibt
        let alive = Set(todoItems.values.flatMap { $0.map(\.uid) })
        if !(todoItems[FamilyConfig.shoppingList] ?? []).isEmpty || todoItems.keys.contains(FamilyConfig.shoppingList) {
            for (key, e) in out where !alive.contains(key) {
                _ = try? await client.call("todo", "remove_item", ["entity_id": FamilyConfig.shoppingMeta, "item": e.metaUID])
                shopMeta[key] = nil
            }
        }
    }

    private func saveShopMeta(_ uid: String, _ meta: ShopMeta) async {
        let json = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let e = shopMeta[uid] {
            shopMeta[uid] = ShopMetaEntry(metaUID: e.metaUID, meta: meta)
            _ = try? await client.call("todo", "update_item", ["entity_id": FamilyConfig.shoppingMeta, "item": e.metaUID, "description": json])
        } else {
            _ = try? await client.call("todo", "add_item", ["entity_id": FamilyConfig.shoppingMeta, "item": uid, "description": json])
            await refreshShopMeta()
        }
    }

    /// Eintragen – mit Doppelt-Prüfung. Rückgabe: Hinweistext, falls nichts Neues angelegt wurde.
    func shopAdd(_ text: String, to list: String) async -> String? {
        let key = ShopText.key(text)
        let items = todoItems[list] ?? []
        if let open = items.first(where: { !$0.done && ShopText.key($0.summary) == key }) {
            let who = personName(shopMeta[open.uid]?.meta.von)
            return "„\(open.summary)“ steht schon drauf" + (who.map { " (von \($0))" } ?? "")
        }
        if let old = items.first(where: { $0.done && ShopText.key($0.summary) == key }) {
            // Alten Eintrag wieder aktivieren statt doppelt anlegen
            if old.summary != text {
                _ = try? await client.call("todo", "update_item", ["entity_id": list, "item": old.uid, "rename": text])
            }
            await setTodo(old, done: false, in: list)
            await saveShopMeta(old.uid, ShopMeta(von: myKey, zeit: HADate.iso.string(from: Date())))
            return nil
        }
        let before = Set(items.map(\.uid))
        await addTodo(text, to: list)
        if let new = (todoItems[list] ?? []).first(where: { !before.contains($0.uid) && $0.summary == text }) {
            await saveShopMeta(new.uid, ShopMeta(von: myKey, zeit: HADate.iso.string(from: Date())))
        }
        return nil
    }

    /// Abhaken: gekauft oder „haben wir noch“
    func shopMark(_ item: TodoItem, in list: String, status: String) async {
        await setTodo(item, done: true, in: list)
        var meta = shopMeta[item.uid]?.meta ?? ShopMeta()
        meta.status = status
        meta.wer = myKey
        meta.wann = HADate.iso.string(from: Date())
        await saveShopMeta(item.uid, meta)
        if status == "vorhanden", let from = meta.von, from != myKey {
            let me = personName(myKey) ?? "Jemand"
            await notify(from, "🏠 Haben wir noch", "\(item.summary) ist noch da – sagt \(me).")
        }
    }

    func shopReopen(_ item: TodoItem, in list: String) async {
        await setTodo(item, done: false, in: list)
        var meta = shopMeta[item.uid]?.meta ?? ShopMeta()
        meta.status = nil; meta.wer = nil; meta.wann = nil
        await saveShopMeta(item.uid, meta)
    }

    func shopRename(_ item: TodoItem, in list: String, to text: String) async {
        do {
            _ = try await client.call("todo", "update_item", ["entity_id": list, "item": item.uid, "rename": text])
        } catch { report(error) }
        await refreshTodos()
    }

    /// „Ich gehe einkaufen“ – alle anderen bekommen eine Mitteilung
    func announceShopping(openCount: Int) async {
        let me = personName(myKey) ?? "Jemand"
        let msg = "\(me) geht jetzt einkaufen – fehlt noch was? Auf der Liste stehen \(openCount) Sachen."
        for p in ["jan", "vanessa", "emma", "leoni"] where p != myKey {
            await notify(p, "🛒 Einkauf", msg)
        }
    }
}

// MARK: - Ansicht

struct ListsView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String = ""
    @State private var newItem = ""
    @State private var hint: String?
    @State private var renameItem: TodoItem?
    @State private var renameText = ""
    @State private var announced = false
    @AppStorage("shopSortAisles") private var byAisle = true
    @AppStorage("shopHistory") private var historyRaw = ""
    @AppStorage("shopSwipeHintSeen") private var hintSeen = false
    @FocusState private var inputFocused: Bool

    private var listID: String { selected.isEmpty ? (store.todoLists.first { $0.entity_id == FamilyConfig.shoppingList }?.entity_id ?? store.todoLists.first?.entity_id ?? "") : selected }
    private var isShopping: Bool { listID == FamilyConfig.shoppingList }
    private var items: [TodoItem] { store.todoItems[listID] ?? [] }
    private var open: [TodoItem] { items.filter { !$0.done } }
    private var done: [TodoItem] {
        items.filter(\.done).sorted { (store.shopMeta[$0.uid]?.meta.wann ?? "") > (store.shopMeta[$1.uid]?.meta.wann ?? "") }
    }

    /// Häufig gekauft (auf diesem Handy gezählt)
    private var history: [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(historyRaw.utf8))) ?? [:]
    }
    private var suggestions: [String] {
        let openKeys = Set(open.map { ShopText.key($0.summary) })
        return history.sorted { $0.value > $1.value }.map(\.key)
            .filter { !openKeys.contains($0.lowercased()) }
            .prefix(12).map { $0 }
    }

    struct ShopGroup: Identifiable {
        let name: String
        let items: [TodoItem]
        var id: String { name }
    }

    private var groups: [ShopGroup] {
        guard isShopping && byAisle else { return [ShopGroup(name: "", items: open)] }
        let g = Dictionary(grouping: open) { ShopText.category($0.summary) }
        var out: [ShopGroup] = []
        for (name, list) in g { out.append(ShopGroup(name: name, items: list)) }
        out.sort { ShopText.order(ofCategory: $0.name) < ShopText.order(ofCategory: $1.name) }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.todoLists.isEmpty {
                    ContentUnavailableView("Keine Listen", systemImage: "checklist",
                                           description: Text("In Home Assistant gibt es noch keine To-do-Liste."))
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .top) { ErrorBanner().padding(.horizontal) }
            .refreshable { await store.refreshTodos() }
            .navigationTitle(store.todoLists.first { $0.entity_id == listID }?.name ?? "Listen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { MealPlanView() } label: { Label("Essensplan", systemImage: "fork.knife") }
                }
                if isShopping {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                Task { await store.announceShopping(openCount: open.count); announced = true }
                            } label: { Label("Ich gehe einkaufen", systemImage: "figure.walk") }
                            Toggle(isOn: $byAisle) { Label("Nach Gängen sortieren", systemImage: "square.grid.3x1.below.line.grid.1x2") }
                            Button { withAnimation { hintSeen = false } } label: {
                                Label("Wischen erklären", systemImage: "hand.draw")
                            }
                            ShareLink(item: shareText) { Label("Liste teilen", systemImage: "square.and.arrow.up") }
                            if !done.isEmpty {
                                Button(role: .destructive) { Task { await store.clearCompleted(in: listID) } } label: {
                                    Label("Erledigte löschen", systemImage: "trash")
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .alert("Ändern", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
                TextField("z. B. 2x Milch", text: $renameText)
                Button("Abbrechen", role: .cancel) { renameItem = nil }
                Button("Sichern") {
                    if let it = renameItem, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await store.shopRename(it, in: listID, to: renameText) }
                    }
                    renameItem = nil
                }
            }
            .alert("Die anderen wissen Bescheid", isPresented: $announced) {
                Button("OK", role: .cancel) {}
            } message: { Text("Alle bekommen eine Mitteilung, dass du einkaufen gehst.") }
        }
    }

    private var list: some View {
        List {
            if store.todoLists.count > 1 {
                Picker("Liste", selection: Binding(get: { listID }, set: { selected = $0 })) {
                    ForEach(store.todoLists) { l in Text(l.name).tag(l.entity_id) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Eingabe + Vorschläge
            Section {
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint).font(.title3)
                    TextField(isShopping ? "z. B. 2x Milch" : "Hinzufügen …", text: $newItem)
                        .focused($inputFocused)
                        .submitLabel(.done)
                        .onSubmit { add(newItem) }
                }
                if let hint {
                    Label(hint, systemImage: "info.circle.fill").font(.caption).foregroundStyle(.orange)
                }
                if isShopping && !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions, id: \.self) { s in
                                Button { add(s) } label: {
                                    Text("+ \(s)").font(.caption.weight(.medium))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }

            if !hintSeen && !open.isEmpty {
                Section {
                    SwipeHintCard(shopping: isShopping) { withAnimation { hintSeen = true } }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            // Offene Einträge
            if open.isEmpty {
                Section { Text("Alles erledigt 🎉").foregroundStyle(.secondary) }
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.items) { item in openRow(item) }
                } header: {
                    if !g.name.isEmpty {
                        Text("\(ShopText.emoji(ofCategory: g.name)) \(g.name)")
                    }
                }
            }

            // Erledigt
            if !done.isEmpty {
                Section {
                    ForEach(done.prefix(30)) { item in doneRow(item) }
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

    // MARK: Zeilen

    private func openRow(_ item: TodoItem) -> some View {
        let parts = ShopText.split(item.summary)
        let meta = store.shopMeta[item.uid]?.meta
        return HStack(spacing: 12) {
            Button { buy(item) } label: {
                Image(systemName: "circle").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let q = parts.qty {
                        Text("\(q)×").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                    }
                    Text(parts.name)
                }
                if let who = store.personName(meta?.von) {
                    Text("von \(who)" + (HADate.parse(meta?.zeit).map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { buy(item) } label: { Label(isShopping ? "Gekauft" : "Erledigt", systemImage: "checkmark") }.tint(.green)
            if isShopping {
                Button { Task { await store.shopMark(item, in: listID, status: "vorhanden") } } label: {
                    Label("Haben wir", systemImage: "house.fill")
                }
                .tint(.teal)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await store.removeTodo(item, from: listID) } } label: {
                Label("Löschen", systemImage: "trash")
            }
            Button { renameText = item.summary; renameItem = item } label: {
                Label("Ändern", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button { buy(item) } label: { Label("Gekauft", systemImage: "checkmark.circle") }
            if isShopping {
                Button { Task { await store.shopMark(item, in: listID, status: "vorhanden") } } label: {
                    Label("Haben wir noch", systemImage: "house")
                }
            }
            Button { renameText = item.summary; renameItem = item } label: { Label("Ändern / Menge", systemImage: "pencil") }
            Button(role: .destructive) { Task { await store.removeTodo(item, from: listID) } } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    private func doneRow(_ item: TodoItem) -> some View {
        let meta = store.shopMeta[item.uid]?.meta
        let had = meta?.status == "vorhanden"
        return Button {
            Task { await store.shopReopen(item, in: listID) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: had ? "house.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(had ? Color.teal : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.summary).strikethrough(!had).foregroundStyle(.secondary)
                    if let who = store.personName(meta?.wer) {
                        Text((had ? "war noch da · " : "gekauft von ") + who
                             + (HADate.parse(meta?.wann).map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await store.removeTodo(item, from: listID) } } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    // MARK: Aktionen

    private func add(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newItem = ""
        inputFocused = true          // Tastatur offen lassen für den nächsten Eintrag
        Task {
            if isShopping {
                hint = await store.shopAdd(text, to: listID)
                if hint != nil {
                    try? await Task.sleep(for: .seconds(4))
                    hint = nil
                }
            } else {
                await store.addTodo(text, to: listID)
            }
        }
    }

    private func buy(_ item: TodoItem) {
        if isShopping {
            var h = history
            let name = ShopText.split(item.summary).name
            h[name, default: 0] += 1
            if let data = try? JSONEncoder().encode(h) { historyRaw = String(decoding: data, as: UTF8.self) }
            Task { await store.shopMark(item, in: listID, status: "gekauft") }
        } else {
            Task { await store.setTodo(item, done: true, in: listID) }
        }
    }

    private var shareText: String {
        var lines: [String] = ["🛒 Einkaufsliste"]
        for g in groups {
            if !g.name.isEmpty {
                lines.append("")
                lines.append(ShopText.emoji(ofCategory: g.name) + " " + g.name)
            }
            for i in g.items { lines.append("• " + i.summary) }
        }
        return lines.joined(separator: "\n")
    }
}


// MARK: - Wisch-Erklärung mit kleiner Animation

struct SwipeHintCard: View {
    let shopping: Bool
    let done: () -> Void

    @State private var offset: CGFloat = 0
    @State private var phase = 0     // 0 = Ruhe, 1 = nach rechts, 2 = nach links

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("So funktioniert die Liste", systemImage: "hand.draw.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Verstanden", action: done).font(.caption.weight(.semibold))
            }
            demoRow
            VStack(alignment: .leading, spacing: 6) {
                hintLine("circle", .secondary, "Kreis antippen", shopping ? "gekauft" : "erledigt")
                hintLine("arrow.right", .green, "Nach rechts wischen", shopping ? "gekauft – weiter wischen = sofort" : "erledigt")
                if shopping {
                    hintLine("house.fill", .teal, "Rechts, zweiter Knopf", "haben wir noch")
                }
                hintLine("arrow.left", .red, "Nach links wischen", "ändern oder löschen")
                hintLine("hand.tap", .secondary, "Lange drücken", "alle Möglichkeiten")
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .task { await loop() }
    }

    private var demoRow: some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text(shopping ? "Gekauft" : "Erledigt")
                }
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.green)
                .opacity(offset > 0 ? 1 : 0)
                HStack(spacing: 6) {
                    Text("Löschen")
                    Image(systemName: "trash")
                }
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .background(Color.red)
                .opacity(offset < 0 ? 1 : 0)
            }
            HStack(spacing: 10) {
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("2× Milch")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .offset(x: offset)
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func hintLine(_ symbol: String, _ color: Color, _ gesture: String, _ result: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            Text(gesture).fontWeight(.semibold)
            Text("→ \(result)").foregroundStyle(.secondary)
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeInOut(duration: 0.6)) { offset = 110 }
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeInOut(duration: 0.5)) { offset = 0 }
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeInOut(duration: 0.6)) { offset = -110 }
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeInOut(duration: 0.5)) { offset = 0 }
            try? await Task.sleep(for: .seconds(1.0))
        }
    }
}
