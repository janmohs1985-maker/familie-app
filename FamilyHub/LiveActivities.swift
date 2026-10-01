import ActivityKit
import Foundation

// MARK: - Live-Aktivität: Wäsche & Spülmaschine auf dem Sperrbildschirm / in der Dynamic Island
//
// Family Hub startet sie per Push, sobald ein Gerät läuft (auch wenn die App zu ist), schickt
// neue Endzeiten und beendet sie mit „Fertig – ausräumen“. Die App meldet dafür nur ihre Schlüssel.
// Gleiche Definition steht in FamilieLive/GeraetAttributes.swift (Anzeige) – Felder müssen gleich bleiben.

struct GeraetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var titel: String
        var symbol: String
        var start: Double      // Unix-Sekunden
        var ende: Double       // Unix-Sekunden, 0 = unbekannt
        var fertig: Bool
        var info: String
        // nur beim Auto-Laden (alte Aktivitäten haben die Felder nicht → nil)
        var soc: Double? = nil
        var ziel: Double? = nil
        var kw: Double? = nil
        var pv: Double? = nil
        var akku: Double? = nil
        var netz: Double? = nil
    }
    var geraet: String
}

enum LiveActivityBridge {
    @MainActor private static var started = false

    @MainActor static func start() {
        guard !started else { return }
        started = true
        if #available(iOS 17.2, *) {
            Task {
                for await data in ActivityKit.Activity<GeraetAttributes>.pushToStartTokenUpdates {
                    await report(["la_start": hex(data)])
                }
            }
        }
        Task {
            for await activity in ActivityKit.Activity<GeraetAttributes>.activityUpdates { observe(activity) }
        }
        for activity in ActivityKit.Activity<GeraetAttributes>.activities { observe(activity) }
    }

    private static func observe(_ activity: ActivityKit.Activity<GeraetAttributes>) {
        Task {
            for await data in activity.pushTokenUpdates {
                await report(["la_token": activity.attributes.geraet + ":" + hex(data)])
            }
        }
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private static func report(_ extra: [String: Any]) async {
        let client = HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
        var data = extra
        data["id"] = await MainActor.run { DeviceReport.deviceID }
        _ = try? await client.call("rest_command", "familie_geraet_set", ["daten": data])
    }
}


// MARK: - Bewässerung: Live-Aktivität startet die App selbst (nur bei dem, der startet), mit Stopp-Knopf

enum IrrigationLive {
    static let key = "bewaesserung"

    static func start(zone: String, symbol: String, minutes: Int) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endAll()
        let now = Date().timeIntervalSince1970
        let state = GeraetAttributes.ContentState(titel: zone, symbol: symbol, start: now, ende: now + Double(minutes * 60),
                                                  fertig: false, info: "Bewässerung · \(minutes) Min.")
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.ende + 60))
        _ = try? ActivityKit.Activity<GeraetAttributes>.request(attributes: GeraetAttributes(geraet: key),
                                                               content: content, pushType: .token)
    }

    static func endAll() async {
        for a in ActivityKit.Activity<GeraetAttributes>.activities where a.attributes.geraet == key {
            var s = a.content.state
            s.fertig = true
            s.info = "Gestoppt"
            await a.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .immediate)
        }
    }
}
