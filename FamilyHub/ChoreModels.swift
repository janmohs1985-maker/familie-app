import Foundation

// MARK: - Datenmodelle für Aufgaben & Belohnungen
//
// Alles liegt in Home Assistant (Integration „Lokale To-do-Liste“):
//  • todo.aufgaben_<kind>      Aufgaben. Offen = needs_action, vom Kind erledigt = completed (wartet auf Bestätigung).
//                              Beschreibung: "Punkte: 10" (+ "Wiederkehrend")
//  • todo.aufgaben_vorlagen    Wiederkehrende Aufgaben. Beschreibung JSON {"kind","punkte","tage"}; abgehakt = pausiert.
//  • todo.belohnungen          Belohnungen zum Einlösen. Beschreibung "Punkte: 50"
//  • todo.belohnungen_anfragen Einlöse-Wünsche der Kinder. Beschreibung JSON {"kind","punkte"}
//  • counter.punkte_<kind>     Punktestand, gebucht über script.punkte_buchen (schreibt auch ins Logbuch)

struct Chore: Identifiable, Hashable {
    let uid: String
    let kid: String
    let title: String
    let points: Int
    let due: Date?
    let recurring: Bool
    let done: Bool
    var id: String { "\(kid)|\(uid)" }
}

struct ChoreTemplate: Identifiable, Hashable {
    let uid: String
    let title: String
    let kid: String
    let points: Int
    let days: [Int]          // 0 = Montag … 6 = Sonntag
    let active: Bool
    var id: String { uid }
}

struct Reward: Identifiable, Hashable {
    let uid: String
    let title: String
    let points: Int
    var id: String { uid }
}

struct RewardRequest: Identifiable, Hashable {
    let uid: String
    let kid: String
    let title: String
    let points: Int
    var id: String { uid }
}

struct PointsEntry: Identifiable, Hashable {
    let uid: String
    let kid: String
    let points: Int
    let reason: String
    let time: Date?
    var id: String { uid }
}

struct DoorbellRing: Identifiable, Hashable {
    let uid: String
    let file: String         // z. B. familie_klingel_3.jpg
    let time: Date?
    let label: String
    var id: String { uid }
    var imagePath: String { "/media/local/\(file)?v=\(Int(time?.timeIntervalSince1970 ?? 0))" }
}

enum ChoreText {
    static let dayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// Liest "Punkte: 10" aus einer Beschreibung.
    static func points(_ description: String?) -> Int {
        guard let d = description, let r = d.range(of: "Punkte:") else { return 0 }
        let rest = d[r.upperBound...].drop { $0 == " " }
        var digits = ""
        for ch in rest {
            if ch.isNumber || (digits.isEmpty && ch == "-") { digits.append(ch) } else { break }
        }
        return Int(digits) ?? 0
    }

    static func json(_ description: String?) -> JSONValue? {
        guard let d = description, d.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(d.utf8))
    }

    static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func weekdays(_ days: [Int]) -> String {
        let s = Set(days)
        if s.count == 7 { return "Täglich" }
        if s == Set(0...4) { return "Mo–Fr" }
        if s == Set([5, 6]) { return "Wochenende" }
        return days.sorted().map { dayNames[$0] }.joined(separator: ", ")
    }

    static func pointsText(_ n: Int) -> String { n == 1 ? "1 Punkt" : "\(n) Punkte" }

    /// Heutiger Wochentag im Format 0 = Montag.
    static var todayIndex: Int { (Calendar.current.component(.weekday, from: Date()) + 5) % 7 }
}
