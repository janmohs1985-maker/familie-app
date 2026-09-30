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
        let klingel = UNNotificationCategory(identifier: "KLINGEL", actions: [open], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([klingel])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushState.shared.token = hex }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in PushState.shared.lastError = msg }
    }

    /// Auch bei offener App oben einblenden
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
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
        let link = (response.notification.request.content.userInfo["link"] as? String) ?? "heute"
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
