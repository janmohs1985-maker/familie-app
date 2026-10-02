import SwiftUI
import MapKit

// MARK: - DB Status: Bahnübergang Elchinger Straße (Nersingen)
//
// Die Züge kommen von Transitous (freie Fahrplan- und Echtzeitdaten, kein Schlüssel nötig).
// Aus dem Fahrweg jedes Zugabschnitts wird berechnet, wann er den Übergang kreuzt.
// Die Schranke ist nicht angebunden – Schließzeiten sind geschätzt.

enum RailConfig {
    static let crossing = CLLocationCoordinate2D(latitude: 48.42915, longitude: 10.11561)
    static let api = "https://api.transitous.org/api/v1/map/trips"
    /// Bereich für Abfrage und Karte (Neu-Ulm-Ost bis Leipheim-West)
    static let minLat = 48.405, minLon = 10.06, maxLat = 48.45, maxLon = 10.17
    /// so nah muss der Fahrweg am Übergang vorbeiführen
    static let passDistance: Double = 60
    /// Abschnitte, die so nah am Übergang liegen, zeigt die Karte
    static let mapDistance: Double = 300
    static let railModes: Set<String> = ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_FAST_RAIL",
                                         "REGIONAL_RAIL", "RAIL", "SUBURBAN"]
    static let longModes: Set<String> = ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"]
    static let stationName = "Nersingen"
}

/// Ein Zug, der den Übergang kreuzt
struct RailPass: Identifiable, Hashable {
    let id: String
    let name: String
    let isLong: Bool
    let westbound: Bool
    let stops: Bool
    let pass: Date
    let delay: Int?          // Minuten, nil = ohne Echtzeit
    let closeFrom: Date
    let closeTo: Date

    var direction: String { westbound ? "→ Ulm" : "→ Augsburg" }
    var info: String { stops ? "hält in Nersingen" : "fährt durch" }
}

/// Ein Zugabschnitt zwischen zwei Halten mit Fahrweg (für die Karte)
struct RailSegment: Identifiable {
    let id: String
    let name: String
    let isLong: Bool
    let dep: Date
    let arr: Date
    let coords: [CLLocationCoordinate2D]
    let cum: [Double]

    /// Position und Fahrtrichtung (Grad, 0 = Norden) zu einem Zeitpunkt – linear über die Strecke verteilt
    func position(at d: Date) -> (coord: CLLocationCoordinate2D, heading: Double)? {
        guard d >= dep, d <= arr, coords.count > 1, let total = cum.last, total > 0 else { return nil }
        let span = arr.timeIntervalSince(dep)
        let target = span > 0 ? total * d.timeIntervalSince(dep) / span : 0
        for k in 0..<(coords.count - 1) where cum[k + 1] >= target {
            let len = cum[k + 1] - cum[k]
            let t = len > 0 ? (target - cum[k]) / len : 0
            let a = coords[k], b = coords[k + 1]
            let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * t)
            let dx = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
            let dy = b.latitude - a.latitude
            return (c, atan2(dx, dy) * 180 / .pi)
        }
        return nil
    }
}

// MARK: Daten

private struct TransitousSegment: Decodable {
    struct Trip: Decodable { let tripId: String; let routeShortName: String? }
    struct Place: Decodable { let name: String; let lat: Double; let lon: Double }
    let trips: [Trip]
    let mode: String
    let from: Place
    let to: Place
    let departure: String
    let arrival: String
    let scheduledDeparture: String?
    let realTime: Bool?
    let polyline: String
}

@MainActor @Observable
final class RailModel {
    static let shared = RailModel()

    var passes: [RailPass] = []
    var segments: [RailSegment] = []
    var loaded: Date?
    var error: String?
    private var loading = false

    /// Der nächste Zug, der noch kommt (oder gerade am Übergang ist)
    var nextPass: RailPass? { passes.first { $0.closeTo > .now } }
    func closed(at d: Date) -> RailPass? { passes.first { $0.closeFrom <= d && $0.closeTo >= d } }
    var closedNow: RailPass? { closed(at: .now) }

    func refreshIfStale(maxAge: TimeInterval) async {
        if let l = loaded, -l.timeIntervalSinceNow < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let iso = ISO8601DateFormatter()
        let now = Date.now
        var comps = URLComponents(string: RailConfig.api)!
        comps.queryItems = [
            URLQueryItem(name: "min", value: "\(RailConfig.minLat),\(RailConfig.minLon)"),
            URLQueryItem(name: "max", value: "\(RailConfig.maxLat),\(RailConfig.maxLon)"),
            URLQueryItem(name: "zoom", value: "15"),
            URLQueryItem(name: "startTime", value: iso.string(from: now.addingTimeInterval(-30 * 60))),
            URLQueryItem(name: "endTime", value: iso.string(from: now.addingTimeInterval(90 * 60))),
        ]
        var req = URLRequest(url: comps.url!, timeoutInterval: 25)
        req.setValue("FamilieApp/1.0 (es.mohs.familie)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let raw = try JSONDecoder().decode([TransitousSegment].self, from: data)
            let parsed = Self.parse(raw, iso: iso)
            passes = parsed.passes
            segments = parsed.segments
            loaded = .now
            error = nil
        } catch {
            self.error = "Zugdaten gerade nicht erreichbar."
        }
    }

