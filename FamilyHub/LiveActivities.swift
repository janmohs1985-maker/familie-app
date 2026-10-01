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
                for await data in Activity<GeraetAttributes>.pushToStartTokenUpdates {
                    await report(["la_start": hex(data)])
                }
            }
        }
        Task {
            for await activity in Activity<GeraetAttributes>.activityUpdates { observe(activity) }
        }
        for activity in Activity<GeraetAttributes>.activities { observe(activity) }
    }

    private static func observe(_ activity: Activity<GeraetAttributes>) {
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
