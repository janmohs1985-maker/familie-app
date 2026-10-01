import SwiftUI
import UIKit
import UserNotifications

// MARK: - Mitteilungen direkt in der Familie-App
//
// 1. Push über Apple: Die App holt sich ein Push-Token und meldet es mit der Geräteliste an Family Hub.
//    Das Skript „Familie: Mitteilung senden“ schickt normale Mitteilungen dann über Family Hub an die App,
//    Kritisches (Rauch) und Mitteilungen mit Bild weiter über die Home-Assistant-App.
// 2. Lokale Erinnerungen: plant die App selbst (Klassenarbeit, Müll am Vorabend) – ohne Server.

@MainActor @Observable
final class PushState {
    static let shared = PushState()
    var token: String?
    var authorized = false
    var denied = false
    var pendingLink: String?
    var lastError: String?

    /// Einmal nach dem Anmelden: um Erlaubnis fragen (nur beim ersten Mal sichtbar) und bei Apple registrieren
    func setup() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refresh()
        UIApplication.shared.registerForRemoteNotifications()
    }

    func refresh() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        authorized = [.authorized, .provisional, .ephemeral].contains(s.authorizationStatus)
        denied = s.authorizationStatus == .denied
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Klingel-Mitteilung (lange drücken = Live-Bild): „Öffnen“ – iOS verlangt Face ID/Code, dann summt die Tür,
        // ohne dass die App aufgeht. „App öffnen“ zeigt die Haustür-Seite.
        let open = UNNotificationAction(identifier: "oeffnen", title: "🔓 Öffnen",
                                        options: [.authenticationRequired, .destructive])
        let talk = UNNotificationAction(identifier: "sprechen", title: "🎙 Sprechen", options: [.foreground])
        let klingel = UNNotificationCategory(identifier: "KLINGEL", actions: [talk, open], intentIdentifiers: [], options: [])
        // Aufgabe vom Partner (lange drücken): annehmen – auch mit Datum oder Nachricht – oder zurückgeben
        let aufgabe = UNNotificationCategory(identifier: "AUFGABE", actions: [
            UNNotificationAction(identifier: "a_annehmen", title: "👍 Annehmen", options: []),
            UNNotificationAction(identifier: "a_heute", title: "📅 Mache ich heute", options: []),
            UNNotificationAction(identifier: "a_morgen", title: "📅 Mache ich morgen", options: []),
            UNTextInputNotificationAction(identifier: "a_nachricht", title: "💬 Annehmen mit Nachricht …", options: [],
                                          textInputButtonTitle: "Senden", textInputPlaceholder: "Nachricht"),
            UNTextInputNotificationAction(identifier: "a_zurueck", title: "↩️ Zurückgeben …", options: [.destructive],
                                          textInputButtonTitle: "Zurückgeben", textInputPlaceholder: "Warum? (optional)"),
        ], intentIdentifiers: [], options: [])
        // Jemand ist einkaufen (lange drücken): etwas zum Mitbringen dazuschreiben
        let mitbringen = UNNotificationCategory(identifier: "MITBRINGEN", actions: [
            UNTextInputNotificationAction(identifier: "mb_text", title: "➕ Etwas mitbringen …", options: [],
                                          textInputButtonTitle: "Senden", textInputPlaceholder: "z. B. Milch, Brot"),
        ], intentIdentifiers: [], options: [])
        // „Essen ist fertig!“ (lange drücken): kurz antworten
        let rufen = UNNotificationCategory(identifier: "RUFEN", actions: [
            UNNotificationAction(identifier: "r_komme", title: "👍 Komme!", options: []),
            UNNotificationAction(identifier: "r_5", title: "⏱ 5 Minuten", options: []),
            UNTextInputNotificationAction(identifier: "r_text", title: "💬 Antworten …", options: [],
                                          textInputButtonTitle: "Senden", textInputPlaceholder: "Antwort"),
        ], intentIdentifiers: [], options: [])
        // Tesla eingesteckt (lange drücken): wie laden?
        let laden = UNNotificationCategory(identifier: "LADEN", actions: [
            UNNotificationAction(identifier: "l_nacht", title: "🌙 Ab 0 Uhr (Nachtstrom)", options: []),
            UNNotificationAction(identifier: "l_sonne", title: "☀️ Nur mit Sonne", options: []),
            UNNotificationAction(identifier: "l_sofort", title: "⚡ Sofort laden", options: []),
        ], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([klingel, aufgabe, mitbringen, rufen, laden])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "pushToken")   // für Antworten aus Mitteilungen, wenn die App nicht läuft
        Task { @MainActor in PushState.shared.token = hex }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in PushState.shared.lastError = msg }
    }

    /// Auch bei offener App oben einblenden
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in NotificationHistory.shared.arrived += 1 }
        completionHandler([.banner, .list, .sound])
    }

    /// Antippen: zur passenden Stelle springen (Feld „link“, z. B. essen, aufgaben, einkauf)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "oeffnen" {
            // im Hintergrund öffnen – die App muss dafür nicht aufgehen
            Task {
                await DoorOpener.openFromNotification()
                completionHandler()
            }
            return
        }
        if response.actionIdentifier.hasPrefix("r_") {
            let link = response.notification.request.content.userInfo["link"] as? String ?? ""
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            let answer = response.actionIdentifier == "r_5" ? "⏱ 5 Minuten" : (response.actionIdentifier == "r_komme" ? "👍 Komme!" : text)
            Task {
                await CallBridge.answer(id: String(link.dropFirst("rufen_".count)), text: answer)
                completionHandler()
            }
            return
        }
        if response.actionIdentifier.hasPrefix("l_") {
            let wahl = String(response.actionIdentifier.dropFirst(2))
            Task {
                _ = try? await CallBridge.client().callWithResponse("rest_command", "familie_laden",
                    ["daten": ["wahl": wahl, "token": CallBridge.token]], timeout: 30)
                completionHandler()
            }
            return
        }
        if response.actionIdentifier == "mb_text" {
            let info = response.notification.request.content.userInfo
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            let link = info["link"] as? String ?? ""
            Task {
                await ShoppingFromNotification.send(text: text, shopper: String(link.dropFirst("mitbringen_".count)))
                completionHandler()
            }
            return
        }
        if response.actionIdentifier.hasPrefix("a_") {
            let info = response.notification.request.content.userInfo
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            let action = response.actionIdentifier
            Task {
                await TodoFromNotification.answer(action: action, link: info["link"] as? String ?? "",
                                                  sender: info["von"] as? String ?? "", text: text)
                completionHandler()
            }
            return
        }
        var link = (response.notification.request.content.userInfo["link"] as? String) ?? "heute"
        if response.actionIdentifier == "sprechen" { link = "klingel_gespraech" }
        Task { @MainActor in PushState.shared.pendingLink = link }
        completionHandler()
    }
}

