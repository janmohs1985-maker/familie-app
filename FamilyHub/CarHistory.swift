import SwiftUI
import MapKit
import Charts

// MARK: - Auto-Verlauf aus TeslaLogger
//
// Family Hub liest die TeslaLogger-Datenbank auf der Synology (nur lesend) und liefert Fahrten, Routen,
// Ladevorgänge und Monatswerte. Nur für Eltern (Family Hub prüft das iPhone über den Push-Schlüssel).

enum TeslaHistoryAPI {
    static func send(_ data: [String: Any]) async throws -> JSONValue {
        var d = data
        d["token"] = CallBridge.token
        let r = try await CallBridge.client().callWithResponse("rest_command", "familie_tesla", ["daten": d], timeout: 45)
        let c = r["content"] ?? r
        if c["ok"]?.string != "true" { throw HAError.unexpected(c["error"]?.string ?? "Family Hub nicht erreichbar") }
        return c
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let monthKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func date(_ v: JSONValue?) -> Date? { v?.string.flatMap { stamp.date(from: $0) } }
    static func month(_ v: JSONValue?) -> Date? { v?.string.flatMap { monthKey.date(from: $0) } }

    /// „89278 Nersingen, Schwabenstraße 10a“ → „Schwabenstraße 10a, Nersingen“
    static func place(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "Unbekannt" }
        let parts = s.components(separatedBy: ", ")
        guard parts.count == 2 else { return s }
        var town = parts[0]
        if let sp = town.firstIndex(of: " "), town[..<sp].allSatisfy(\.isNumber) { town = String(town[town.index(after: sp)...]) }
        let street = parts[1].trimmingCharacters(in: .whitespaces)
        return street.isEmpty ? town : "\(street), \(town)"
    }

    static func km(_ v: Double) -> String {
        v >= 100 ? "\(Int(v.rounded()).formatted()) km" : String(format: "%.1f km", v).replacingOccurrences(of: ".", with: ",")
    }
    static func dec(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

// MARK: Daten

struct TeslaTrip: Identifiable, Hashable {
    let start: Date
    let end: Date?
    let from: String
    let to: String
    let km: Double
    let kwh: Double?
    let per100: Double?
    let minutes: Int
    let startPos: Int
    let endPos: Int
    let startSoc: Double?
    let endSoc: Double?
    let fromLat: Double?, fromLng: Double?, toLat: Double?, toLng: Double?
    let temp: Double?
    let vmax: Double?
    var id: Int { startPos }

    init?(_ j: JSONValue) {
        guard let s = TeslaHistoryAPI.date(j["StartDate"]), let km = j["km_diff"]?.double,
              let a = j["StartPosID"]?.double, let b = j["EndPosID"]?.double else { return nil }
        start = s
        end = TeslaHistoryAPI.date(j["EndDate"])
        from = TeslaHistoryAPI.place(j["Start_address"]?.string)
        to = TeslaHistoryAPI.place(j["End_address"]?.string)
        self.km = km
        kwh = j["consumption_kWh"]?.double
        per100 = j["avg_consumption_kWh_100km"]?.double
        minutes = Int(j["DurationMinutes"]?.double ?? 0)
        startPos = Int(a); endPos = Int(b)
        startSoc = j["StartSoc"]?.double; endSoc = j["EndSoc"]?.double
        fromLat = j["lat"]?.double; fromLng = j["lng"]?.double
        toLat = j["EndLat"]?.double; toLng = j["EndLng"]?.double
        temp = j["outside_temp_avg"]?.double
        vmax = j["speed_max"]?.double
    }

    var fromCoord: CLLocationCoordinate2D? { fromLat.flatMap { la in fromLng.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } } }
    var toCoord: CLLocationCoordinate2D? { toLat.flatMap { la in toLng.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } } }
}

