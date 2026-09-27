import SwiftUI

// MARK: - Was die Kinder sehen dürfen
//
// Gespeichert in Home Assistant (input_text.familie_kinder_freigaben), damit es auf allen Handys gilt.
// Format: gesperrte Bereiche pro Kind, z. B. "emma:pool,musik;leoni:pool" – "-" = nichts gesperrt.
// Standard: alles erlaubt.

enum KidFeature: String, CaseIterable, Identifiable {
    case kalender, listen, stundenplan, schulmappe, essensplan, musik, haustuer, strom, heizung, pool, saugroboter
    var id: String { rawValue }

    var title: String {
        switch self {
        case .kalender: "Kalender"
        case .listen: "Listen & Einkauf"
        case .stundenplan: "Stundenplan & Freizeit"
        case .schulmappe: "Schulmappe"
        case .essensplan: "Essensplan"
        case .strom: "Haus & Strom"
        case .heizung: "Heizung (eigenes Zimmer einstellen)"
        case .saugroboter: "Saugroboter"
        case .pool: "Pool"
        case .musik: "Musik / Spotify"
        case .haustuer: "Haustür / Klingel"
        }
    }
    var symbol: String {
        switch self {
        case .kalender: "calendar"
        case .listen: "cart.fill"
        case .stundenplan: "graduationcap.fill"
        case .schulmappe: "folder.fill"
        case .essensplan: "fork.knife"
        case .strom: "bolt.fill"
        case .heizung: "heat.waves"
        case .saugroboter: "fan.fill"
        case .pool: "figure.pool.swim"
        case .musik: "hifispeaker.2.fill"
        case .haustuer: "bell.fill"
        }
    }
}

@MainActor
extension AppStore {
    static let kidPermissionsEntity = "input_text.familie_kinder_freigaben"

    /// Gesperrte Bereiche je Kind
    var kidBlocked: [String: Set<String>] {
        let raw = states[Self.kidPermissionsEntity]?.state ?? ""
        var out: [String: Set<String>] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0])] = Set(kv[1].split(separator: ",").map(String.init))
        }
        return out
    }

    /// Darf die aktuelle Ansicht diesen Bereich sehen? Eltern immer.
    func allows(_ f: KidFeature) -> Bool {
        guard let kid = activeKid else { return true }
        return !(kidBlocked[kid]?.contains(f.rawValue) ?? false)
    }

    func kidAllows(_ kid: String, _ f: KidFeature) -> Bool {
        !(kidBlocked[kid]?.contains(f.rawValue) ?? false)
    }

    func setKidFeature(_ kid: String, _ f: KidFeature, allowed: Bool) async {
        var map = kidBlocked
        var set = map[kid] ?? []
        if allowed { set.remove(f.rawValue) } else { set.insert(f.rawValue) }
        map[kid] = set
        let value = map.keys.sorted()
            .compactMap { k in map[k].flatMap { $0.isEmpty ? nil : "\(k):\($0.sorted().joined(separator: ","))" } }
            .joined(separator: ";")
        do {
            _ = try await client.call("input_text", "set_value",
                                      ["entity_id": Self.kidPermissionsEntity, "value": value.isEmpty ? "-" : value])
            try? await Task.sleep(for: .milliseconds(500))
            await refreshStates()
        } catch { report(error) }
    }
}

struct KidPermissionsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            if store.states[AppStore.kidPermissionsEntity] == nil {
                Section {
                    Label("Speicher in Home Assistant fehlt (input_text.familie_kinder_freigaben).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(FamilyConfig.kids) { kid in
                Section {
                    ForEach(KidFeature.allCases) { f in
                        Toggle(isOn: Binding(
                            get: { store.kidAllows(kid.id, f) },
                            set: { on in Task { await store.setKidFeature(kid.id, f, allowed: on) } }
                        )) {
                            Label(f.title, systemImage: f.symbol)
                        }
                        .tint(kid.color)
                    }
                } header: {
                    Text(kid.name)
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Gilt sofort auf den Handys der Kinder. Ausgeschaltete Bereiche verschwinden bei ihnen komplett – auch die Karten auf „Heute“. Aufgaben und Zuhause bleiben immer sichtbar. Zum Prüfen: Einstellungen → „Aufgaben ansehen als“.")
            }
        }
        .navigationTitle("Für die Kinder")
        .navigationBarTitleDisplayMode(.inline)
    }
}
