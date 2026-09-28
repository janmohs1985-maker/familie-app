import SwiftUI

// MARK: - Essensplan
//
// todo.essensplan:      Gericht = Name, Datum = Fälligkeitsdatum, Beschreibung JSON {"mahlzeit":"mittag|abend","zutaten":[…]}
// todo.essenswuensche:  Wunsch = Name, Beschreibung JSON {"von":"emma|leoni|eltern","zeit":"…"}
// Bearbeiten dürfen nur Eltern, Wünsche dürfen alle einreichen.

struct Meal: Identifiable, Hashable {
    let uid: String
    var dish: String
    var date: Date
    var slot: String             // "mittag" oder "abend"
    var ingredients: [String]
    var id: String { uid }
    var slotName: String { slot == "mittag" ? "Mittag" : "Abend" }
    var slotSymbol: String { slot == "mittag" ? "sun.max.fill" : "moon.stars.fill" }
}

struct MealWish: Identifiable, Hashable {
    let uid: String
    let dish: String
    let from: String             // Kind-ID oder "eltern"
    let time: Date?
    var id: String { uid }
    var fromName: String { FamilyConfig.kid(from)?.name ?? "Eltern" }
}

@MainActor
extension AppStore {

    /// Eltern dürfen den Plan bearbeiten (nicht in der Kinder-Vorschau)
    var canEditMeals: Bool { isParent && activeKid == nil }

    func refreshMeals() async {
        guard isLoggedIn else { return }
        do {
            let status = ["needs_action", "completed"]
            let planResp = try await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.mealPlan, "status": status])
            meals = (planResp[FamilyConfig.mealPlan]?["items"]?.array ?? []).compactMap { i in
                guard let uid = i["uid"]?.string, let dish = i["summary"]?.string,
                      let date = HADate.day.date(from: String((i["due"]?.string ?? "").prefix(10))) else { return nil }
                let cfg = ChoreText.json(i["description"]?.string)
                return Meal(uid: uid, dish: dish, date: date, slot: cfg?["mahlzeit"]?.string ?? "abend",
                            ingredients: cfg?["zutaten"]?.array?.compactMap(\.string) ?? [])
            }.sorted { ($0.date, $0.slot == "mittag" ? 0 : 1) < ($1.date, $1.slot == "mittag" ? 0 : 1) }

