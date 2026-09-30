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
    var eventToShow: HAEvent?                     // Termin antippen → Details/Bearbeiten
    var todoLists: [HAState] = []
    var todoItems: [String: [TodoItem]] = [:]
    var shopMeta: [String: ShopMetaEntry] = [:]
    var doorOpenings: [DoorOpening] = []             // ekey: Emma/Leoni öffnen die Haustür      // Zusatzinfos je Listen-Eintrag (uid)
    var pictures: [String: UIImage] = [:]

    // Aufgaben & Belohnungen
    var chores: [String: [Chore]] = [:]          // je Kind
    var choreTemplates: [ChoreTemplate] = []
    var rewards: [Reward] = []
    var rewardRequests: [RewardRequest] = []
    var currentUserID: String?                    // HA-Benutzer-ID des angemeldeten Benutzers
    var userLookupFailed = false
    var viewAs = "auto"                           // nur für Eltern: "auto", "eltern" oder Kind-ID
    var pointsHistory: [PointsEntry] = []
    var doorbellRings: [DoorbellRing] = []
    var appControls: [AppControl] = []
    var meals: [Meal] = []
    var mealWishes: [MealWish] = []
    var activities: [Activity] = []               // Freizeit der Kinder
    var schoolDocs: [SchoolDoc] = []              // Schulmappe
    var parentTodos: [ParentTodo] = []            // Aufgaben Jan & Vanessa

    // Navigation
    var selectedTab = "heute"
    var route: String?                            // Ziel aus einem Mitteilungs-Link (familie://…)
    var aufgabenMode = "wir"                      // Eltern: "wir" oder "kinder"

    // Dokumente / Scanner (nur Eltern)
    var scans: [ScanFile] = []
    var scanning = false
    var scannerState = "off"                      // off | connecting | ready (Vorwärm-Verbindung)
    var sentScans: Set<String> = []
    @ObservationIgnored var scanCache: [String: Data] = [:]

    // UI
    var lastError: String?
    var lastUpdate: Date?
    var busy: Set<String> = []          // Entitäten, die gerade geschaltet werden

    @ObservationIgnored private(set) var client: HAClient!
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var freshPictures: Set<String> = []

    init() {
        let stored = Keychain.load()
        credentials = stored
        pictures = AvatarCache.loadAll()
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
        chores = [:]; choreTemplates = []; rewards = []; rewardRequests = []; pointsHistory = []; doorbellRings = []; appControls = []; meals = []; mealWishes = []; activities = []; schoolDocs = []; parentTodos = []; selectedTab = "heute"
        scans = []; sentScans = []; scanCache = [:]
        currentUserID = nil; userLookupFailed = false; viewAs = "auto"
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
        await refreshStates()
        async let b: () = refreshCalendar()
        async let c: () = refreshTodos()
        async let d: () = refreshChores()
        async let e: () = loadCurrentUser()
        async let f: () = refreshDoorbell()
        async let g: () = refreshControls()
        async let h: () = refreshMeals()
        async let i: () = refreshFreizeit()
        async let j: () = refreshSchool()
        async let k: () = refreshParentTodos()
        async let l: () = refreshDoorOpenings()
        _ = await (b, c, d, e, f, g, h, i, j, k, l)
    }

    func refreshStates() async {
        guard isLoggedIn else { return }
        do {
            let list = try await client.states()
            states = Dictionary(list.map { ($0.entity_id, $0) }, uniquingKeysWith: { a, _ in a })
            todoLists = list.filter { $0.entity_id.hasPrefix("todo.") &&
                !FamilyConfig.systemTodoLists.contains($0.entity_id) &&
                (FamilyConfig.todoLists.isEmpty || FamilyConfig.todoLists.contains($0.entity_id)) }
                .sorted { $0.name < $1.name }
            lastUpdate = Date()
            lastError = nil
            await loadPictures()
        } catch { report(error) }
    }

    private func loadPictures() async {
        // einmal pro App-Start frisch laden (zwischengespeicherte Bilder werden bis dahin angezeigt)
        for p in FamilyConfig.people where !freshPictures.contains(p.id) {
            if let path = states[p.id]?.attr("entity_picture")?.string,
               let img = await client.image(path: path) {
                pictures[p.id] = img
                freshPictures.insert(p.id)
                AvatarCache.save(img, for: p.id)
            }
        }
    }

    func refreshCalendar(days: Int = 120) async {
        guard isLoggedIn else { return }
        do {
            var cals = try await client.calendars()
            cals = cals.filter { !FamilyConfig.hiddenCalendars.contains($0.entity_id) &&
                (FamilyConfig.calendars.isEmpty || FamilyConfig.calendars.contains($0.entity_id)) }
            if !FamilyConfig.calendars.isEmpty {            // Reihenfolge wie in FamilyConfig
                cals.sort { (FamilyConfig.calendars.firstIndex(of: $0.entity_id) ?? 99) < (FamilyConfig.calendars.firstIndex(of: $1.entity_id) ?? 99) }
            }
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
                let resp = try await client.callWithResponse("todo", "get_items", ["entity_id": list.entity_id,
                                                                                    "status": ["needs_action", "completed"]])
                let items = resp[list.entity_id]?["items"]?.array ?? []
                todoItems[list.entity_id] = items.compactMap { i in
                    guard let uid = i["uid"]?.string, let s = i["summary"]?.string else { return nil }
                    return TodoItem(uid: uid, summary: s, done: i["status"]?.string == "completed", due: i["due"]?.string)
                }
            } catch { report(error) }
        }
        await refreshShopMeta()
    }

    // MARK: - Aktionen

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

    func createEvent(calendar: String, title: String, start: Date, end: Date, allDay: Bool, location: String, notes: String = "") async throws {
        if canEditEvents {
            try await calendarWrite((["aktion": "neu", "kalender": calendar, "titel": title, "ort": location, "notiz": notes] as [String: Any])
                .merging(Self.eventTimes(start: start, end: end, allDay: allDay)) { $1 })
            return
        }
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

    /// Termine ändern/löschen dürfen nur Jan und Vanessa (läuft über Family Hub direkt am Kalender-Server)
    var canEditEvents: Bool { myParentID != nil && activeKid == nil }

    static func eventTimes(start: Date, end: Date, allDay: Bool) -> [String: Any] {
        if allDay {
            // Enddatum ist bei ganztägigen Terminen exklusiv
            let endDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(end, start)))!
            return ["ganztags": true, "start": HADate.day.string(from: start), "ende": HADate.day.string(from: endDay)]
        }
        return ["ganztags": false, "start": HADate.iso.string(from: start), "ende": HADate.iso.string(from: max(end, start))]
    }

    func calendarWrite(_ data: [String: Any]) async throws {
        guard let token = PushState.shared.token ?? UserDefaults.standard.string(forKey: "pushToken") else {
            throw HAError.unexpected("Bitte zuerst Mitteilungen für die Familie-App erlauben – daran erkennt Family Hub dein iPhone.")
        }
        var d = data
        d["token"] = token
        let r = try await client.callWithResponse("rest_command", "familie_kalender", ["daten": d], timeout: 45)
        let c = r["content"] ?? r
        if c["ok"]?.string != "true" {
            throw HAError.unexpected(c["error"]?.string ?? "Kalender nicht erreichbar.")
        }
        await refreshCalendar()
    }

    func updateEvent(_ e: HAEvent, calendar: String, title: String, start: Date, end: Date, allDay: Bool,
                     location: String, notes: String) async throws {
        guard let uid = e.uid else { throw HAError.unexpected("Dieser Termin lässt sich nicht bearbeiten.") }
        try await calendarWrite((["aktion": "aendern", "kalender": e.calendarID, "ziel": calendar, "uid": uid,
                                  "titel": title, "ort": location, "notiz": notes] as [String: Any])
            .merging(Self.eventTimes(start: start, end: end, allDay: allDay)) { $1 })
    }

    func deleteEvent(_ e: HAEvent) async throws {
        guard let uid = e.uid else { throw HAError.unexpected("Dieser Termin lässt sich nicht löschen.") }
        try await calendarWrite(["aktion": "loeschen", "kalender": e.calendarID, "uid": uid])
    }

    /// Kalender, in die neue Termine geschrieben werden können (Feature-Bit 1 = CREATE_EVENT)
    var writableCalendars: [HACalendar] {
        calendars.filter { ((states[$0.entity_id]?.attr("supported_features")?.int ?? 0) & 1) == 1 }
    }

    func color(for calendarID: String) -> Color {
        if let c = FamilyConfig.calendarColors[calendarID] { return c }
        let idx = calendars.firstIndex { $0.entity_id == calendarID } ?? 0
        return FamilyConfig.calendarPalette[idx % FamilyConfig.calendarPalette.count]
    }

    func report(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        lastError = error.localizedDescription
    }
}
