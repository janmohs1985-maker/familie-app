import ActivityKit
import Foundation

// Gleiche Definition wie in der App (FamilyHub/LiveActivities.swift) – Felder müssen gleich bleiben.
struct GeraetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var titel: String
        var symbol: String
        var start: Double
        var ende: Double
        var fertig: Bool
        var info: String
    }
    var geraet: String
}