            let wishResp = try await client.callWithResponse("todo", "get_items", ["entity_id": FamilyConfig.mealWishes, "status": status])
            mealWishes = (wishResp[FamilyConfig.mealWishes]?["items"]?.array ?? []).compactMap { i in
                guard let uid = i["uid"]?.string, let dish = i["summary"]?.string else { return nil }
                let cfg = ChoreText.json(i["description"]?.string)
                return MealWish(uid: uid, dish: dish, from: cfg?["von"]?.string ?? "eltern", time: HADate.parse(cfg?["zeit"]?.string))
            }.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }

            // Aufräumen: Eltern entfernen Einträge, die älter als 7 Tage sind
            if canEditMeals {
                let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date()))!
                for m in meals where m.date < cutoff {
                    _ = try? await client.call("todo", "remove_item", ["entity_id": FamilyConfig.mealPlan, "item": m.uid])
                }
                meals.removeAll { $0.date < cutoff }
            }
        } catch { report(error) }
    }

    func meals(on day: Date) -> [Meal] {
        meals.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    private func mealJSON(_ slot: String, _ ingredients: [String]) -> String {
        ChoreText.jsonString(["mahlzeit": slot, "zutaten": ingredients])
    }

    // MARK: Eltern

    func addMeal(dish: String, date: Date, slot: String, ingredients: [String]) async {
        guard canEditMeals else { return }
        do {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.mealPlan, "item": dish,
                                                       "due_date": HADate.day.string(from: date),
                                                       "description": mealJSON(slot, ingredients)])
        } catch { report(error) }
        await refreshMeals()
    }

    func updateMeal(_ m: Meal) async {
        guard canEditMeals else { return }
        do {
            try await client.call("todo", "update_item", ["entity_id": FamilyConfig.mealPlan, "item": m.uid, "rename": m.dish,
                                                          "due_date": HADate.day.string(from: m.date),
                                                          "description": mealJSON(m.slot, m.ingredients)])
        } catch { report(error) }
        await refreshMeals()
    }

    func deleteMeal(_ m: Meal) async {
        guard canEditMeals else { return }
        meals.removeAll { $0.uid == m.uid }
        do { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.mealPlan, "item": m.uid]) }
        catch { report(error) }
    }

    func addIngredientsToShopping(_ m: Meal) async {
        guard canEditMeals else { return }
        let existing = Set((todoItems[FamilyConfig.shoppingList] ?? []).filter { !$0.done }.map { $0.summary.lowercased() })
        do {
            for z in m.ingredients where !existing.contains(z.lowercased()) {
                try await client.call("todo", "add_item", ["entity_id": FamilyConfig.shoppingList, "item": z])
            }
        } catch { report(error) }
        await refreshTodos()
    }

    func planWish(_ w: MealWish, date: Date, slot: String) async {
        guard canEditMeals else { return }
        await addMeal(dish: w.dish, date: date, slot: slot, ingredients: [])
        _ = try? await client.call("todo", "remove_item", ["entity_id": FamilyConfig.mealWishes, "item": w.uid])
        await refreshMeals()
        if FamilyConfig.kid(w.from) != nil {
            let day = DayText.label(date)
            await notify(w.from, "🍽 Dein Essenswunsch", "\(w.dish) gibt's \(day.hasPrefix("Heute") || day.hasPrefix("Morgen") ? day.lowercased() : "am \(day)") zum \(slot == "mittag" ? "Mittagessen" : "Abendessen")!")
        }
    }

    func rejectWish(_ w: MealWish) async {
        await deleteWish(w)
        if canEditMeals, FamilyConfig.kid(w.from) != nil {
            await notify(w.from, "🍽 Essenswunsch", "\(w.dish) passt diesmal leider nicht in den Plan.")
        }
    }

    // MARK: Alle

    func addWish(_ dish: String) async {
        let from = activeKid ?? "eltern"
        do {
            try await client.call("todo", "add_item", ["entity_id": FamilyConfig.mealWishes, "item": dish,
                                                       "description": ChoreText.jsonString(["von": from, "zeit": HADate.iso.string(from: Date())])])
        } catch { report(error) }
        await refreshMeals()
        if let kid = FamilyConfig.kid(from) {
            await notify("eltern", "🍽 \(kid.name) wünscht sich …", dish)
        }
    }

    func deleteWish(_ w: MealWish) async {
        mealWishes.removeAll { $0.uid == w.uid }
        do { try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.mealWishes, "item": w.uid]) }
        catch { report(error) }
    }
}

// MARK: - Ansicht