struct TeslaCharge: Identifiable, Hashable {
    let start: Date
    let end: Date?
    let kwh: Double
    let cost: Double?
    let fast: Bool
    let maxPower: Double?
    let place: String
    let startSoc: Double?
    let endSoc: Double?
    var id: Date { start }

    init?(_ j: JSONValue) {
        guard let s = TeslaHistoryAPI.date(j["StartDate"]), let kwh = j["charge_energy_added"]?.double else { return nil }
        start = s
        end = TeslaHistoryAPI.date(j["EndDate"])
        self.kwh = kwh
        cost = j["cost_total"]?.double
        fast = (j["fast_charger_present"]?.double ?? 0) >= 1
        maxPower = j["max_charger_power"]?.double
        let raw = (j["address"]?.string ?? "").replacingOccurrences(of: "⚡", with: "").trimmingCharacters(in: .whitespaces)
        place = TeslaHistoryAPI.place(raw)
        startSoc = j["StartSoc"]?.double; endSoc = j["EndSoc"]?.double
    }
}

struct TeslaMonth: Identifiable {
    let month: Date
    var km = 0.0, kwh = 0.0, drives = 0
    var charged = 0.0, fast = 0.0, cost = 0.0
    var id: Date { month }
    var per100: Double? { km >= 20 && kwh > 0 ? kwh / km * 100 : nil }
}

struct TeslaPlace: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct TeslaStats {
    var months: [TeslaMonth] = []
    var range100: [(month: Date, km: Double)] = []
    var places: [TeslaPlace] = []
    var odometer: Double?
    var drives = 0
    var since: Date?
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case week = "7 Tage", month = "30 Tage", year = "12 Monate", all = "Alles"
    var id: String { rawValue }
    var from: Date {
        let cal = Calendar.current
        switch self {
        case .week: return cal.date(byAdding: .day, value: -6, to: Date())!
        case .month: return cal.date(byAdding: .day, value: -29, to: Date())!
        case .year: return cal.date(byAdding: .month, value: -12, to: Date())!
        case .all: return cal.date(from: DateComponents(year: 2018, month: 1, day: 1))!
        }
    }
    var params: [String: Any] {
        ["von": TeslaHistoryAPI.dayKey.string(from: from), "bis": TeslaHistoryAPI.dayKey.string(from: Date())]
    }
}

// MARK: Seite

struct CarHistoryPage: View {
    enum HistorySection: String, CaseIterable, Identifiable {
        case trips = "Fahrten", map = "Karte", charging = "Laden", stats = "Statistik"
        var id: String { rawValue }
    }

