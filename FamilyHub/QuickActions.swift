import SwiftUI
import LocalAuthentication

// MARK: - Favoriten auf „Zuhause“: Garagentor, Garagentür, Haustür, Außenlicht
//
// Tor und Türen: erst nachfragen, dann Face ID / Code des iPhones, dann auslösen.
// Außenlicht: direkt alle Fassaden- und Eingangslichter an bzw. aus.

enum QuickConfig {
    static let gateScript = "script.toggle_garage_door"          // Impuls auf switch.garagentor
    static let gateStatus = "sensor.garagentor_status"            // „Geschlossen“ / „Offen“ …
    static let gateOpen = "binary_sensor.garagentor_offen"
    static let gateClosed = "binary_sensor.garagentor_geschlossen"
    static let gateMoving = "binary_sensor.garagentor_fahren"
    static let garageLock = "lock.garage_2"                       // Nuki Garage (kann öffnen = Falle ziehen)
    static let frontDoor = "button.doorbird_ture_relay_ghqsex_1"  // Haustüre öffnen (Doorbird-Relais)

    /// Außenlicht: alle Fassadenlichter + Eingang Überdachung (unerreichbare werden übersprungen)
    static let outdoorExtra = ["light.eingang_uberdachung_deckenlicht"]
    static func outdoorLights(_ states: [String: HAState]) -> [String] {
        let facade = states.keys.filter { $0.hasPrefix("light.licht_fassade_") }.sorted()
        return (facade + outdoorExtra).filter { id in
            guard let s = states[id] else { return false }
            return s.state != "unavailable"
        }
    }
}

enum QuickAction: String, Identifiable {
    case gate, garageDoor, frontDoor, outdoor
    var id: String { rawValue }
    var secure: Bool { self != .outdoor }
}

@MainActor
enum SecureAuth {
    /// Face ID / Touch ID, sonst Code des iPhones
    static func confirm(_ reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Abbrechen"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

struct QuickActionsRow: View {
    @Environment(AppStore.self) private var store
    @State private var pending: QuickAction?
    @State private var busy: QuickAction?
    @State private var done: QuickAction?
    @State private var failed = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            tile(.gate, title: "Garagentor", symbol: gateOpen ? "door.garage.open" : "door.garage.closed",
                 status: gateText, active: gateOpen)
            tile(.garageDoor, title: "Garagentür", symbol: lockOpen ? "lock.open.fill" : "lock.fill",
                 status: lockText, active: lockOpen)
            tile(.frontDoor, title: "Haustür", symbol: "door.left.hand.closed", status: "öffnen", active: false)
            tile(.outdoor, title: "Außenlicht", symbol: outdoorOn ? "lightbulb.2.fill" : "lightbulb.2",
                 status: outdoorOn ? "an" : "aus", active: outdoorOn)
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let a = pending {
                switch a {
                case .gate:
                    Button(gateOpen ? "Tor schließen" : "Tor öffnen") { run(.gate) }
                case .garageDoor:
                    Button("Tür öffnen") { run(.garageDoor, service: "open") }
                    if lockOpen { Button("Absperren") { run(.garageDoor, service: "lock") } }
                    else { Button("Nur aufsperren") { run(.garageDoor, service: "unlock") } }
                case .frontDoor:
                    Button("Haustür öffnen") { run(.frontDoor) }
                case .outdoor:
                    EmptyView()
                }
                Button("Abbrechen", role: .cancel) { }
            }
        } message: {
            Text("Danach bestätigst du mit \(AppLock.biometryName).")
        }
        .sensoryFeedback(.success, trigger: done)
        .sensoryFeedback(.error, trigger: failed)
    }

    // MARK: Zustände