enum MealEmoji {
    /// Passendes Emoji zum Gericht (einfache Stichwortsuche)
    static func of(_ dish: String) -> String {
        let d = dish.lowercased()
        let map: [(String, [String])] = [
            ("🍕", ["pizza", "flammkuchen"]), ("🍝", ["spaghetti", "nudel", "pasta", "lasagne", "maultasche", "spätzle", "tortellini", "gnocchi"]),
            ("🍔", ["burger"]), ("🌭", ["wurst", "hot dog", "hotdog", "würstchen"]), ("🌮", ["taco", "wrap", "burrito", "fajita", "quesadilla"]),
            ("🍣", ["sushi"]), ("🍛", ["curry", "chili"]), ("🍚", ["reis", "risotto", "paella"]), ("🍜", ["ramen", "nudelsuppe", "asia", "wok"]),
            ("🍲", ["suppe", "eintopf", "gulasch", "ragout"]), ("🥗", ["salat", "bowl"]), ("🐟", ["fisch", "lachs", "forelle", "thunfisch"]),
            ("🍗", ["hähnchen", "hühn", "chicken", "hendl", "chicken nuggets", "nuggets"]), ("🥩", ["steak", "schnitzel", "braten", "fleisch", "grill"]),
            ("🥔", ["kartoffel", "pommes", "rösti", "püree"]), ("🥞", ["pfannkuchen", "pancake", "crêpe", "crepe", "kaiserschmarrn"]),
            ("🧇", ["waffel"]), ("🍳", ["ei", "rührei", "omelett", "spiegelei"]), ("🥪", ["brot", "sandwich", "toast", "vesper", "abendbrot"]),
            ("🥘", ["auflauf", "gratin", "pfanne"]), ("🥟", ["knödel", "dumpling", "maultaschen"]), ("🧀", ["käse", "raclette", "fondue"]),
            ("🥦", ["gemüse", "brokkoli", "vegetarisch"]),
        ]
        for (emoji, words) in map where words.contains(where: { d.contains($0) }) { return emoji }
        return "🍽️"
    }
}

struct MealPlanView: View {
    @Environment(AppStore.self) private var store
    @State private var wishText = ""
    @State private var editMeal: Meal?
    @State private var newSlot: NewMealSlot?
    @State private var planWish: MealWish?

    struct NewMealSlot: Identifiable {
        let day: Date
        let slot: String
        var id: String { "\(day.timeIntervalSince1970)-\(slot)" }
    }

    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dayStrip(proxy)
                    todayHero
                    wishesSection
                    ForEach(days.dropFirst(), id: \.self) { day in
                        let list = store.meals(on: day)
                        if !list.isEmpty || store.canEditMeals {
                            dayCard(day, list).id(day)
                        }
                    }
                    if !store.canEditMeals && store.meals.filter({ $0.date > Date() }).isEmpty {
                        Text("Für die nächsten Tage ist noch nichts geplant.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Essensplan")
        .refreshable { await store.refreshMeals() }
        .task { await store.refreshMeals() }
        .sheet(item: $editMeal) { m in MealEditSheet(meal: m) }
        .sheet(item: $newSlot) { n in MealEditSheet(meal: nil, day: n.day, presetSlot: n.slot) }
        .sheet(item: $planWish) { w in MealEditSheet(meal: nil, day: Date(), wish: w) }
    }

    // MARK: Tagesleiste

    private func dayStrip(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let count = store.meals(on: day).count
                    let today = Calendar.current.isDateInToday(day)
                    Button {
                        withAnimation { proxy.scrollTo(day, anchor: .top) }
                    } label: {
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2.weight(.semibold))
                            Text(day.formatted(.dateTime.day()))
                                .font(.headline)
                            HStack(spacing: 3) {
                                ForEach(0..<2, id: \.self) { i in
                                    Circle().fill(i < count ? (today ? Color.white : Color.orange) : Color.clear)
                                        .frame(width: 5, height: 5)
                                }
                            }
                        }
                        .frame(width: 46, height: 64)
                        .foregroundStyle(today ? Color.white : Color.primary)
                        .background(today ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id(days.first!)
    }

    // MARK: Heute

