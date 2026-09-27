import SwiftUI

/// Alles, was an deinen Haushalt angepasst ist, steht in dieser Datei.
/// Entitäten ändern/ergänzen, neu bauen, fertig.
enum FamilyConfig {

    /// Standard-Adresse deines Home Assistant (kann in der App geändert werden).
    static let defaultServer = "https://ha.mohs.es"

    // MARK: Familie

    struct Person: Identifiable {
        let id: String          // person.* Entität
        let name: String
        let color: Color
        var schoolEnd: String? = nil   // Sensor mit Attribut "friendly" (z. B. "Freitag bis 12:15")
    }

    static let people: [Person] = [
        Person(id: "person.mohs",    name: "Jan",     color: .orange),
        Person(id: "person.vanessa", name: "Vanessa", color: .green),
        Person(id: "person.emma",    name: "Emma",    color: .blue, schoolEnd: "sensor.emma_schulende_heute_full"),
        Person(id: "person.leoni",   name: "Leoni",   color: .pink, schoolEnd: "sensor.leoni_schulende_heute_full"),
    ]

    // MARK: Müll

    struct Waste: Identifiable {
        let id: String          // Sensor: Zustand = Datum, Attribut tage_bis
        let name: String
        let symbol: String
        let color: Color
    }

    static let waste: [Waste] = [
        Waste(id: "sensor.nachster_hausmull",   name: "Hausmüll",    symbol: "trash.fill",       color: .gray),
        Waste(id: "sensor.nachster_gelber_sack", name: "Gelber Sack", symbol: "arrow.3.trianglepath", color: .yellow),
        Waste(id: "sensor.nachste_blaue_tonne", name: "Blaue Tonne", symbol: "trash",            color: .blue),
    ]

    // MARK: Haushalt-Status (Anzeige auf "Heute")

    static let mailbox = "input_boolean.briefkasten"      // on = Post da
    static let weather = "weather.forecast_home"

    // MARK: Kalender

    /// Leer lassen = alle Kalender aus Home Assistant anzeigen.
    /// Sonst nur diese (z. B. ["calendar.familie", "calendar.emma"]).
    static let calendars: [String] = [
        "calendar.personlicher_kalender",   // Familie (familie@mohs.es)
        "calendar.jan",
        "calendar.vanessa",
        "calendar.emma",
        "calendar.leoni",
        "calendar.deutschland_by",          // Feiertage
    ]

    /// Feste Farben je Kalender (wie im Wochenplaner auf dem Dashboard)
    static let calendarColors: [String: Color] = [
        "calendar.personlicher_kalender": .red,
        "calendar.jan": .orange,
        "calendar.vanessa": .green,
        "calendar.emma": .blue,
        "calendar.leoni": .pink,
        "calendar.deutschland_by": .gray,
    ]

    /// Kalender, die grundsätzlich ausgeblendet werden.
    static let hiddenCalendars: Set<String> = [
        "calendar.llm_vision_timeline",
        "calendar.opensprinkler_schedule",
    ]

    // MARK: Listen

    /// Leer lassen = alle To-do-Listen aus Home Assistant.
    static let todoLists: [String] = []

    // MARK: Steuern
    //
    // Welche Schalter es gibt und wer sie bedienen darf, wird in der App eingestellt
    // (Steuern → Bearbeiten) und in Home Assistant in der Liste „App Schalter“ gespeichert.

    static let appControls = "todo.app_schalter"

    // MARK: Essensplan

    static let mealPlan = "todo.essensplan"             // Gericht, Datum = Fälligkeitsdatum, Beschreibung JSON {"mahlzeit","zutaten"}
    static let mealWishes = "todo.essenswuensche"       // Wünsche, Beschreibung JSON {"von","zeit"}
    static let shoppingList = "todo.einkaufsliste"      // Ziel für „Zutaten auf die Einkaufsliste“
    static let controllableDomains: Set<String> = ["light", "switch", "input_boolean", "cover", "fan", "lock",
                                                   "scene", "script", "button", "input_button"]

    // MARK: Aufgaben & Belohnungen

    struct Kid: Identifiable, Hashable {
        let id: String          // Kurzname, bildet die Entitäten: todo.aufgaben_<id>, counter.punkte_<id>
        let name: String
        let person: String      // person.* – darüber erkennt die App, wer angemeldet ist
        let color: Color
    }

    static let kids: [Kid] = [
        Kid(id: "emma",  name: "Emma",  person: "person.emma",  color: .blue),
        Kid(id: "leoni", name: "Leoni", person: "person.leoni", color: .pink),
    ]
    static func kid(_ id: String) -> Kid? { kids.first { $0.id == id } }

    static func choreList(_ kid: String) -> String { "todo.aufgaben_\(kid)" }
    static func pointsCounter(_ kid: String) -> String { "counter.punkte_\(kid)" }
    static let choreTemplates = "todo.aufgaben_vorlagen"
    static let rewards = "todo.belohnungen"
    static let rewardRequests = "todo.belohnungen_anfragen"
    static let pointsScript = "punkte_buchen"                       // script.punkte_buchen
    static let recurringAutomation = "automation.familie_wiederkehrende_aufgaben_anlegen"

    static let pointsHistory = "todo.punkte_verlauf"
    static let notifyScript = "familie_mitteilung"                  // script.familie_mitteilung (an: eltern/jan/vanessa/emma/leoni)
    static let scannerScript = "familie_scanner"                    // script.familie_scanner (Add-on „Familie Scanner“, nur Eltern)
    static func streakCounter(_ kid: String) -> String { "counter.serie_\(kid)" }
    static func activityFlag(_ kid: String) -> String { "input_boolean.aufgabe_heute_\(kid)" }
    static let streakBonusDays = 7                                   // muss zur Automation „Familie: Serien-Bonus“ passen
    static let streakBonusPoints = 20

    // MARK: Taschengeld

    static let pointsPerEuro = 10
    static let minPayoutEuro = 5

    // MARK: Klingel

    static let doorbellEvent = "event.doorbird_ture_knopf"
    static let doorbellLastRing = "camera.doorbird_ture_letztes_klingeln"
    static let doorbellLive = "camera.doorbird_ture_live"
    static let doorbellHistory = "todo.klingel_verlauf"              // Bilder liegen unter /media/local/<datei>

    /// Diese Listen gehören zu App-Funktionen und erscheinen nicht im Tab „Listen“.
    static let guestWifiSwitch = "switch.mohs_gaste"          // UniFi: WLAN „Mohs - Gäste“ an/aus
    static let freizeitList = "todo.freizeit"                 // Freizeitaktivitäten der Kinder
    static let schoolDocsList = "todo.schulmappe"             // Schulmappe (Fotos über das Scanner-Add-on)

    static var systemTodoLists: Set<String> {
        Set(kids.map { choreList($0.id) } + [choreTemplates, rewards, rewardRequests, pointsHistory, doorbellHistory, appControls, mealPlan, mealWishes, freizeitList, schoolDocsList])
    }

    // MARK: Farben für Kalender (nach Reihenfolge)

    static let calendarPalette: [Color] = [.red, .orange, .green, .blue, .pink, .purple, .teal, .brown]
}
