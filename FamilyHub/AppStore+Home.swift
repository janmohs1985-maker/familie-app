import Foundation
import CoreLocation

/// Klingel und Standorte.
@MainActor
extension AppStore {

    // MARK: Klingel

    func refreshDoorbell() async {
        guard isLoggedIn else { return }
        do {
            let resp = try await client.callWithResponse("todo", "get_items",
                ["entity_id": FamilyConfig.doorbellHistory, "status": ["needs_action", "completed"]])
            let raw = resp[FamilyConfig.doorbellHistory]?["items"]?.array ?? []
            doorbellRings = raw.compactMap { i in
                guard let uid = i["uid"]?.string, let desc = i["description"]?.string else { return nil }
                let lines = desc.split(separator: "\n").map(String.init)
                guard let file = lines.first, file.hasSuffix(".jpg") else { return nil }
                return DoorbellRing(uid: uid, file: file, time: HADate.parse(lines.dropFirst().first),
                                    label: i["summary"]?.string ?? "")
            }.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
        } catch { report(error) }
    }

    /// Besuch aus dem Verlauf löschen – Eintrag und Bild
    func deleteDoorbellRing(_ r: DoorbellRing) async {
        do {
            try await client.call("todo", "remove_item", ["entity_id": FamilyConfig.doorbellHistory, "item": r.uid])
            _ = try? await paperless(["aktion": "klingelbild_loeschen", "file": r.file])
            doorbellRings.removeAll { $0.id == r.id }
        } catch { report(error) }
        await refreshDoorbell()
    }

    /// Zeitpunkt des letzten Klingelns (Zustand der Event-Entität ist ein Zeitstempel)
    var lastRing: Date? { HADate.parse(states[FamilyConfig.doorbellEvent]?.state) }

    // MARK: Standorte

    func coordinate(of personID: String) -> CLLocationCoordinate2D? {
        guard let s = states[personID], let lat = s.attr("latitude")?.double, let lon = s.attr("longitude")?.double else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var homeCoordinate: CLLocationCoordinate2D? { coordinate(of: "zone.home") }

    /// Wann das iPhone der Person zuletzt einen Standort gemeldet hat
    func locationAge(of personID: String) -> Date? {
        guard let s = states[personID] else { return nil }
        let src = s.attr("source")?.string.flatMap { states[$0] }
        return HADate.parse(src?.last_updated ?? s.last_updated ?? s.last_changed)
    }

    /// Home-Assistant-App auf den iPhones um einen frischen Standort bitten (höchstens alle 60 s)
    static let locationNotify: [String: String] = [
        "person.mohs": "mobile_app_iphone_jan", "person.vanessa": "mobile_app_iphone16pro_vany",
        "person.emma": "mobile_app_iphone_emma", "person.leoni": "mobile_app_iphone_leoni",
    ]
    private static var lastLocationRequest = Date.distantPast

    func requestFreshLocations(_ people: [String]? = nil) {
        guard Date().timeIntervalSince(Self.lastLocationRequest) > 60 || people != nil else { return }
        if people == nil { Self.lastLocationRequest = Date() }
        let targets = (people ?? Array(Self.locationNotify.keys)).compactMap { Self.locationNotify[$0] }
        Task {
            await withTaskGroup(of: Void.self) { g in
                for svc in targets {
                    g.addTask { _ = try? await self.client.call("notify", svc, ["message": "request_location_update"]) }
                }
            }
            for wait in [5, 10, 15] {
                try? await Task.sleep(for: .seconds(wait))
                await refreshStates()
            }
        }
    }

    /// Akku des Geräts, über das die Person geortet wird
    func battery(of personID: String) -> Int? {
        guard let src = states[personID]?.attr("source")?.string else { return nil }
        return states[src]?.attr("battery_level")?.int
    }

    func distanceHome(of personID: String) -> CLLocationDistance? {
        guard let a = coordinate(of: personID), let h = homeCoordinate else { return nil }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: h.latitude, longitude: h.longitude))
    }

    /// Weg der letzten Stunden – nur verfügbar, wenn der Recorder person.* aufzeichnet.
    func track(of personID: String, hours: Int = 12) async -> [CLLocationCoordinate2D] {
        let since = Date().addingTimeInterval(TimeInterval(-hours * 3600))
        guard let data = try? await client.history(entity: personID, since: since) else { return [] }
        return data.compactMap { s in
            guard let lat = s["attributes"]?["latitude"]?.double, let lon = s["attributes"]?["longitude"]?.double else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
