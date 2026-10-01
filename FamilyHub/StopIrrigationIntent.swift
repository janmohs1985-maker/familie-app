import ActivityKit
import AppIntents

// Stopp-Knopf in der Live-Aktivität der Bewässerung (läuft in der App, auch wenn sie geschlossen ist).
// Gleicher Typ steht auch in FamilieLive/StopIrrigationIntent.swift (nur damit der Knopf ihn kennt).
struct StopIrrigationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Bewässerung stoppen"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let client = HAClient(credentials: Keychain.load()) { creds in
            if let creds { Keychain.save(creds) }
        }
        _ = try? await client.call("opensprinkler", "stop", ["entity_id": IrrigationConfig.controller])
        await IrrigationLive.endAll()
        return .result()
    }
}