    @State private var section: HistorySection = .trips
    @State private var range: HistoryRange = .month

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $section) {
                ForEach(HistorySection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch section {
            case .trips: TripsList(range: range)
            case .map: RoutesMap(range: range)
            case .charging: ChargesList(range: range)
            case .stats: CarStatsView()
            }
        }
        .background(AppBackground())
        .navigationTitle("Verlauf")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if section != .stats {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Zeitraum", selection: $range) {
                            ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(range.rawValue, systemImage: "calendar")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}

/// Lade-/Fehlerzustand für alle Unterseiten
private struct LoadState: View {
    let loading: Bool
    let error: String?
    let empty: Bool
    let emptyText: String
    var retry: () -> Void

    var body: some View {
        if loading {
            ProgressView("Lade aus TeslaLogger …").frame(maxWidth: .infinity, minHeight: 200)
        } else if let error {
            ContentUnavailableView {
                Label("Nicht geladen", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Nochmal", action: retry)
            }
        } else if empty {
            ContentUnavailableView(emptyText, systemImage: "car")
        }
    }
}

// MARK: Fahrten

private struct TripsList: View {
    let range: HistoryRange
    @State private var trips: [TeslaTrip] = []
    @State private var loading = true
    @State private var error: String?

    private var days: [(key: String, date: Date, trips: [TeslaTrip])] {
        let groups = Dictionary(grouping: trips) { TeslaHistoryAPI.dayKey.string(from: $0.start) }
        return groups.map { (key: $0.key, date: $0.value[0].start, trips: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                LoadState(loading: loading && trips.isEmpty, error: error, empty: !loading && trips.isEmpty,
                          emptyText: "Keine Fahrten in diesem Zeitraum") { Task { await load() } }
                if !trips.isEmpty {
                    summary
                    ForEach(days, id: \.key) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(TeslaHistoryAPI.km(day.trips.reduce(0) { $0 + $1.km }))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(day.trips.enumerated()), id: \.element.id) { i, t in
                                    if i > 0 { Divider().padding(.leading, 56) }
                                    NavigationLink { TripDetail(trip: t) } label: { TripRow(trip: t) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .cardSurface()
                        }
                    }
                    if trips.count >= 800 {
                        Text("Es werden die letzten 800 Fahrten gezeigt.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .refreshable { await load() }
        .task(id: range) { await load() }
    }

    private var summary: some View {
        let km = trips.reduce(0) { $0 + $1.km }
        let kwh = trips.compactMap(\.kwh).reduce(0, +)
        let min = trips.reduce(0) { $0 + $1.minutes }
        return HStack {
            StatBlock(value: TeslaHistoryAPI.km(km), label: "\(trips.count) Fahrten", color: .blue)
            StatBlock(value: TeslaHistoryAPI.duration(min), label: "unterwegs", color: .purple)
            StatBlock(value: km >= 10 ? TeslaHistoryAPI.dec(kwh / km * 100) + " kWh" : "–", label: "pro 100 km", color: .green)
        }
        .padding(.vertical, 14)
        .cardSurface()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var p = range.params
            p["aktion"] = "fahrten"
            let c = try await TeslaHistoryAPI.send(p)
            trips = (c["fahrten"]?.array ?? []).compactMap(TeslaTrip.init)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TripRow: View {
    let trip: TeslaTrip
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(trip.start.formatted(.dateTime.hour().minute())).font(.subheadline.weight(.semibold).monospacedDigit())
                Text(TeslaHistoryAPI.duration(trip.minutes)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.to).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("von \(trip.from)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    Label(TeslaHistoryAPI.km(trip.km), systemImage: "road.lanes")
                    if let s = trip.startSoc, let e = trip.endSoc {
                        Label("\(Int(s)) → \(Int(e)) %", systemImage: "battery.50percent")
                    }
                    if let p = trip.per100, trip.km >= 2 {
                        Text("\(TeslaHistoryAPI.dec(p)) kWh/100")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct TripDetail: View {
    let trip: TeslaTrip
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Map(position: $position) {
                    if points.count > 1 {
                        MapPolyline(coordinates: points).stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                    if let c = trip.fromCoord { Marker("Start", systemImage: "flag.fill", coordinate: c).tint(.green) }
                    if let c = trip.toCoord { Marker("Ziel", systemImage: "flag.checkered", coordinate: c).tint(.red) }
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))

                Card(title: trip.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()), symbol: "car.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(trip.from, systemImage: "circle.fill").foregroundStyle(.green).font(.subheadline)
                        Label(trip.to, systemImage: "mappin.circle.fill").foregroundStyle(.red).font(.subheadline)
                        Divider()
                        HStack {
                            StatBlock(value: TeslaHistoryAPI.km(trip.km), label: "Strecke", color: .blue)
                            StatBlock(value: TeslaHistoryAPI.duration(trip.minutes), label: "Dauer", color: .purple)
                            StatBlock(value: trip.kwh.map { TeslaHistoryAPI.dec($0) + " kWh" } ?? "–", label: "Verbrauch", color: .green)
                        }
                        VStack(spacing: 6) {
                            if let s = trip.startSoc, let e = trip.endSoc { InfoRow("Akku", "\(Int(s)) % → \(Int(e)) %") }
                            InfoRow("Pro 100 km", trip.per100.map { TeslaHistoryAPI.dec($0) + " kWh" })
                            if trip.minutes > 0 { InfoRow("Ø Geschwindigkeit", "\(Int(trip.km / Double(trip.minutes) * 60)) km/h") }
                            InfoRow("Höchstgeschwindigkeit", trip.vmax.flatMap { $0 > 0 ? "\(Int($0)) km/h" : nil })
                            InfoRow("Außen", trip.temp.map { String(format: "%.0f °C", $0) })
                            if let e = trip.end { InfoRow("Ankunft", e.formatted(.dateTime.hour().minute())) }
                        }
                    }
                }
            }
            .padding()
        }
        .background(AppBackground())
        .navigationTitle(TeslaHistoryAPI.km(trip.km))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let c = try? await TeslaHistoryAPI.send(["aktion": "route", "start": trip.startPos, "ende": trip.endPos]) else { return }
            points = (c["punkte"]?.array ?? []).compactMap { p in
                guard let a = p.array, a.count == 2, let la = a[0].double, let lo = a[1].double else { return nil }
                return CLLocationCoordinate2D(latitude: la, longitude: lo)
            }
            position = .automatic
        }
    }
}

// MARK: Karte aller Strecken

private struct RoutesMap: View {
    let range: HistoryRange
    @State private var lines: [[CLLocationCoordinate2D]] = []
    @State private var loading = true
    @State private var error: String?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(lines.indices, id: \.self) { i in
                    MapPolyline(coordinates: lines[i]).stroke(.blue.opacity(0.75), lineWidth: 3)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)
            .contentMargins(.bottom, DS.tabBarSpace, for: .scrollContent)

            Group {
                if loading {
                    Label("Strecken werden geladen …", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else {
                    Label("\(lines.count) Strecken · \(range.rawValue)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
        }
        .task(id: range) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var p = range.params
            p["aktion"] = "karte"
            let c = try await TeslaHistoryAPI.send(p)
            lines = (c["strecken"]?.array ?? []).compactMap { s in
                let pts: [CLLocationCoordinate2D] = (s.array ?? []).compactMap { p in
                    guard let a = p.array, a.count == 2, let la = a[0].double, let lo = a[1].double else { return nil }
                    return CLLocationCoordinate2D(latitude: la, longitude: lo)
                }
                return pts.count > 1 ? pts : nil
            }
            error = nil
            position = .automatic
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Laden

private struct ChargesList: View {
    let range: HistoryRange
    @State private var charges: [TeslaCharge] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                LoadState(loading: loading && charges.isEmpty, error: error, empty: !loading && charges.isEmpty,
                          emptyText: "Keine Ladevorgänge in diesem Zeitraum") { Task { await load() } }
                if !charges.isEmpty {
                    summary
                    VStack(spacing: 0) {
                        ForEach(Array(charges.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { Divider().padding(.leading, 52) }
                            ChargeRow(charge: c)
                        }
                    }
                    .cardSurface()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .refreshable { await load() }
        .task(id: range) { await load() }
    }

    private var summary: some View {
        let total = charges.reduce(0) { $0 + $1.kwh }
        let fast = charges.filter(\.fast).reduce(0) { $0 + $1.kwh }
        let cost = charges.compactMap(\.cost).reduce(0, +)
        return VStack(spacing: 10) {
            HStack {
                StatBlock(value: Fmt.kwh(total), label: "\(charges.count)× geladen", color: .green)
                StatBlock(value: Fmt.kwh(total - fast), label: "zu Hause u. a.", color: .blue)
                StatBlock(value: Fmt.kwh(fast), label: "Schnelllader", color: .red)
            }
            if cost > 0 {
                Text("Schnelllader-Kosten laut TeslaLogger: \(Fmt.euro(cost))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .cardSurface()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var p = range.params
            p["aktion"] = "laden"
            let c = try await TeslaHistoryAPI.send(p)
            charges = (c["laden"]?.array ?? []).compactMap(TeslaCharge.init)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ChargeRow: View {
    let charge: TeslaCharge
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: charge.fast ? "bolt.fill" : "ev.charger.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(charge.fast ? .red : .green)
                .frame(width: 30, height: 30)
                .background((charge.fast ? Color.red : Color.green).opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(charge.place).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(charge.start.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    if let e = charge.end {
                        Text(TeslaHistoryAPI.duration(max(1, Int(e.timeIntervalSince(charge.start) / 60))))
                    }
                    if let s = charge.startSoc, let e = charge.endSoc { Text("\(Int(s)) → \(Int(e)) %") }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.kwh(charge.kwh)).font(.subheadline.weight(.semibold).monospacedDigit())
                if let c = charge.cost, c > 0 {
                    Text(Fmt.euro(c)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else if let p = charge.maxPower, p > 0 {
                    Text("max. \(Int(p)) kW").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: Statistik

private struct CarStatsView: View {
    @State private var stats: TeslaStats?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LoadState(loading: loading && stats == nil, error: error, empty: false, emptyText: "") { Task { await load() } }
                if let s = stats {
                    totals(s)
                    let last = Array(s.months.suffix(13))
                    if !last.isEmpty {
                        Card(title: "Kilometer pro Monat", symbol: "road.lanes") {
                            Chart(last) { m in
                                BarMark(x: .value("Monat", m.month, unit: .month), y: .value("km", m.km))
                                    .foregroundStyle(.blue.gradient)
                            }
                            .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                            .frame(height: 170)
                        }
                        Card(title: "Laden pro Monat", symbol: "ev.charger.fill") {
                            Chart {
                                ForEach(last) { m in
                                    BarMark(x: .value("Monat", m.month, unit: .month), y: .value("kWh", m.charged - m.fast))
                                        .foregroundStyle(by: .value("Art", "Zu Hause u. a."))
                                    BarMark(x: .value("Monat", m.month, unit: .month), y: .value("kWh", m.fast))
                                        .foregroundStyle(by: .value("Art", "Schnelllader"))
                                }
                            }
                            .chartForegroundStyleScale(["Zu Hause u. a.": Color.green, "Schnelllader": Color.red])
                            .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                            .frame(height: 170)
                        }
                        let cons = last.filter { $0.per100 != nil }
                        if cons.count > 1 {
                            Card(title: "Verbrauch (kWh pro 100 km)", symbol: "leaf.fill") {
                                Chart(cons) { m in
                                    LineMark(x: .value("Monat", m.month, unit: .month), y: .value("kWh/100 km", m.per100 ?? 0))
                                        .interpolationMethod(.catmullRom)
                                        .foregroundStyle(.green)
                                    PointMark(x: .value("Monat", m.month, unit: .month), y: .value("kWh/100 km", m.per100 ?? 0))
                                        .foregroundStyle(.green)
                                }
                                .chartYScale(domain: .automatic(includesZero: false))
                                .frame(height: 150)
                                Text("Im Winter höher – Heizung und kalter Akku.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if s.range100.count > 2 { battery(s) }
                    if !s.places.isEmpty { places(s) }
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task { if stats == nil { await load() } }
    }

    private func totals(_ s: TeslaStats) -> some View {
        let year = s.months.filter { $0.month >= Calendar.current.date(byAdding: .month, value: -12, to: Date())! }
        let km = year.reduce(0) { $0 + $1.km }
        let charged = year.reduce(0) { $0 + $1.charged }
        return Card(title: "Überblick", symbol: "car.fill") {
            VStack(spacing: 12) {
                HStack {
                    StatBlock(value: s.odometer.map { "\(Int($0).formatted()) km" } ?? "–", label: "Kilometerstand", color: .primary)
                    StatBlock(value: s.drives.formatted(), label: "Fahrten gesamt", color: .blue)
                }
                HStack {
                    StatBlock(value: TeslaHistoryAPI.km(km), label: "letzte 12 Monate", color: .blue)
                    StatBlock(value: Fmt.kwh(charged), label: "geladen (12 Monate)", color: .green)
                }
                if let since = s.since {
                    Text("Aufgezeichnet seit \(since.formatted(.dateTime.month(.wide).year())) – Lücken, wenn TeslaLogger nicht lief.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func battery(_ s: TeslaStats) -> some View {
        let first = s.range100.first!.km, last = s.range100.last!.km
        let loss = first > 0 ? (1 - last / first) * 100 : 0
        return Card(title: "Akku – Reichweite bei 100 %", symbol: "battery.100percent") {
            Chart(s.range100, id: \.month) { p in
                LineMark(x: .value("Monat", p.month, unit: .month), y: .value("km", p.km))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.orange)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 150)
            HStack {
                StatBlock(value: "\(Int(first)) km", label: s.range100.first!.month.formatted(.dateTime.month(.abbreviated).year()), color: .secondary)
                StatBlock(value: "\(Int(last)) km", label: "jetzt", color: .orange)
                StatBlock(value: loss > 0 ? "−\(TeslaHistoryAPI.dec(loss)) %" : "±0 %", label: "Verlust", color: loss > 10 ? .red : .green)
            }
        }
    }

    private func places(_ s: TeslaStats) -> some View {
        Card(title: "Häufigste Ziele (12 Monate)", symbol: "mappin.and.ellipse") {
            VStack(spacing: 8) {
                ForEach(Array(s.places.prefix(10).enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.caption.weight(.bold)).frame(width: 18).foregroundStyle(.secondary)
                        Text(p.name).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text("\(p.count)×").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let c = try await TeslaHistoryAPI.send(["aktion": "statistik"])
            var byMonth: [Date: TeslaMonth] = [:]
            for f in c["fahrten"]?.array ?? [] {
                guard let m = TeslaHistoryAPI.month(f["m"]) else { continue }
                var x = byMonth[m] ?? TeslaMonth(month: m)
                x.km = f["km"]?.double ?? 0
                x.kwh = f["kwh"]?.double ?? 0
                x.drives = Int(f["n"]?.double ?? 0)
                byMonth[m] = x
            }
            for l in c["laden"]?.array ?? [] {
                guard let m = TeslaHistoryAPI.month(l["m"]) else { continue }
                var x = byMonth[m] ?? TeslaMonth(month: m)
                x.charged = l["kwh"]?.double ?? 0
                x.fast = l["schnell"]?.double ?? 0
                x.cost = l["kosten"]?.double ?? 0
                byMonth[m] = x
            }
            var s = TeslaStats()
            s.months = byMonth.values.sorted { $0.month < $1.month }
            s.range100 = (c["akku"]?.array ?? []).compactMap { a in
                guard let m = TeslaHistoryAPI.month(a["m"]), let v = a["voll"]?.double, v > 100 else { return nil }
                return (month: m, km: v)
            }
            s.places = (c["ziele"]?.array ?? []).compactMap { z in
                guard let n = z["n"]?.double else { return nil }
                return TeslaPlace(name: TeslaHistoryAPI.place(z["ort"]?.string), count: Int(n))
            }
            s.odometer = c["gesamt"]?["km"]?.double
            s.drives = Int(c["gesamt"]?["n"]?.double ?? 0)
            s.since = TeslaHistoryAPI.date(c["gesamt"]?["seit"])
            stats = s
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Einstieg auf der Auto-Seite

struct CarHistoryLink: View {
    var body: some View {
        NavigationLink { CarHistoryPage() } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verlauf").font(.headline)
                    Text("Fahrten, Karte aller Strecken, Laden, Statistik").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
    }
}