    private var gateOpen: Bool {
        if store.states[QuickConfig.gateOpen]?.state == "on" { return true }
        if store.states[QuickConfig.gateClosed]?.state == "on" { return false }
        let s = (store.states[QuickConfig.gateStatus]?.state ?? "").lowercased()
        return !s.isEmpty && !s.contains("geschlossen") && s != "unknown" && s != "unavailable"
    }
    private var gateText: String {
        if store.states[QuickConfig.gateMoving]?.state == "on" { return "fährt …" }
        if let s = store.states[QuickConfig.gateStatus]?.state, !["unknown", "unavailable", ""].contains(s) { return s.lowercased() }
        return gateOpen ? "offen" : "zu"
    }
    private var lockOpen: Bool {
        let s = store.states[QuickConfig.garageLock]?.state ?? ""
        return ["unlocked", "open", "opening", "unlocking"].contains(s)
    }
    private var lockText: String {
        switch store.states[QuickConfig.garageLock]?.state ?? "" {
        case "locked": return "abgesperrt"
        case "unlocked": return "aufgesperrt"
        case "open", "opening": return "offen"
        case "locking": return "sperrt …"
        case "unlocking": return "sperrt auf …"
        case "jammed": return "klemmt!"
        default: return "unbekannt"
        }
    }
    private var outdoorOn: Bool {
        QuickConfig.outdoorLights(store.states).contains { store.states[$0]?.state == "on" }
    }
    private var dialogTitle: String {
        switch pending {
        case .gate: return gateOpen ? "Garagentor schließen?" : "Garagentor öffnen?"
        case .garageDoor: return "Garagentür"
        case .frontDoor: return "Haustür öffnen?"
        default: return ""
        }
    }

    // MARK: Kachel

    private func tile(_ a: QuickAction, title: String, symbol: String, status: String, active: Bool) -> some View {
        Button {
            if a == .outdoor { run(.outdoor) } else { pending = a }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle().fill(active ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
                    if busy == a {
                        ProgressView().controlSize(.small).tint(active ? .white : .secondary)
                    } else {
                        Image(systemName: done == a ? "checkmark" : symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    HStack(spacing: 3) {
                        if a.secure { Image(systemName: "faceid").font(.system(size: 8, weight: .bold)) }
                        Text(status).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(active ? AnyShapeStyle(Color.orange.opacity(0.14)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityLabel("\(title), \(status)")
    }

    // MARK: Ausführen

    private func run(_ a: QuickAction, service: String? = nil) {
        pending = nil
        Task {
            if a.secure {
                // kurz warten, bis der Dialog weg ist – sonst erscheint Face ID nicht zuverlässig
                try? await Task.sleep(for: .milliseconds(350))
                guard await SecureAuth.confirm(reason(a, service)) else { return }
            }
            busy = a
            defer { busy = nil }
            do {
                switch a {
                case .gate:
                    try await store.client.call("script", "turn_on", ["entity_id": QuickConfig.gateScript])
                case .garageDoor:
                    try await store.client.call("lock", service ?? "open", ["entity_id": QuickConfig.garageLock])
                case .frontDoor:
                    try await store.client.call("button", "press", ["entity_id": QuickConfig.frontDoor])
                case .outdoor:
                    let ids = QuickConfig.outdoorLights(store.states)
                    guard !ids.isEmpty else { return }
                    try await store.client.call("light", outdoorOn ? "turn_off" : "turn_on", ["entity_id": ids])
                }
                done = a
                try? await Task.sleep(for: .seconds(1))
                await store.refreshStates()
                try? await Task.sleep(for: .seconds(1))
                if done == a { done = nil }
            } catch {
                failed.toggle()
                store.report(error)
            }
        }
    }

    private func reason(_ a: QuickAction, _ service: String?) -> String {
        switch a {
        case .gate: return gateOpen ? "Garagentor schließen" : "Garagentor öffnen"
        case .garageDoor:
            switch service {
            case "lock": return "Garagentür absperren"
            case "unlock": return "Garagentür aufsperren"
            default: return "Garagentür öffnen"
            }
        case .frontDoor: return "Haustür öffnen"
        case .outdoor: return "Außenlicht schalten"
        }
    }
}
