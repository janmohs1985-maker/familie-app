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
    static let calendars: [String] = []

    /// Kalender, die grundsätzlich ausgeblendet werden.
    static let hiddenCalendars: Set<String> = [
        "calendar.llm_vision_timeline",
        "calendar.opensprinkler_schedule",
    ]

    // MARK: Listen

    /// Leer lassen = alle To-do-Listen aus Home Assistant.
    static let todoLists: [String] = []

    // MARK: Steuern

    enum ControlKind {
        case toggle                         // light/switch/input_boolean/fan … → homeassistant.toggle
        case script(String)                 // startet ein Skript, Zustand kommt aus `entity`
        case lock                           // lock.lock / lock.unlock
    }

    struct Control: Identifiable {
        let id: String                      // Entität, deren Zustand angezeigt wird
        let name: String
        let symbolOn: String
        let symbolOff: String
        let kind: ControlKind
        var onStates: Set<String> = ["on", "open", "Offen", "unlocked"]
        var confirm: Bool = false           // Sicherheitsabfrage vor dem Schalten
    }

    static let controls: [Control] = [
        Control(id: "sensor.garagentor_status", name: "Garagentor",
                symbolOn: "door.garage.open", symbolOff: "door.garage.closed",
                kind: .script("script.toggle_garage_door"), confirm: true),
        Control(id: "lock.garage_2", name: "Garagentür",
                symbolOn: "lock.open.fill", symbolOff: "lock.fill",
                kind: .lock, confirm: true),
        Control(id: "input_boolean.briefkasten", name: "Post im Briefkasten",
                symbolOn: "envelope.badge.fill", symbolOff: "envelope",
                kind: .toggle),
        Control(id: "input_boolean.garagentor_offnen_paketboote", name: "Paketbote",
                symbolOn: "shippingbox.fill", symbolOff: "shippingbox",
                kind: .toggle),
        Control(id: "light.eingang_uberdachung_deckenlicht", name: "Licht Eingang",
                symbolOn: "lightbulb.fill", symbolOff: "lightbulb",
                kind: .toggle),
        Control(id: "switch.gartenhaus_deckenlicht", name: "Licht Gartenhaus",
                symbolOn: "lightbulb.fill", symbolOff: "lightbulb",
                kind: .toggle),
    ]

    // MARK: Farben für Kalender (nach Reihenfolge)

    static let calendarPalette: [Color] = [.red, .orange, .green, .blue, .pink, .purple, .teal, .brown]
}
