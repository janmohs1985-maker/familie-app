import SwiftUI

// MARK: - „Aktuell“: wegwischen
//
// Jede Karte hat einen Schlüssel für GENAU diesen Vorgang (z. B. Sauger + Startzeit).
// Weggewischt bleibt sie weg – startet der Vorgang neu, ändert sich der Schlüssel und sie erscheint wieder.
// Gespeichert pro iPhone, also pro Person.

@MainActor @Observable
final class Dismissed {
    static let shared = Dismissed()
    private static let storeKey = "heuteAusgeblendet"
    private(set) var keys: [String]

    private init() {
        keys = UserDefaults.standard.stringArray(forKey: Self.storeKey) ?? []
    }

    func isHidden(_ key: String) -> Bool { keys.contains(key) }

    func hide(_ key: String) {
        guard !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > 300 { keys.removeFirst(keys.count - 300) }
        UserDefaults.standard.set(keys, forKey: Self.storeKey)
    }
}

struct DismissableModifier: ViewModifier {
    let key: String?
    @State private var dismissed = Dismissed.shared
    @State private var offset: CGFloat = 0

    private var fade: Double {
        let moved = Double(abs(offset)) / 260.0
        return 1.0 - Swift.min(0.7, moved)
    }

    func body(content: Content) -> some View {
        if let key, dismissed.isHidden(key) {
            EmptyView()
        } else if let key {
            content
                .offset(x: offset)
                .opacity(fade)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { v in
                            // nur waagerecht – senkrecht bleibt Scrollen
                            if abs(v.translation.width) > abs(v.translation.height) * 1.5 { offset = v.translation.width }
                        }
                        .onEnded { v in
                            if abs(offset) > 110 {
                                withAnimation(.easeOut(duration: 0.2)) { offset = offset > 0 ? 600 : -600 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    withAnimation(.snappy) { dismissed.hide(key) }
                                    offset = 0
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                            }
                        }
                )
                .contextMenu {
                    Button { withAnimation(.snappy) { dismissed.hide(key) } } label: {
                        Label("Ausblenden, bis es wieder passiert", systemImage: "eye.slash")
                    }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: dismissed.keys.count)
                .accessibilityAction(named: "Ausblenden") { dismissed.hide(key) }
        } else {
            content
        }
    }
}

extension View {
    /// Wegwischbar machen – `key` beschreibt genau diesen Vorgang (nil = nicht wegwischbar)
    func dismissable(_ key: String?) -> some View { modifier(DismissableModifier(key: key)) }
}

// MARK: Schlüssel je Karte

@MainActor
extension AppStore {
    private func changed(_ entity: String) -> String { states[entity]?.last_changed ?? "" }

    var dismissKeyMailbox: String { "post." + changed(FamilyConfig.mailbox) }
    var dismissKeyDoorbell: String { "klingel.\(Int(lastRing?.timeIntervalSince1970 ?? 0))" }

    var dismissKeyKitchen: String {
        let parts = MieleConfig.appliances.filter { mieleRunning($0) || mieleFinished($0) }
            .map { $0.key + ":" + changed($0.status) }
        return "kueche." + parts.joined(separator: ",")
    }

    var dismissKeyVacuum: String {
        let parts = FamilyConfig.vacuums.map { $0.id + ":" + changed($0.id) }
        return "sauger." + parts.joined(separator: ",")
    }

    func dismissKeyLaundry(_ d: LaundryConfig.Device) -> String {
        "waesche.\(d.key).\(Int(laundryStart(d)?.timeIntervalSince1970 ?? 0))"
    }

    func dismissKeyUpcoming(_ item: UpcomingItem) -> String {
        "anstehend.\(item.id).\(Int(item.date.timeIntervalSince1970))"
    }
}
