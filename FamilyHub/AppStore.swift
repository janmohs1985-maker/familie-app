import SwiftUI
import Observation

@MainActor
@Observable
final class AppStore {
    // Anmeldung
    var credentials: Credentials?
    var isLoggedIn: Bool { credentials != nil }

    // Daten
    var states: [String: HAState] = [:]
    var calendars: [HACalendar] = []
    var events: [HAEvent] = []
    var todoLists: [HAState] = []
    var todoItems: [String: [TodoItem]] = [:]
    var pictures: [String: UIImage] = [:]

    // UI
    var lastError: String?
    var lastUpdate: Date?
    var busy: Set<String> = []          // Entitäten, die gerade geschaltet werden

    @ObservationIgnored private(set) var client: HAClient!
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        let stored = Keychain.load()
        credentials = stored
        client = HAClient(credentials: stored) { [weak self] creds in
            if let creds { Keychain.save(creds) } else { Keychain.clear() }
            Task { @MainActor in self?.credentials = creds }
        }
    }

    // MARK: - Anmeldung

    func login(server: String, user: String, password: String, mfa: String?, flow: String?) async throws {
        try await client.login(server: server, username: user, password: password, mfaCode: mfa, pendingFlowID: flow)
        await refreshAll()
    }

    func loginWithToken(server: String, token: String) async throws {
        try await client.useLongLivedToken(server: server, token: token)
        await refreshAll()
    }

    func logout() async {
        await client.logout()
        states = [:]; events = []; calendars = []; todoItems = [:]; pictures = [:]
    }

    // MARK: - Laden

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStates()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    func refreshAll() async {
        guard isLoggedIn else { return }
        async let a: () = refreshStates()
        async let b: () = refreshCalendar()
        async let c: () = refreshTodos()
        _ = await (a, b, c)
    }

    func refreshStates() async {
        guard isLoggedIn else { return }
        do {
            let list = try await client.states()
            states = Dictionary(list.map { ($0.entity_id, $0) }, uniquingKeysWith: { a, _ in a })
            todoLists = list.filter { $0.entity_id.hasPrefix("todo.") &&
                (FamilyConfig.todoLists.isEmpty || FamilyConfig.todoLists.contains($0.entity_id)) }
                .sorted { $0.name < $1.name }
            lastUpdate = Date()
            lastError = nil
            await loadPictures()
        } catch { report(error) }
    }

    private func loadPictures() async {
        for p in FamilyConfig.people where pictures[p.id] == nil {
            if let path = states[p.id]?.attr("entity_picture")?.string,
               let img = await client.image(path: path) {
                pictures[p.id] = img
            }
        }
    }

    func refreshCalendar(days: Int = 21) async {
        guard isLoggedIn else { return }
        do {
            var cals = try await client.calendars()
            cals = cals.filter { !FamilyConfig.hiddenCalendars.contains($0.entity_id) &&
                (FamilyConfig.calendars.isEmpty || FamilyConfig.calendars.contains($0.entity_id)) }
            calendars = cals
            let from = Calendar.current.startOfDay(for: Date())
            let to = Calendar.current.date(byAdding: .day, value: days, to: from)!
            var all: [HAEvent] = []
            try await withThrowingTaskGroup(of: [HAEvent].self) { group in
                for c in cals { group.addTask { [client] in try await client!.events(calendar: c.entity_id, from: from, to: to) } }
                for try await ev in group { all += ev }
            }
            events = all.sorted { ($0.start, $0.summary) < ($1.start, $1.summary) }
        } catch { report(error) }
    }

    func refreshTodos() async {
        guard isLoggedIn else { return }
        if todoLists.isEmpty { await refreshStates() }
        for list in todoLists {
            do {
                let resp = try await client.callWithResponse("todo", "get_items", ["entity_id": list.entity_id])
                let items = resp[list.entity_id]?["items"]?.array ?? []
                todoItems[list.entity_id] = items.compactMap { i in
                    guard let uid = i["uid"]?.string, let s = i["summary"]?.string else { return nil }
                    return TodoItem(uid: uid, summary: s, done: i["status"]?.string == "completed", due: i["due"]?.string)
                }
            } catch { report(error) }
        }
    }

    // MARK: - Aktionen

    func perform(_ control: FamilyConfig.Control) async {
        busy.insert(control.id)
        defer { busy.remove(control.id) }
        do {
            switch control.kind {
            case .toggle:
                try await client.call("homeassistant", "toggle", ["entity_id": control.id])
            case .script(let script):
                try await client.call("script", "turn_on", ["entity_id": script])
            case .lock:
                let locked = states[control.id]?.state == "locked"
                try await client.call("lock", locked ? "unlock" : "lock", ["entity_id": control.id])
            }
            try? await Task.sleep(for: .milliseconds(800))
            await refreshStates()
        } catch { report(error) }
    }

    func addTodo(_ text: String, to list: String) async {
        do {
            try await client.call("todo", "add_item", ["entity_id": list, "item": text])
            await refreshTodos()
        } catch { report(error) }
    }

    func setTodo(_ item: TodoItem, done: Bool, in list: String) async {
        // sofort anzeigen, dann synchronisieren
        if var items = todoItems[list], let i = items.firstIndex(of: item) {
            items[i] = TodoItem(uid: item.uid, summary: item.summary, done: done, due: item.due)
            todoItems[list] = items
        }
        do {
            try await client.call("todo", "update_item", ["entity_id": list, "item": item.uid,
                                                           "status": done ? "completed" : "needs_action"])
        } catch { report(error) }
        await refreshTodos()
    }

    func removeTodo(_ item: TodoItem, from list: String) async {
        todoItems[list]?.removeAll { $0.uid == item.uid }
        do { try await client.call("todo", "remove_item", ["entity_id": list, "item": item.uid]) }
        catch { report(error) }
        await refreshTodos()
    }

    func clearCompleted(in list: String) async {
        do { try await client.call("todo", "remove_completed_items", ["entity_id": list]) }
        catch { report(error) }
        await refreshTodos()
    }

    func createEvent(calendar: String, title: String, start: Date, end: Date, allDay: Bool, location: String) async throws {
        var data: [String: Any] = ["entity_id": calendar, "summary": title]
        if allDay {
            // Enddatum ist bei ganztägigen Terminen exklusiv
            let endDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!
            data["start_date"] = HADate.day.string(from: start)
            data["end_date"] = HADate.day.string(from: endDay)
        } else {
            data["start_date_time"] = HADate.serviceDateTime.string(from: start)
            data["end_date_time"] = HADate.serviceDateTime.string(from: end)
        }
        if !location.isEmpty { data["location"] = location }
        try await client.call("calendar", "create_event", data)
        await refreshCalendar()
    }

    /// Kalender, in die neue Termine geschrieben werden können (Feature-Bit 1 = CREATE_EVENT)
    var writableCalendars: [HACalendar] {
        calendars.filter { ((states[$0.entity_id]?.attr("supported_features")?.int ?? 0) & 1) == 1 }
    }

    func color(for calendarID: String) -> Color {
        let idx = calendars.firstIndex { $0.entity_id == calendarID } ?? 0
        return FamilyConfig.calendarPalette[idx % FamilyConfig.calendarPalette.count]
    }

    private func report(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        lastError = error.localizedDescription
    }
}