/// Haustür aus der Mitteilung öffnen (App läuft dabei evtl. nur im Hintergrund)
enum DoorOpener {
    static func openFromNotification() async {
        let client = HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
        let ok: Bool
        do {
            try await client.call("button", "press", ["entity_id": QuickConfig.frontDoor])
            ok = true
        } catch {
            ok = false
        }
        let c = UNMutableNotificationContent()
        c.title = ok ? "🔓 Haustür geöffnet" : "⚠️ Haustür nicht geöffnet"
        c.body = ok ? "Der Türöffner hat gesummt." : "Home Assistant war nicht erreichbar – bitte in der App öffnen."
        c.sound = ok ? nil : .default
        c.userInfo = ["link": "haustuer"]
        c.threadIdentifier = "haustuer"
        let req = UNNotificationRequest(identifier: "familie.tuer." + UUID().uuidString, content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}

/// „Bitte mitbringen“ aus der Mitteilung: Family Hub trägt es ein und sagt dem, der einkauft, Bescheid
enum ShoppingFromNotification {
    static func send(text: String, shopper: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let token = UserDefaults.standard.string(forKey: "pushToken") ?? ""
        let client = HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
        var ok = false
        var err = "Home Assistant war nicht erreichbar."
        do {
            let r = try await client.callWithResponse("rest_command", "familie_mitbringen",
                                                      ["daten": ["token": token, "text": t, "fuer": shopper]], timeout: 40)
            let c = r["content"] ?? r
            if c["error"]?.string == nil, !(c["eingetragen"]?.array ?? []).isEmpty { ok = true }
            else { err = c["error"]?.string ?? err }
        } catch {}
        let c = UNMutableNotificationContent()
        let name = FamilyConfig.parent(shopper)?.name ?? FamilyConfig.kid(shopper)?.name ?? ""
        if ok {
            c.title = "✅ Auf der Einkaufsliste"
            c.body = t + (name.isEmpty ? "" : " – \(name) weiß Bescheid.")
        } else {
            c.title = "⚠️ Nicht eingetragen"
            c.body = err + " Bitte in der App eintragen."
            c.sound = .default
        }
        c.userInfo = ["link": "einkauf"]
        c.threadIdentifier = "einkauf"
        let req = UNNotificationRequest(identifier: "familie.mitbringen." + UUID().uuidString, content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}

/// Aufgabe direkt aus der Mitteilung beantworten (App läuft evtl. nur im Hintergrund)
enum TodoFromNotification {
    static func answer(action: String, link: String, sender: String, text: String) async {
        guard link.hasPrefix("aufgabe_") else { return }
        let uid = String(link.dropFirst("aufgabe_".count))
        // ich = der Elternteil, der die Aufgabe NICHT geschickt hat
        guard let me = FamilyConfig.parents.first(where: { $0.id != sender })?.id, !sender.isEmpty else { return }
        let cal = Calendar.current
        let art: TodoAntwort.Art
        switch action {
        case "a_heute": art = .annehmen(Date())
        case "a_morgen": art = .annehmen(cal.date(byAdding: .day, value: 1, to: Date()))
        case "a_zurueck": art = .zurueck
        default: art = .annehmen(nil)
        }
        let client = HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
        let err = await TodoAntwort.senden(client: client, uid: uid, me: me, art: art, text: text)
        let c = UNMutableNotificationContent()
        let name = FamilyConfig.parent(sender)?.name ?? ""
        if let err {
            c.title = "⚠️ Antwort nicht gesendet"
            c.body = err + " – bitte in der App antworten."
            c.sound = .default
        } else {
            c.title = action == "a_zurueck" ? "↩️ Zurückgegeben" : "👍 Angenommen"
            c.body = "\(name) weiß Bescheid."
        }
        c.userInfo = ["link": "wir"]
        c.threadIdentifier = "wir"
        let req = UNNotificationRequest(identifier: "familie.aufgabe." + UUID().uuidString, content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Verlauf (Glocke auf „Heute“)
//
// Family Hub schreibt jede Mitteilung pro Person mit (14 Tage). Abgefragt wird mit dem eigenen Push-Token –
// so bekommt jedes iPhone nur die Mitteilungen seiner Person.

struct HistoryEntry: Identifiable, Hashable {
    let date: Date
    let title: String
    let text: String
    let link: String
    let from: String
    let fromName: String
    let symbol: String
    let color: String
    let image: String
    var id: String { "\(date.timeIntervalSince1970)|\(title)|\(text)" }
}

@MainActor @Observable
final class NotificationHistory {
    static let shared = NotificationHistory()
    private static let readKey = "verlaufGelesenBis"
    var entries: [HistoryEntry] = []
    var loaded = false
    var error: String?
    var arrived = 0                      // Mitteilung kam bei offener App → neu laden
    private(set) var readUntil: Double = UserDefaults.standard.double(forKey: NotificationHistory.readKey)

    var unread: Int { entries.filter { $0.date.timeIntervalSince1970 > readUntil }.count }

    func isUnread(_ e: HistoryEntry) -> Bool { e.date.timeIntervalSince1970 > readUntil }

    func markAllRead() {
        guard let newest = entries.first?.date.timeIntervalSince1970, newest > readUntil else { return }
        readUntil = newest
        UserDefaults.standard.set(newest, forKey: Self.readKey)
    }

    func load(_ store: AppStore) async {
        guard store.isLoggedIn else { return }
        guard let token = PushState.shared.token else {
            error = "Mitteilungen sind auf diesem iPhone noch nicht eingeschaltet."
            loaded = true
            return
        }
        do {
            let r = try await store.client.callWithResponse("rest_command", "familie_verlauf", ["daten": ["token": token]], timeout: 20)
            let c = r["content"] ?? r
            error = (c["eintraege"]?.array ?? []).isEmpty ? c["error"]?.string : nil
            entries = (c["eintraege"]?.array ?? []).compactMap { e in
                guard let t = e["t"]?.double else { return nil }
                return HistoryEntry(date: Date(timeIntervalSince1970: t),
                                    title: e["titel"]?.string ?? "", text: e["text"]?.string ?? "",
                                    link: e["link"]?.string ?? "heute", from: e["von"]?.string ?? "",
                                    fromName: e["von_name"]?.string ?? "", symbol: e["symbol"]?.string ?? "",
                                    color: e["farbe"]?.string ?? "", image: e["bild"]?.string ?? "")
            }
        } catch {
            self.error = "Verlauf nicht erreichbar"
        }
        loaded = true
    }
}

struct NotificationHistoryButton: View {
    @Environment(AppStore.self) private var store
    @State private var history = NotificationHistory.shared
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: history.unread > 0 ? "bell.badge.fill" : "bell")
                .symbolRenderingMode(history.unread > 0 ? .palette : .monochrome)
                .foregroundStyle(history.unread > 0 ? Color.red : Color.accentColor, Color.accentColor)
        }
        .accessibilityLabel(history.unread > 0 ? "Mitteilungen, \(history.unread) neu" : "Mitteilungen")
        .sheet(isPresented: $show) { NotificationHistoryView() }
        .task { await history.load(store) }
        .onChange(of: history.arrived) { _, _ in Task { await history.load(store) } }
        .onChange(of: PushState.shared.token) { _, _ in Task { await history.load(store) } }
    }
}

struct NotificationHistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var history = NotificationHistory.shared
    @State private var readBefore: Double = 0

    struct DayGroup: Identifiable {
        let day: Date
        let items: [HistoryEntry]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: history.entries) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { DayGroup(day: $0, items: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let err = history.error, history.entries.isEmpty {
                    Label(err, systemImage: "bell.slash").foregroundStyle(.secondary)
                } else if history.loaded && history.entries.isEmpty {
                    Label("Noch keine Mitteilungen", systemImage: "bell").foregroundStyle(.secondary)
                }
                ForEach(days) { g in
                    Section(dayTitle(g.day)) {
                        ForEach(g.items) { e in
                            Button { open(e) } label: { row(e) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if !history.entries.isEmpty {
                    Text("Es werden die Mitteilungen der letzten 14 Tage aufgehoben.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Mitteilungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .refreshable { await history.load(store) }
            .task {
                readBefore = history.readUntil
                await history.load(store)
                history.markAllRead()
            }
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Heute" }
        if cal.isDateInYesterday(d) { return "Gestern" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func personPicture(_ key: String) -> (UIImage?, Color)? {
        if let p = FamilyConfig.parent(key) { return (store.pictures[p.person], p.color) }
        if let k = FamilyConfig.kid(key) { return (store.pictures[k.person], k.color) }
        return nil
    }

    private func row(_ e: HistoryEntry) -> some View {
        let fresh = e.date.timeIntervalSince1970 > readBefore
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if !e.from.isEmpty, let pic = personPicture(e.from) {
                    Avatar(image: pic.0, name: e.fromName.isEmpty ? e.from : e.fromName, color: pic.1,
                           initialFont: .headline, ring: 0)
                } else {
                    let tint = Color(hexString: e.color) ?? .indigo
                    Image(systemName: e.symbol.isEmpty ? "bell.fill" : e.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(e.fromName.isEmpty ? e.title : e.fromName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(e.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if fresh {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                }
                if !e.fromName.isEmpty, !e.title.isEmpty {
                    Text(e.title).font(.subheadline).lineLimit(2)
                }
                if !e.text.isEmpty {
                    Text(e.text).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            if let url = URL(string: e.image), !e.image.isEmpty {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func open(_ e: HistoryEntry) {
        dismiss()
        let link = e.link
        let store = store
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if let url = URL(string: "familie://" + link) { store.openLink(url) }
        }
    }
}

extension Color {
    /// „#FF9500“ → Farbe
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Lokale Erinnerungen

enum LocalReminders {
    static let prefix = "familie.lokal."
    static let examsKey = "erinnerungKlassenarbeit"
    static let wasteKey = "erinnerungMuell"

    /// Plant alle lokalen Erinnerungen neu (nach jedem Aktualisieren)
    @MainActor
    static func reschedule(_ store: AppStore) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        guard store.isLoggedIn, PushState.shared.authorized else { return }

        let defaults = UserDefaults.standard
        defaults.register(defaults: [examsKey: true, wasteKey: true])
        let cal = Calendar.current
        let now = Date()
        var requests: [UNNotificationRequest] = []

        func at(_ day: Date, hour: Int) -> Date? {
            cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        }
        func add(_ id: String, _ date: Date, _ title: String, _ body: String, link: String) {
            guard date > now else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            c.threadIdentifier = link
            c.userInfo = ["link": link]
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            requests.append(UNNotificationRequest(identifier: prefix + id, content: c,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }

        // Klassenarbeiten: am Vorabend um 18 Uhr
        if defaults.bool(forKey: examsKey) {
            if !ExamsModel.shared.loaded { await ExamsModel.shared.load(store) }
            let own = store.activeKid ?? store.detectedKid
            for e in ExamsModel.shared.items where e.upcoming && e.daysLeft >= 1 && e.daysLeft <= 21 {
                if let own, e.kid != own { continue }
                guard let before = cal.date(byAdding: .day, value: -1, to: e.date), let when = at(before, hour: 18) else { continue }
                let kidName = FamilyConfig.kid(e.kid)?.name ?? ""
                let isKid = own != nil
                let title = "Morgen: \(e.title)" + (isKid || kidName.isEmpty ? "" : " · \(kidName)")
                let body: String
                if e.prepared {
                    body = isKid ? "Du hast schon gelernt – viel Erfolg!" : "\(kidName) hat schon gelernt."
                } else {
                    body = (e.topic.isEmpty ? "" : e.topic + " – ") + (isKid ? "Hast du schon gelernt?" : "Schon gelernt?")
                }
                add("arbeit." + e.id, when, "📝 " + title, body, link: "schule")
            }
        }

        // Müll: am Vorabend um 19 Uhr (nur Eltern)
        if defaults.bool(forKey: wasteKey), store.isParent, store.activeKid == nil {
            for w in FamilyConfig.waste {
                guard let s = store.states[w.id], let day = HADate.day.date(from: s.state),
                      let before = cal.date(byAdding: .day, value: -1, to: day), let when = at(before, hour: 19) else { continue }
                add("muell." + w.id, when, "🗑 \(w.name) rausstellen", "Abholung morgen früh", link: "heute")
            }
        }

        for r in requests { try? await center.add(r) }
    }
}

// MARK: - Einstellungen → Mitteilungen

struct NotificationSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var push = PushState.shared
    @AppStorage(LocalReminders.examsKey) private var exams = true
    @AppStorage(LocalReminders.wasteKey) private var waste = true
    @State private var testResult: String?
    @State private var testing = false

    private var parent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        Section {
            if push.denied {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Mitteilungen sind aus – in den iPhone-Einstellungen einschalten", systemImage: "bell.slash.fill")
                }
                .foregroundStyle(.orange)
            } else {
                LabeledContent {
                    Text(push.token != nil && push.authorized ? "an" : "wird eingerichtet …")
                        .foregroundStyle(push.token != nil && push.authorized ? Color.green : .secondary)
                } label: {
                    Label("Mitteilungen der Familie-App", systemImage: "bell.badge.fill")
                }
            }
            Toggle(isOn: $exams) {
                Label("Klassenarbeit am Vorabend", systemImage: "pencil.and.list.clipboard")
            }
            if parent {
                Toggle(isOn: $waste) {
                    Label("Mülltonne am Vorabend", systemImage: "trash")
                }
            }
            if parent {
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack {
                        Label("Test-Mitteilung an mich", systemImage: "paperplane")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || push.token == nil)
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mitteilungen")
        } footer: {
            Text("Nachrichten zu Essen, Aufgaben, Wäsche & Co. kommen direkt von „Familie“. Rauchalarm und Klingel-Fotos kommen weiter über die Home-Assistant-App.")
        }
        .onChange(of: exams) { _, _ in Task { await LocalReminders.reschedule(store) } }
        .onChange(of: waste) { _, _ in Task { await LocalReminders.reschedule(store) } }
        .task { await push.refresh() }
    }

    private func sendTest() async {
        testing = true
        defer { testing = false }
        await store.reportDevice(force: true)
        let me = store.myParentID ?? store.detectedKid ?? ""
        let daten: [String: Any] = ["an": me, "titel": "👋 Test", "nachricht": "So sehen Mitteilungen der Familie-App aus.", "link": "heute"]
        do {
            let r = try await store.client.callWithResponse("rest_command", "familie_push", ["daten": daten], timeout: 30)
            let c = r["content"] ?? r
            let sent = c["gesendet"]?.int ?? 0
            if sent > 0 {
                testResult = "Gesendet – kommt gleich an."
            } else if let f = c["fehler"]?.array?.first?.string {
                testResult = "Nicht gesendet: \(f)"
            } else if c["grund"]?.string == "aus" {
                testResult = "Family Hub hat noch keinen Push-Schlüssel."
            } else {
                testResult = "Nicht gesendet – dieses iPhone ist noch nicht angemeldet."
            }
        } catch {
            testResult = "Fehler: \(error.localizedDescription)"
        }
    }
}
