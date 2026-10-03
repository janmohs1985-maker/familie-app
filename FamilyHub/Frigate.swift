import SwiftUI
import AVFoundation

// MARK: - Kameras (Frigate über die Frigate-Integration in Home Assistant)
//
// Kameras, Schalter und Werte kommen aus dem Entitäten-Register (Plattform „frigate“),
// Ereignisse über die WebSocket-Befehle der Integration (frigate/events/get),
// Bilder und Clips über deren Proxy (/api/frigate/notifications/<id>/…),
// Live-Bild als HLS (camera/stream), Aufnahmen als VOD (/api/frigate/<instanz>/vod/…).

enum FrigateConfig {
    /// Instanz-ID der Integration (Standard „frigate“)
    static var instance: String { UserDefaults.standard.string(forKey: "frigateInstance") ?? "frigate" }
}

struct FCam: Identifiable, Hashable {
    let entityID: String            // camera.haustuer
    var name: String                // Anzeigename
    var deviceID: String?
    var frigateName: String         // Name in Frigate (für Aufnahmen)
    var switches: [String] = []     // switch.* derselben Kamera
    var numbers: [String] = []      // number.* derselben Kamera
    var sensors: [String] = []      // sensor.* / binary_sensor.* derselben Kamera
    var id: String { entityID }
    var objectID: String { String(entityID.dropFirst("camera.".count)) }
    var hasAutotracker: Bool { switches.contains { $0.hasSuffix("_ptz_autotracker") } }
}

struct FEvent: Identifiable, Hashable {
    let id: String
    let camera: String              // Frigate-Kameraname
    let label: String
    let subLabel: String?
    let score: Double?
    let start: Date
    let end: Date?
    let hasClip: Bool
    let hasSnapshot: Bool
    let zones: [String]

    var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(start)) } }
    var thumbPath: String { "/api/frigate/notifications/\(id)/thumbnail.jpg" }
    var snapshotPath: String { "/api/frigate/notifications/\(id)/snapshot.jpg" }
    var clipPath: String { "/api/frigate/notifications/\(id)/clip.mp4" }

    init?(_ j: JSONValue) {
        guard let id = j["id"]?.string, let cam = j["camera"]?.string,
              let s = j["start_time"]?.double else { return nil }
        self.id = id
        camera = cam
        label = j["label"]?.string ?? "object"
        if let sl = j["sub_label"]?.string, !sl.isEmpty { subLabel = sl }
        else { subLabel = j["sub_label"]?.array?.first?.string }
        score = j["top_score"]?.double ?? j["data"]?["top_score"]?.double ?? j["data"]?["score"]?.double ?? j["score"]?.double
        start = Date(timeIntervalSince1970: s)
        end = j["end_time"]?.double.map { Date(timeIntervalSince1970: $0) }
        hasClip = j["has_clip"]?.string == "true"
        hasSnapshot = j["has_snapshot"]?.string == "true"
        zones = j["zones"]?.array?.compactMap(\.string) ?? []
    }
}

