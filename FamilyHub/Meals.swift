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

struct MealPlanView: View {
    @Environment(AppStore.self) private var store
    @State private var wishText = ""
    @State private var editMeal: Meal?
    @State private var newMealDay: Date?
    @State private var planWish: MealWish?

    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        List {
            // Wünsche
            Section {
                ForEach(store.mealWishes) { w in
                    HStack(spacing: 12) {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.dish).font(.body.weight(.medium))
                            Text("von \(w.fromName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.canEditMeals {
                            Button("Einplanen") { planWish = w }
                                .buttonStyle(.borderedProminent).font(.caption)
                            Button { Task { await store.rejectWish(w) } } label: {
                                Image(systemName: "xmark.circle.fill").font(.title3)
                            }
                            .buttonStyle(.borderless).tint(.secondary)
                        } else if w.from == store.activeKid {
                            Button { Task { await store.deleteWish(w) } } label: {
                                Image(systemName: "xmark.circle.fill").font(.title3)
                            }
                            .buttonStyle(.borderless).tint(.secondary)
                        }
                    }
                }
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint).font(.title3)
                    TextField("Essenswunsch eintragen …", text: $wishText)
                        .submitLabel(.send)
                        .onSubmit(sendWish)
                }
            } header: {
                Text("Wünsche")
            } footer: {
                if !store.canEditMeals { Text("Mama und Papa sehen deinen Wunsch und planen ihn vielleicht ein.") }
            }

            // Plan für 14 Tage
            ForEach(days, id: \.self) { day in
                let list = store.meals(on: day)
                if !list.isEmpty || store.canEditMeals {
                    Section(DayText.label(day)) {
                        ForEach(list) { m in
                            MealRow(meal: m)
                                .contentShape(Rectangle())
                                .onTapGesture { if store.canEditMeals { editMeal = m } }
                                .swipeActions(edge: .trailing) {
                                    if store.canEditMeals {
                                        Button(role: .destructive) { Task { await store.deleteMeal(m) } } label: {
                                            Label("Löschen", systemImage: "trash")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if store.canEditMeals && !m.ingredients.isEmpty {
                                        Button { Task { await store.addIngredientsToShopping(m) } } label: {
                                            Label("Einkaufen", systemImage: "cart.badge.plus")
                                        }
                                        .tint(.green)
                                    }
                                }
                        }
                        if store.canEditMeals && list.count < 2 {
                            Button { newMealDay = day } label: {
                                Label("Essen planen", systemImage: "plus")
                            }
                        }
                    }
                }
            }
            if !store.canEditMeals && store.meals.isEmpty {
                Text("Noch nichts geplant.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Essensplan")
        .refreshable { await store.refreshMeals() }
        .task { await store.refreshMeals() }
        .sheet(item: $editMeal) { m in MealEditSheet(meal: m) }
        .sheet(isPresented: Binding(get: { newMealDay != nil }, set: { if !$0 { newMealDay = nil } })) {
            MealEditSheet(meal: nil, day: newMealDay ?? Date())
        }
        .sheet(item: $planWish) { w in MealEditSheet(meal: nil, day: Date(), wish: w) }
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
            Image(systemName: meal.slotSymbol)
                .foregroundStyle(meal.slot == "mittag" ? Color.orange : Color.indigo)
                .frame(width: 24)
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
                    Text("Mit Komma trennen. Im Plan nach rechts wischen → „Einkaufen“ setzt sie auf die Einkaufsliste.")
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