    private var todayHero: some View {
        let list = store.meals(on: Date())
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heute").font(.title2.weight(.bold))
                Spacer()
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(["mittag", "abend"], id: \.self) { slot in
                    if let m = list.first(where: { $0.slot == slot }) {
                        heroTile(m)
                    } else {
                        emptyTile(day: Date(), slot: slot, tall: true)
                    }
                }
            }
        }
    }

    private func heroTile(_ m: Meal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(m.slotName, systemImage: m.slotSymbol).font(.caption.weight(.semibold))
                    .foregroundStyle(m.slot == "mittag" ? Color.orange : Color.indigo)
                Spacer()
            }
            Text(MealEmoji.of(m.dish)).font(.system(size: 44))
            Text(m.dish).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            if !m.ingredients.isEmpty {
                Text(m.ingredients.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(
            LinearGradient(colors: m.slot == "mittag" ? [Color.orange.opacity(0.22), Color.yellow.opacity(0.12)]
                                                       : [Color.indigo.opacity(0.22), Color.purple.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture { if store.canEditMeals { editMeal = m } }
        .contextMenu { mealMenu(m) }
    }

    // MARK: Wünsche

    private var wishesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Wünsche", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)
                Spacer()
                if !store.mealWishes.isEmpty {
                    Text("\(store.mealWishes.count)").font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.pink.opacity(0.15), in: Capsule())
                }
            }
            if !store.mealWishes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.mealWishes) { w in wishCard(w) }
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.pink).font(.title3)
                TextField(store.canEditMeals ? "Idee oder Wunsch notieren …" : "Was möchtest du gerne essen?", text: $wishText)
                    .submitLabel(.send)
                    .onSubmit(sendWish)
                if !wishText.isEmpty {
                    Button("Senden", action: sendWish).font(.subheadline.weight(.semibold))
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            if !store.canEditMeals {
                Text("Mama und Papa sehen deinen Wunsch und planen ihn vielleicht ein.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func wishCard(_ w: MealWish) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(MealEmoji.of(w.dish)).font(.title)
                Spacer()
                if store.canEditMeals || w.from == store.activeKid {
                    Button {
                        Task {
                            if store.canEditMeals { await store.rejectWish(w) } else { await store.deleteWish(w) }
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(w.dish).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text("von \(w.fromName)").font(.caption2).foregroundStyle(.secondary)
            if store.canEditMeals {
                Button { planWish = w } label: {
                    Text("Einplanen").font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.pink).controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 150, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Tage

    private func dayCard(_ day: Date, _ list: [Meal]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.day())).font(.title2.weight(.bold))
                if Calendar.current.isDateInTomorrow(day) {
                    Text("morgen").font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(width: 46)
            .padding(.top, 4)
            VStack(spacing: 8) {
                ForEach(["mittag", "abend"], id: \.self) { slot in
                    if let m = list.first(where: { $0.slot == slot }) {
                        mealTile(m)
                    } else if store.canEditMeals {
                        emptyTile(day: day, slot: slot, tall: false)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func mealTile(_ m: Meal) -> some View {
        HStack(spacing: 12) {
            Text(MealEmoji.of(m.dish)).font(.system(size: 30))
                .frame(width: 46, height: 46)
                .background((m.slot == "mittag" ? Color.orange : Color.indigo).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: m.slotSymbol).font(.caption2)
                    Text(m.slotName).font(.caption2.weight(.semibold))
                }
                .foregroundStyle(m.slot == "mittag" ? Color.orange : Color.indigo)
                Text(m.dish).font(.body.weight(.semibold)).lineLimit(2)
                if !m.ingredients.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(m.ingredients, id: \.self) { z in
                                Text(z).font(.caption2)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if store.canEditMeals { editMeal = m } }
        .contextMenu { mealMenu(m) }
    }

    private func emptyTile(day: Date, slot: String, tall: Bool) -> some View {
        Button {
            if store.canEditMeals { newSlot = NewMealSlot(day: day, slot: slot) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: slot == "mittag" ? "sun.max" : "moon.stars")
                Text(store.canEditMeals ? "\(slot == "mittag" ? "Mittag" : "Abend") planen" : "noch offen")
                    .font(.subheadline)
                Spacer(minLength: 0)
                if store.canEditMeals { Image(systemName: "plus") }
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: tall ? 170 : 46, alignment: tall ? Alignment.top : Alignment.center)
            .background(
                RoundedRectangle(cornerRadius: tall ? 20 : 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!store.canEditMeals)
    }

    @ViewBuilder private func mealMenu(_ m: Meal) -> some View {
        if store.canEditMeals {
            Button { editMeal = m } label: { Label("Bearbeiten", systemImage: "pencil") }
            if !m.ingredients.isEmpty {
                Button { Task { await store.addIngredientsToShopping(m) } } label: {
                    Label("Zutaten auf Einkaufsliste", systemImage: "cart.badge.plus")
                }
            }
            Button(role: .destructive) { Task { await store.deleteMeal(m) } } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    private func sendWish() {
        let t = wishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        wishText = ""
        Task { await store.addWish(t) }
    }
}

struct MealRow: View {
    let meal: Meal
    var body: some View {
        HStack(spacing: 12) {
            Text(MealEmoji.of(meal.dish)).font(.title2)
                .frame(width: 38, height: 38)
                .background((meal.slot == "mittag" ? Color.orange : Color.indigo).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.dish).font(.body.weight(.medium))
                Text(meal.ingredients.isEmpty ? meal.slotName : "\(meal.slotName) · \(meal.ingredients.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct MealEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let meal: Meal?
    var day: Date = Date()
    var wish: MealWish? = nil
    var presetSlot: String? = nil

    @State private var dish = ""
    @State private var date = Date()
    @State private var slot = "abend"
    @State private var ingredients = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gericht") {
                    TextField("z. B. Spaghetti Bolognese", text: $dish)
                }
                Section {
                    DatePicker("Tag", selection: $date, displayedComponents: .date)
                    Picker("Mahlzeit", selection: $slot) {
                        Text("Mittag").tag("mittag")
                        Text("Abend").tag("abend")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("Nudeln, Hackfleisch, Tomaten …", text: $ingredients, axis: .vertical)
                } header: { Text("Zutaten (optional)") } footer: {
                    Text("Mit Komma trennen. Im Plan lange auf das Essen drücken → „Zutaten auf Einkaufsliste“.")
                }
            }
            .navigationTitle(wish != nil ? "Wunsch einplanen" : meal == nil ? "Essen planen" : "Essen bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }
                            .disabled(dish.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if let meal {
                    dish = meal.dish; date = meal.date; slot = meal.slot; ingredients = meal.ingredients.joined(separator: ", ")
                } else {
                    dish = wish?.dish ?? ""; date = day
                    if let presetSlot { slot = presetSlot }
                }
            }
        }
    }

    private func save() async {
        saving = true
        let d = dish.trimmingCharacters(in: .whitespaces)
        let z = ingredients.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let wish {
            await store.planWish(MealWish(uid: wish.uid, dish: d, from: wish.from, time: wish.time), date: date, slot: slot)
            if !z.isEmpty, let m = store.meals.first(where: { $0.dish == d && Calendar.current.isDate($0.date, inSameDayAs: date) }) {
                var mm = m; mm.ingredients = z
                await store.updateMeal(mm)
            }
        } else if var m = meal {
            m.dish = d; m.date = date; m.slot = slot; m.ingredients = z
            await store.updateMeal(m)
        } else {
            await store.addMeal(dish: d, date: date, slot: slot, ingredients: z)
        }
        saving = false
        dismiss()
    }
}

/// Karte auf der „Heute“-Seite
struct MealTodayCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let today = store.meals(on: Date())
        NavigationLink {
            MealPlanView()
        } label: {
            Card(title: "Essen", symbol: "fork.knife") {
                VStack(alignment: .leading, spacing: 8) {
                    if today.isEmpty {
                        Text("Heute ist noch nichts geplant").foregroundStyle(.secondary)
                    }
                    ForEach(today) { m in MealRow(meal: m) }
                    HStack {
                        if !store.mealWishes.isEmpty {
                            Label("\(store.mealWishes.count) \(store.mealWishes.count == 1 ? "Wunsch" : "Wünsche")", systemImage: "heart.fill")
                                .font(.caption).foregroundStyle(.pink)
                        }
                        Spacer()
                        Text("Essensplan").font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