enum FLabel {
    static func name(_ l: String) -> String {
        switch l {
        case "person": "Person"
        case "car": "Auto"
        case "truck": "Lkw"
        case "bus": "Bus"
        case "motorcycle": "Motorrad"
        case "bicycle": "Fahrrad"
        case "dog": "Hund"
        case "cat": "Katze"
        case "bird": "Vogel"
        case "horse": "Pferd"
        case "package": "Paket"
        case "face": "Gesicht"
        case "license_plate": "Kennzeichen"
        default: l.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func color(_ l: String) -> Color {
        switch l {
        case "person", "face": Color(red: 0.21, green: 0.39, blue: 0.91)
        case "car", "truck", "bus", "motorcycle", "bicycle", "license_plate": Color(red: 0.85, green: 0.45, blue: 0.10)
        case "dog", "cat", "bird", "horse": Color(red: 0.11, green: 0.60, blue: 0.40)
        case "package": Color(red: 0.48, green: 0.31, blue: 0.84)
        default: .gray
        }
    }
    static func symbol(_ l: String) -> String {
        switch l {
        case "person", "face": "figure.walk"
        case "car", "truck", "bus", "license_plate": "car.fill"
        case "motorcycle", "bicycle": "bicycle"
        case "dog": "dog.fill"
        case "cat": "cat.fill"
        case "bird": "bird.fill"
        case "package": "shippingbox.fill"
        default: "eye.fill"
        }
    }
    struct Group: Identifiable {
        let key: String
        let title: String
        let labels: Set<String>
        var id: String { key }
    }
    /// Filter-Gruppen für die Ereignis-Liste
    static let groups: [Group] = [
        Group(key: "person", title: "Person", labels: ["person", "face"]),
        Group(key: "auto", title: "Auto", labels: ["car", "truck", "bus", "motorcycle", "bicycle", "license_plate"]),
        Group(key: "tier", title: "Tier", labels: ["dog", "cat", "bird", "horse"]),
        Group(key: "paket", title: "Paket", labels: ["package"]),
    ]
}

/// Bekannte Frigate-Schalter → deutscher Name und Erklärung
enum FSwitch {
    static let known: [(suffix: String, title: String, info: String)] = [
        ("_detect", "Objekterkennung", "Personen, Autos und Tiere erkennen"),
        ("_recordings", "Aufnahme", "Clips und Aufnahmen speichern"),
        ("_snapshots", "Schnappschüsse", "Standbild zu jedem Ereignis"),
        ("_motion", "Bewegungserkennung", "Grundlage für die Erkennung"),
        ("_audio_detection", "Audio-Erkennung", "Bellen, Schreie, Glasbruch"),
        ("_audio", "Audio-Erkennung", "Bellen, Schreie, Glasbruch"),
        ("_ptz_autotracker", "Autotracking", "Kamera folgt Personen von selbst"),
        ("_review_alerts", "Warnungen", "Wichtige Ereignisse markieren"),
        ("_review_detections", "Erkennungen", "Alle Erkennungen sammeln"),
        ("_improve_contrast", "Kontrast verbessern", "Hilft bei Dunkelheit"),
    ]
    static func describe(_ entity: String, fallback: String) -> (title: String, info: String?) {
        if let k = known.first(where: { entity.hasSuffix($0.suffix) }) { return (k.title, k.info) }
        return (fallback, nil)
    }
}

@MainActor
@Observable
final class FrigateModel {
    static let shared = FrigateModel()

    var cameras: [FCam] = []
    var events: [FEvent] = []
    var loadedOnce = false
    var error: String?
    /// Ereignisse neuer als dieser Zeitpunkt gelten als „neu“
    var seenUntil: Date = {
        let t = UserDefaults.standard.double(forKey: "frigateSeen")
        return t > 0 ? Date(timeIntervalSince1970: t) : Date().addingTimeInterval(-86400)
    }()
    @ObservationIgnored private var lastCamLoad: Date?
    @ObservationIgnored private var loadedDays: Set<String> = []

    private init() {}

    // MARK: Laden

    func load(_ store: AppStore, force: Bool = false) async {
        if force || cameras.isEmpty || (lastCamLoad.map { Date().timeIntervalSince($0) > 300 } ?? true) {
            await loadCameras(store)
        }
        await loadEvents(store)
        loadedOnce = true
    }

    private func loadCameras(_ store: AppStore) async {
        var found: [FCam] = []
        if let reg = try? await store.client.websocket(["type": "config/entity_registry/list_for_display"]),
           let list = reg["entities"]?.array {
            let fr = list.filter { $0["pl"]?.string == "frigate" }
            for e in fr {
                guard let id = e["ei"]?.string, id.hasPrefix("camera."), e["hb"]?.string == nil else { continue }
                let dev = e["di"]?.string
                var cam = FCam(entityID: id, name: store.states[id]?.name ?? id, deviceID: dev,
                               frigateName: String(id.dropFirst("camera.".count)))
                if let dev {
                    let same = fr.compactMap { $0["di"]?.string == dev ? $0["ei"]?.string : nil }
                    cam.switches = same.filter { $0.hasPrefix("switch.") }.sorted()
                    cam.numbers = same.filter { $0.hasPrefix("number.") }.sorted()
                    cam.sensors = same.filter { $0.hasPrefix("sensor.") || $0.hasPrefix("binary_sensor.") }.sorted()
                }
                found.append(cam)
            }
        }
        if found.isEmpty {
            // Ersatz: Kamera X ist von Frigate, wenn es switch.X_detect gibt
            for (id, st) in store.states where id.hasPrefix("camera.") {
                let obj = String(id.dropFirst("camera.".count))
                guard store.states["switch.\(obj)_detect"] != nil else { continue }
                var cam = FCam(entityID: id, name: st.name, deviceID: nil, frigateName: obj)
                cam.switches = FSwitch.known.map { "switch.\(obj)\($0.suffix)" }.filter { store.states[$0] != nil }
                found.append(cam)
            }
        }
        // Frigate-Namen aus bekannten Ereignissen übernehmen
        for i in found.indices {
            if let ev = events.first(where: { Self.norm($0.camera) == Self.norm(found[i].objectID) }) {
                found[i].frigateName = ev.camera
            }
        }
        found.sort { a, b in
            if (a.objectID == "birdseye") != (b.objectID == "birdseye") { return b.objectID == "birdseye" }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
        if !found.isEmpty || cameras.isEmpty { cameras = found }
        lastCamLoad = Date()
    }

    func loadEvents(_ store: AppStore, after: Date? = nil, before: Date? = nil, limit: Int = 300) async {
        var cmd: [String: Any] = ["type": "frigate/events/get", "instance_id": FrigateConfig.instance, "limit": limit]
        if let after { cmd["after"] = Int(after.timeIntervalSince1970) }
        if let before { cmd["before"] = Int(before.timeIntervalSince1970) }
        do {
            var res = try await store.client.websocket(cmd)
            if let s = res.string, let d = s.data(using: .utf8), let j = try? JSONDecoder().decode(JSONValue.self, from: d) { res = j }
            let new = (res.array ?? []).compactMap(FEvent.init)
            var byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for e in new { byID[e.id] = e }
            events = byID.values.sorted { $0.start > $1.start }
            error = nil
            for i in cameras.indices {
                if let ev = events.first(where: { Self.norm($0.camera) == Self.norm(cameras[i].objectID) }) {
                    cameras[i].frigateName = ev.camera
                }
            }
        } catch {
            if events.isEmpty { self.error = error.localizedDescription }
        }
    }

    /// Ereignisse eines älteren Tages nachladen (für die Zeitleiste)
    func ensureDay(_ store: AppStore, _ day: Date) async {
        let start = Calendar.current.startOfDay(for: day)
        let key = "\(Int(start.timeIntervalSince1970))"
        guard !loadedDays.contains(key), start < Calendar.current.startOfDay(for: Date()) else { return }
        loadedDays.insert(key)
        await loadEvents(store, after: start, before: start.addingTimeInterval(86400), limit: 500)
    }

    // MARK: Abfragen

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    func events(of cam: FCam) -> [FEvent] {
        let n = Self.norm(cam.frigateName), o = Self.norm(cam.objectID)
        return events.filter { let c = Self.norm($0.camera); return c == n || c == o }
    }

    func camera(for ev: FEvent) -> FCam? {
        let c = Self.norm(ev.camera)
        return cameras.first { Self.norm($0.frigateName) == c || Self.norm($0.objectID) == c }
    }

    func cameraName(_ ev: FEvent) -> String { camera(for: ev)?.name ?? ev.camera.replacingOccurrences(of: "_", with: " ").capitalized }

    var newEvents: [FEvent] { events.filter { $0.start > seenUntil } }
    var todayCount: Int { events.filter { Calendar.current.isDateInToday($0.start) }.count }

    func markAllSeen() {
        seenUntil = Date()
        UserDefaults.standard.set(seenUntil.timeIntervalSince1970, forKey: "frigateSeen")
    }

    func isOnline(_ cam: FCam, _ store: AppStore) -> Bool {
        guard let s = store.states[cam.entityID]?.state else { return false }
        return s != "unavailable" && s != "unknown"
    }

    // MARK: Video

    /// Live-Bild als HLS-Adresse (ohne Token-Header abspielbar)
    func liveURL(_ store: AppStore, _ cam: FCam) async -> URL? {
        guard let res = try? await store.client.websocket(["type": "camera/stream", "entity_id": cam.entityID, "format": "hls"]),
              let path = res["url"]?.string,
              let req = try? await store.client.authorizedRequest(path: path) else { return nil }
        return req.url?.absoluteURL
    }

    /// Abspielbares Objekt mit Anmeldung (für Clips und Aufnahmen).
    /// Frigate schickt MP4s am Stück ohne Länge und ohne Teilabruf (Range) – das spielt AVPlayer
    /// direkt nicht ab. Deshalb erst in eine Datei laden und dann von dort abspielen.
    func asset(_ store: AppStore, path: String) async -> AVURLAsset? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frigate", isDirectory: true)
        let name = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let file = dir.appendingPathComponent(name + ".mp4")
        if FileManager.default.fileExists(atPath: file.path) { return AVURLAsset(url: file) }
        guard let req = try? await store.client.authorizedRequest(path: path),
              let res = try? await URLSession.shared.download(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let tmp = res.0
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanVideoCache(dir)
        do { try FileManager.default.moveItem(at: tmp, to: file) } catch { return nil }
        return AVURLAsset(url: file)
    }

    /// Nur die letzten Videos behalten
    private func cleanVideoCache(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(10) { try? fm.removeItem(at: f) }
    }

    /// Aufnahme eines Zeitraums als MP4 (Frigate setzt die Aufnahmen zusammen).
    /// Das VOD-HLS der Integration braucht für jedes Teilstück eine Signatur, die der Player nicht mitschickt.
    func recordingPath(_ cam: FCam, from: Date, to: Date) -> String {
        "/api/frigate/\(FrigateConfig.instance)/recording/\(cam.frigateName)/start/\(Int(from.timeIntervalSince1970))/end/\(Int(to.timeIntervalSince1970))"
    }

    // MARK: PTZ

    struct PTZInfo { var presets: [String]; var features: [String] }

    func ptzInfo(_ store: AppStore, _ cam: FCam) async -> PTZInfo? {
        guard let res = try? await store.client.websocket(["type": "frigate/ptz/info", "instance_id": FrigateConfig.instance,
                                                            "camera": cam.frigateName]) else { return nil }
        var r = res
        if let s = res.string, let d = s.data(using: .utf8), let j = try? JSONDecoder().decode(JSONValue.self, from: d) { r = j }
        let presets = r["presets"]?.array?.compactMap(\.string) ?? []
        let features = r["features"]?.array?.compactMap(\.string) ?? []
        if presets.isEmpty && features.isEmpty { return nil }
        return PTZInfo(presets: presets, features: features)
    }

    func ptz(_ store: AppStore, _ cam: FCam, action: String, argument: String = "") async {
        do {
            try await store.client.call("frigate", "ptz", ["entity_id": cam.entityID, "action": action, "argument": argument])
        } catch {
            store.report(error)
        }
    }

    // MARK: Datei für Teilen

    func download(_ store: AppStore, path: String, name: String) async -> URL? {
        guard let data = try? await store.client.download(path: path) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? data.write(to: url)
        return url
    }
}

/// Kurze Zeitangabe für Dauer: „18 Sek.“, „1:05 Min.“
enum FFmt {
    static func duration(_ t: TimeInterval?) -> String {
        guard let t else { return "läuft" }
        let s = Int(t.rounded())
        return s < 60 ? "\(s) Sek." : String(format: "%d:%02d Min.", s / 60, s % 60)
    }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        if m < 1 { return "gerade eben" }
        if m < 60 { return "vor \(m) Min." }
        if Calendar.current.isDateInToday(d) { return time(d) }
        return DayText.short(d)
    }
    static func day(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "Heute" }
        if c.isDateInYesterday(d) { return "Gestern" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