    // MARK: Auswertung

    private static func parse(_ raw: [TransitousSegment], iso: ISO8601DateFormatter) -> (passes: [RailPass], segments: [RailSegment]) {
        var passes: [RailPass] = []
        var segments: [RailSegment] = []
        var seenTrips = Set<String>()
        var seenSegments = Set<String>()
        let lat0 = RailConfig.crossing.latitude, lon0 = RailConfig.crossing.longitude
        let kx = cos(lat0 * .pi / 180) * 111_320, ky = 110_540.0

        for s in raw where RailConfig.railModes.contains(s.mode) {
            guard let dep = iso.date(from: s.departure), let arr = iso.date(from: s.arrival) else { continue }
            let coords = decodePolyline(s.polyline)
            guard coords.count > 1 else { continue }
            let pts = coords.map { ((($0.longitude - lon0) * kx), (($0.latitude - lat0) * ky)) }

            // nächster Punkt des Fahrwegs zum Übergang
            var cum: [Double] = [0]
            var best = Double.infinity, bestAlong = 0.0
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                let dx = b.0 - a.0, dy = b.1 - a.1
                let len2 = dx * dx + dy * dy, len = len2.squareRoot()
                let t = len2 > 0 ? min(1, max(0, (-a.0 * dx - a.1 * dy) / len2)) : 0
                let d = hypot(a.0 + t * dx, a.1 + t * dy)
                if d < best { best = d; bestAlong = cum[k] + t * len }
                cum.append(cum[k] + len)
            }
            guard let total = cum.last, total > 0 else { continue }

            let name = trainName(s.trips.first?.routeShortName, mode: s.mode)
            let isLong = RailConfig.longModes.contains(s.mode)

            if best <= RailConfig.mapDistance {
                let key = "\(name)|\(Int(dep.timeIntervalSince1970 / 60))"
                if seenSegments.insert(key).inserted {
                    segments.append(RailSegment(id: key, name: name, isLong: isLong, dep: dep, arr: arr, coords: coords, cum: cum))
                }
            }

            guard best <= RailConfig.passDistance else { continue }
            let tripID = s.trips.first?.tripId ?? UUID().uuidString
            guard seenTrips.insert(tripID).inserted else { continue }

            let pass = dep.addingTimeInterval(arr.timeIntervalSince(dep) * bestAlong / total)
            // gleicher Zug aus einer zweiten Datenquelle?
            if passes.contains(where: { $0.name == name && abs($0.pass.timeIntervalSince(pass)) < 120 }) { continue }

            let westbound = s.to.lon < s.from.lon
            let fromHere = s.from.name.contains(RailConfig.stationName)
            let toHere = s.to.name.contains(RailConfig.stationName)
            let stops = fromHere || toHere
            // Der Bahnhof liegt östlich vom Übergang: Züge Richtung Ulm stehen schon am Bahnsteig,
            // während die Schranke zu ist.
            let before: TimeInterval = fromHere ? 150 : (isLong ? 90 : 120)
            let after: TimeInterval = toHere ? 45 : 30
            var delay: Int?
            if s.realTime == true, let sd = s.scheduledDeparture.flatMap({ iso.date(from: $0) }) {
                delay = Int((dep.timeIntervalSince(sd) / 60).rounded())
            }
            passes.append(RailPass(id: tripID, name: name, isLong: isLong, westbound: westbound, stops: stops,
                                   pass: pass, delay: delay,
                                   closeFrom: pass.addingTimeInterval(-before), closeTo: pass.addingTimeInterval(after)))
        }
        return (passes.sorted { $0.pass < $1.pass }, segments)
    }

    /// „RE9 (57033)“ → „RE 9“, „ICE 1096“ → „ICE“
    static func trainName(_ raw: String?, mode: String) -> String {
        var s = (raw ?? "").replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let long = ["ICE", "IC", "EC", "EN", "NJ", "RJ", "RJX", "TGV", "FLX"]
        if let first = s.split(separator: " ").first, long.contains(String(first)) { return String(first) }
        if let m = s.firstMatch(of: #/^([A-Za-z]+)(\d+)$/#) { s = "\(m.1) \(m.2)" }
        if s.isEmpty { return RailConfig.longModes.contains(mode) ? "Fernzug" : "Zug" }
        return s
    }

    static func decodePolyline(_ s: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lon = 0
        var out: [CLLocationCoordinate2D] = []
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dlat = next(), let dlon = next() else { break }
            lat += dlat
            lon += dlon
            out.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return out
    }
}

