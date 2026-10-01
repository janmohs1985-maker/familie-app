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
