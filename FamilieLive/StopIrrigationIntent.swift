import AppIntents

// Gegenstück zur App (FamilyHub/StopIrrigationIntent.swift) – ausgeführt wird die Version in der App.
struct StopIrrigationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Bewässerung stoppen"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult { .result() }
}