// MARK: - Seite „DB Status“

struct RailCrossingView: View {
    @State private var model = RailModel.shared

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 14) {
                    Text("Bahnübergang Elchinger Straße · Nersingen")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    if let e = model.error, model.loaded == nil {
                        Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
                    }
                    heroCard(ctx.date)
                    timelineCard(ctx.date)
                    mapCard(ctx.date)
                    trainList(ctx.date)
                    Text("Geschätzt aus Fahrplan und Verspätungen. Die echte Schranke kann früher schließen. Daten: Transitous.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(AppBackground())
        .navigationTitle("DB Status")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { liveBadge }
        }
        .refreshable { await model.refresh() }
        .task {
            while !Task.isCancelled {
                await model.refreshIfStale(maxAge: 25)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(model.error == nil && model.loaded != nil ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(model.loaded.map { "live · " + Self.ago($0) } ?? "lädt …")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private static func ago(_ d: Date) -> String {
        let s = max(0, Int(-d.timeIntervalSinceNow))
        return s < 60 ? "vor \(s) s" : "vor \(s / 60) Min."
    }

    private static func hm(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    private static func minutes(_ t: TimeInterval) -> Int { max(1, Int((t / 60).rounded(.up))) }

    // MARK: Schranke

    private func heroCard(_ now: Date) -> some View {
        let closed = model.closed(at: now)
        let next = model.passes.first { $0.closeFrom > now }
        let label: String, big: String, small: String
        if let c = closed {
            label = "WAHRSCHEINLICH ZU"
            big = "frei in ~\(Self.minutes(c.closeTo.timeIntervalSince(now))) Min."
            small = "\(c.name) \(c.direction) · \(c.stops ? "hält am Bahnhof" : "fährt durch")"
        } else if let n = next {
            label = "WAHRSCHEINLICH OFFEN"
            big = "noch \(Self.minutes(n.closeFrom.timeIntervalSince(now))) Min."
            let dur = Self.minutes(n.closeTo.timeIntervalSince(n.closeFrom))
            small = "dann zu für ca. \(dur) Min. (\(n.name) \(n.stops ? "hält am Bahnhof" : "fährt durch"))"
        } else {
            label = model.loaded == nil ? "LÄDT" : "WAHRSCHEINLICH OFFEN"
            big = model.loaded == nil ? "…" : "frei"
            small = model.loaded == nil ? "Zugdaten werden geholt" : "in der nächsten Stunde kein Zug bekannt"
        }
        let color: Color = closed != nil ? .red : .green
        return HStack(spacing: 14) {
            BarrierGraphic(closed: closed != nil, blink: Int(now.timeIntervalSince1970) % 2 == 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(color)
                Text(big).font(.title2.weight(.bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(small).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .cardSurface()
    }

    // MARK: Zeitstrahl

    private func timelineCard(_ now: Date) -> some View {
        let span: TimeInterval = 30 * 60
        let end = now.addingTimeInterval(span)
        let blocks = model.passes.filter { $0.closeTo > now && $0.closeFrom < end }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Die nächsten 30 Minuten").font(.headline)
                Spacer()
                Text("jetzt \(Self.hm(now))").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.18))
                    ForEach(blocks) { b in
                        let x0 = max(0, b.closeFrom.timeIntervalSince(now)) / span * w
                        let x1 = min(span, b.closeTo.timeIntervalSince(now)) / span * w
                        Rectangle().fill(Color.red.opacity(0.85))
                            .frame(width: max(3, x1 - x0))
                            .offset(x: x0)
                    }
                    Rectangle().fill(Color.primary).frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(height: 40)
            HStack {
                ForEach(0..<4) { i in
                    Text(Self.hm(now.addingTimeInterval(Double(i) * 600)))
                    if i < 3 { Spacer() }
                }
            }
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 14) {
                legend(Color.green.opacity(0.18), "frei")
                legend(Color.red.opacity(0.85), "wahrscheinlich zu")
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(t)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Live-Karte

    private func mapCard(_ now: Date) -> some View {
        let live = model.segments.compactMap { s -> LiveTrain? in
            guard let p = s.position(at: now) else { return nil }
            return LiveTrain(id: s.id, name: s.name, isLong: s.isLong, coord: p.coord, heading: p.heading)
        }
        let closed = model.closed(at: now) != nil
        return ZStack(alignment: .topLeading) {
            Map(initialPosition: .camera(MapCamera(centerCoordinate: RailConfig.crossing, distance: 3200, heading: 0, pitch: 0)),
                interactionModes: [.pan, .zoom]) {
                Annotation("Bahnübergang", coordinate: RailConfig.crossing, anchor: .center) {
                    ZStack {
                        Circle().fill((closed ? Color.red : Color.green).opacity(0.22)).frame(width: 44, height: 44)
                        Circle().fill(.background).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(closed ? Color.red : Color.green, lineWidth: 3))
                        Image(systemName: "xmark").font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(closed ? Color.red : Color.green)
                    }
                }
                .annotationTitles(.hidden)
                ForEach(live) { t in
                    Annotation(t.name, coordinate: t.coord, anchor: .center) {
                        TrainMarker(name: t.name, isLong: t.isLong, heading: t.heading)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 340)

            HStack(spacing: 6) {
                Text("Live-Karte")
                if live.isEmpty && model.loaded != nil { Text("· gerade kein Zug").foregroundStyle(.secondary) }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }

    // MARK: Zugliste

    private func trainList(_ now: Date) -> some View {
        let list = Array(model.passes.filter { $0.closeTo > now }.prefix(8))
        return VStack(alignment: .leading, spacing: 6) {
            Text("NÄCHSTE ZÜGE AM ÜBERGANG").font(.footnote).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) {
                if list.isEmpty {
                    Text(model.loaded == nil ? "Zugdaten werden geholt …" : "In den nächsten 90 Minuten ist kein Zug bekannt.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                    trainRow(p)
                    if i < list.count - 1 { Divider().padding(.leading, 14) }
                }
            }
            .cardSurface()
        }
    }

    private func trainRow(_ p: RailPass) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(Self.hm(p.pass)).font(.headline).monospacedDigit()
                if let d = p.delay {
                    Text(d <= 0 ? "pünktlich" : "+\(d)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(d <= 0 ? Color.green : Color.orange)
                }
            }
            .frame(width: 58)
            TrainBadge(name: p.name, isLong: p.isLong)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.direction).font(.subheadline.weight(.semibold))
                Text(p.info).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(p.stops ? "zu \(Self.hm(p.closeFrom))–\(Self.hm(p.closeTo))"
                         : "zu ~\(Self.minutes(p.closeTo.timeIntervalSince(p.closeFrom))) Min.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

// MARK: - Bausteine

struct LiveTrain: Identifiable {
    let id: String
    let name: String
    let isLong: Bool
    let coord: CLLocationCoordinate2D
    let heading: Double
}

struct TrainBadge: View {
    let name: String
    let isLong: Bool
    static let regional = Color(red: 0.84, green: 0.15, blue: 0.24)

    var body: some View {
        Text(name)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(minWidth: 36)
            .background(isLong ? Color(.systemGray) : Self.regional, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct TrainMarker: View {
    let name: String
    let isLong: Bool
    let heading: Double

    var body: some View {
        let color = isLong ? Color(.systemGray) : TrainBadge.regional
        ZStack {
            Capsule().fill(color)
                .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
                .frame(width: 38, height: 12)
                .rotationEffect(.degrees(heading - 90))
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.background, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .offset(y: -22)
        }
        .frame(width: 60, height: 60)
    }
}

/// Gezeichnete Halbschranke – Arme hoch (offen) oder waagrecht (zu)
struct BarrierGraphic: View {
    let closed: Bool
    var blink = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 112, height: 6).offset(y: 80)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.75)).frame(width: 8, height: 52).offset(x: 10, y: 30)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.75)).frame(width: 8, height: 52).offset(x: 94, y: 30)
            arm.rotationEffect(.degrees(closed ? 0 : -62), anchor: .leading).offset(x: 14, y: 32)
            arm.rotationEffect(.degrees(closed ? 0 : 62), anchor: .trailing).offset(x: 40, y: 32)
            lamp(on: closed && blink).offset(x: 7, y: 15)
            lamp(on: closed && !blink).offset(x: 91, y: 15)
        }
        .frame(width: 112, height: 96, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.8), value: closed)
        .accessibilityLabel(closed ? "Schranke zu" : "Schranke offen")
    }

    private var arm: some View {
        Capsule().fill(.white)
            .overlay(HStack(spacing: 11) {
                Rectangle().fill(Color.red).frame(width: 9)
                Rectangle().fill(Color.red).frame(width: 9)
            })
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5))
            .frame(width: 58, height: 8)
    }

    private func lamp(on: Bool) -> some View {
        Circle().fill(on ? Color.red : Color.secondary.opacity(0.25)).frame(width: 14, height: 14)
            .shadow(color: on ? .red.opacity(0.6) : .clear, radius: 5)
    }
}
