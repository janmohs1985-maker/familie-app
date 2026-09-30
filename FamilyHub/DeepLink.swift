import SwiftUI

// MARK: - Links aus Mitteilungen: familie://einkauf, familie://sauger, …
//
// Home Assistant hängt an jede Familie-Mitteilung einen solchen Link. Beim Antippen öffnet iOS die App
// und wir springen auf die passende Seite.

enum DeepLink {
    /// Ziele, die als Seite unter „Zuhause“ geöffnet werden
    static let zuhausePages: [String: KidFeature?] = [
        "essen": .essensplan, "sauger": .saugroboter, "pool": .pool, "strom": .strom, "heizung": .heizung,
        "bewaesserung": .bewaesserung, "internet": .internet, "rauchmelder": .rauchmelder, "geraete": nil, "beschattung": .beschattung, "waesche": .waesche, "haushalt": .waesche, "vitrinen": nil, "haustuer": .haustuer, "musik": .musik, "schule": .schulmappe,
        "stundenplan": .stundenplan, "scanner": nil, "gaeste": nil,
    ]
}

@MainActor
extension AppStore {
    func openLink(_ url: URL) {
        guard url.scheme == "familie" else { return }
        let target = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch target {
        case "heute", "wetter", "": selectedTab = "heute"
        case "kalender", "termine": if allows(.kalender) { selectedTab = "kalender" }
        case "einkauf", "listen": if allows(.listen) { selectedTab = "listen" }
        case "aufgaben": selectedTab = "aufgaben"
        case "wir": selectedTab = "aufgaben"; aufgabenMode = "wir"
        case let t where t.hasPrefix("aufgabe_"): selectedTab = "aufgaben"; aufgabenMode = "wir"
        case let t where t.hasPrefix("mitbringen_"): if allows(.listen) { selectedTab = "listen" }
        case let t where t.hasPrefix("tuer_"):
            // familie://tuer_emma → Heute, Emmas Seite mit den Türöffnungen
            let kid = String(t.dropFirst(5))
            selectedTab = "heute"
            if let k = FamilyConfig.kid(kid) {
                Task { await refreshDoorOpenings() }
                route = "person:" + k.person
            }
        default:
            guard let feature = DeepLink.zuhausePages[target] else { selectedTab = "heute"; return }
            if let f = feature, !allows(f) { selectedTab = "heute"; return }
            if feature == nil && !(isParent && activeKid == nil) { selectedTab = "heute"; return }
            selectedTab = "zuhause"
            route = target
        }
    }
}

/// Seite zu einem Link-Ziel
struct DeepLinkDestination: View {
    @Environment(AppStore.self) private var store
    let target: String

    var body: some View {
        switch target {
        case "essen": MealPlanView()
        case "sauger": VacuumsView()
        case "pool": PoolView()
        case "strom": EnergyView()
        case "heizung": HeatingView()
        case "bewaesserung": IrrigationView()
        case "internet": NetworkView()
        case "rauchmelder": SmokeView()
        case "geraete": DevicesView()
        case "beschattung": ShadingView()
        case "waesche": LaundryView()
        case "haushalt": AppliancesView()
        case "vitrinen": VitrinesView()
        case "haustuer": DoorbellView()
        case "musik": MusicView()
        case "schule": SchoolDocsView(kid: store.activeKid)
        case "stundenplan": TimetableView(kid: store.activeKid)
        case "scanner": DocumentsView()
        case "gaeste": GuestWifiView()
        default: Text("Seite nicht gefunden").foregroundStyle(.secondary)
        }
    }
}
