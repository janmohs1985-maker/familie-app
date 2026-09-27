import SwiftUI
import Charts

// MARK: - Wetter: eigene Wetterstation (Dach) + Vorhersage (met.no) + Blitzortung

enum WeatherConfig {
    static let forecast = FamilyConfig.weather                     // weather.forecast_home (met.no)
    static let stationTemp = "sensor.wetterstation_temperatur"
    static let stationWind = "sensor.wetterstation_windgeschwindigkeit"
    static let stationLux = "sensor.wetterstation_helligkeit_in_lux"
    static let windRecord = "sensor.windgeschwindigkeit_max_aller_zeiten"
    static let lightningDistance = "sensor.home_lightning_distance"
    static let lightningAzimuth = "sensor.home_lightning_azimuth"
    static let lightningCounter = "sensor.home_lightning_counter"
    static let sun = "sun.sun"

    /// Himmelsrichtung auf Deutsch
    static func direction(_ deg: Double) -> String {
        let names = ["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"]
        return names[Int(((deg.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8]
    }
    static func shortDirection(_ deg: Double) -> String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return names[Int(((deg.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8]
    }
    /// Windstärke in Worten (Beaufort grob)
    static func windText(_ kmh: Double) -> String {
        switch kmh {
        case ..<2: "windstill"
        case ..<12: "leichter Wind"
        case ..<29: "mäßiger Wind"
        case ..<50: "starker Wind"
        case ..<75: "Sturm"
        default: "schwerer Sturm"
        }
    }
}

struct ForecastEntry: Identifiable {
    let time: Date
    let condition: String
    let temp: Double?
    let low: Double?
    let rain: Double?
    let rainChance: Double?
    let wind: Double?
    var id: Date { time }
}

@MainActor
extension AppStore {
    func forecast(_ type: String) async -> [ForecastEntry] {
        guard let r = try? await client.callWithResponse("weather", "get_forecasts",
                                                          ["entity_id": WeatherConfig.forecast, "type": type]),
              let list = r[WeatherConfig.forecast]?["forecast"]?.array else { return [] }
        return list.compactMap { f in
            guard let t = HADate.parse(f["datetime"]?.string) else { return nil }
            return ForecastEntry(time: t, condition: f["condition"]?.string ?? "",
                                 temp: f["temperature"]?.double, low: f["templow"]?.double,
                                 rain: f["precipitation"]?.double, rainChance: f["precipitation_probability"]?.double,
                                 wind: f["wind_speed"]?.double)
        }
    }

    /// Außentemperatur für die Anzeige: bevorzugt die eigene Wetterstation
    var outsideTemp: Double? {
        num(WeatherConfig.stationTemp) ?? states[WeatherConfig.forecast]?.attr("temperature")?.double
    }

    /// Letzter Blitz in der Nähe (nil = keiner gemeldet)
    var lightning: (km: Double, direction: String?, when: Date?)? {
        guard let km = num(WeatherConfig.lightningDistance) else { return nil }
        let dir = num(WeatherConfig.lightningAzimuth).map(WeatherConfig.direction)
        let when = HADate.parse(states[WeatherConfig.lightningDistance]?.last_changed)
        return (km, dir, when)
    }
}

// MARK: - Fenster

struct WeatherSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var hourly: [ForecastEntry] = []
    @State private var daily: [ForecastEntry] = []
    @State private var tempHist: [PoolPoint] = []
    @State private var windHist: [PoolPoint] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    nowCard
                    lightningCard
                    hourlyCard
                    dailyCard
                    stationChart
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Wetter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .refreshable { await store.refreshStates(); await load() }
            .task { await load() }
        }
    }

    private func load() async {
        async let h = store.forecast("hourly")
        async let d = store.forecast("daily")
        async let s = store.hourlyMeans([WeatherConfig.stationTemp, WeatherConfig.stationWind])
        let (hh, dd, ss) = await (h, d, s)
        hourly = Array(hh.prefix(24))
        daily = Array(dd.prefix(7))
        tempHist = ss[WeatherConfig.stationTemp] ?? []
        windHist = ss[WeatherConfig.stationWind] ?? []
    }

    // MARK: Jetzt

    private var nowCard: some View {
        let w = store.states[WeatherConfig.forecast]
        let info = WeatherText.info(w?.state ?? "")
        let wind = store.num(WeatherConfig.stationWind) ?? w?.attr("wind_speed")?.double
        let bearing = w?.attr("wind_bearing")?.double
        let lux = store.num(WeatherConfig.stationLux)
        let sun = store.states[WeatherConfig.sun]
        return VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: info.symbol).symbolRenderingMode(.multicolor).font(.system(size: 56))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.outsideTemp.map { String(format: "%.1f°", $0) } ?? "–")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                    Text(info.text).font(.headline)
                    if store.num(WeatherConfig.stationTemp) != nil {
                        Label("Wetterstation auf dem Dach", systemImage: "sensor.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    WeatherTile(symbol: "wind", color: .teal, title: "Wind",
                                value: wind.map { "\(Int($0.rounded())) km/h" } ?? "–",
                                note: wind.map { WeatherConfig.windText($0) + (bearing.map { " aus \(WeatherConfig.shortDirection($0))" } ?? "") })
                    WeatherTile(symbol: "humidity.fill", color: .blue, title: "Luftfeuchte",
                                value: w?.attr("humidity")?.int.map { "\($0) %" } ?? "–",
                                note: w?.attr("dew_point")?.double.map { String(format: "Taupunkt %.0f°", $0) })
                }
                GridRow {
                    WeatherTile(symbol: "gauge.with.dots.needle.33percent", color: .purple, title: "Luftdruck",
                                value: w?.attr("pressure")?.double.map { "\(Int($0)) hPa" } ?? "–", note: nil)
                    WeatherTile(symbol: lux.map { $0 > 50 ? "sun.max.fill" : "moon.fill" } ?? "sun.max.fill", color: .orange,
                                title: "Helligkeit",
                                value: lux.map { $0 >= 1000 ? String(format: "%.0f klx", $0 / 1000) : "\(Int($0)) lx" } ?? "–",
                                note: w?.attr("uv_index")?.double.map { "UV-Index \(Int($0))" })
                }
            }
            if let rise = HADate.parse(sun?.attr("next_rising")?.string), let set = HADate.parse(sun?.attr("next_setting")?.string) {
                HStack {
                    Label(rise.formatted(date: .omitted, time: .shortened), systemImage: "sunrise.fill")
                    Spacer()
                    Label(set.formatted(date: .omitted, time: .shortened), systemImage: "sunset.fill")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Blitze

    private var lightningCard: some View {
        let l = store.lightning
        let count = store.num(WeatherConfig.lightningCounter) ?? 0
        let color: Color = {
            guard let km = l?.km else { return .green }
            return km < 10 ? .red : (km < 30 ? .orange : .yellow)
        }()
        return Card(title: "Blitze in der Nähe", symbol: "bolt.fill") {
            HStack(spacing: 14) {
                Image(systemName: l == nil ? "checkmark.shield.fill" : "cloud.bolt.rain.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(color)
                    .symbolRenderingMode(l == nil ? SymbolRenderingMode.monochrome : SymbolRenderingMode.multicolor)
                VStack(alignment: .leading, spacing: 3) {
                    if let l {
                        Text("\(Int(l.km.rounded())) km entfernt").font(.title3.weight(.bold)).foregroundStyle(color)
                        Text([l.direction.map { "Richtung \($0)" },
                              l.when.map { "zuletzt \($0.formatted(.relative(presentation: .named)))" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if l.km < 10 {
                            Text("Gewitter ganz nah – lieber drinnen bleiben und nicht in den Pool!")
                                .font(.caption.weight(.semibold)).foregroundStyle(.red)
                        }
                    } else {
                        Text("Keine Blitze gemeldet").font(.headline)
                        Text("Blitzortung.org meldet gerade nichts in der Umgebung.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if count > 0 {
                    VStack(spacing: 0) {
                        Text("\(Int(count))").font(.title2.weight(.bold).monospacedDigit())
                        Text("Blitze").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Stündlich

    private var hourlyCard: some View {
        Card(title: "Nächste 24 Stunden", symbol: "clock") {
            if hourly.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(hourly) { f in
                            VStack(spacing: 6) {
                                Text(f.time.formatted(.dateTime.hour())).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: WeatherText.info(f.condition).symbol)
                                    .symbolRenderingMode(.multicolor).font(.title3).frame(height: 26)
                                Text(f.temp.map { "\(Int($0.rounded()))°" } ?? "–").font(.subheadline.weight(.semibold))
                                Text((f.rain ?? 0) > 0 ? String(format: "%.1f mm", f.rain!) : " ")
                                    .font(.caption2).foregroundStyle(.blue)
                                Text(f.wind.map { "\(Int($0.rounded()))" } ?? "").font(.caption2).foregroundStyle(.teal)
                            }
                            .frame(minWidth: 40)
                        }
                    }
                }
                Label("Unten: Regen in mm · Wind in km/h", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Tage

    private var dailyCard: some View {
        let lo = daily.compactMap(\.low).min() ?? 0
        let hi = daily.compactMap(\.temp).max() ?? 1
        return Card(title: "Nächste Tage", symbol: "calendar") {
            if daily.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    ForEach(daily) { f in
                        HStack(spacing: 10) {
                            Text(Calendar.current.isDateInToday(f.time) ? "Heute" : f.time.formatted(.dateTime.weekday(.abbreviated)))
                                .frame(width: 46, alignment: .leading)
                            Image(systemName: WeatherText.info(f.condition).symbol)
                                .symbolRenderingMode(.multicolor).frame(width: 28)
                            Text((f.rain ?? 0) >= 0.5 ? String(format: "%.0f mm", f.rain!) : "")
                                .font(.caption).foregroundStyle(.blue).frame(width: 40, alignment: .leading)
                            Text(f.low.map { "\(Int($0.rounded()))°" } ?? "").foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                            TempBar(low: f.low ?? f.temp ?? 0, high: f.temp ?? 0, min: lo, max: hi)
                            Text(f.temp.map { "\(Int($0.rounded()))°" } ?? "–").frame(width: 32, alignment: .trailing)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    // MARK: Wetterstation 24 h

    @ViewBuilder private var stationChart: some View {
        if tempHist.count >= 2 {
            Card(title: "Wetterstation – letzte 24 Stunden", symbol: "chart.xyaxis.line") {
                VStack(alignment: .leading, spacing: 8) {
                    Chart(tempHist) { p in
                        LineMark(x: .value("Zeit", p.time), y: .value("°C", p.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.orange)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .frame(height: 140)
                    HStack {
                        if let lo = tempHist.map(\.value).min(), let hi = tempHist.map(\.value).max() {
                            Text(String(format: "Temperatur %.0f° bis %.0f°", lo, hi))
                        }
                        Spacer()
                        if let w = windHist.map(\.value).max() {
                            Text("Wind bis \(Int(w.rounded())) km/h")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let rec = store.num(WeatherConfig.windRecord) {
                        Text("Stärkster Wind bisher: \(Int(rec.rounded())) km/h")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Bausteine

struct WeatherTile: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TempBar: View {
    let low: Double
    let high: Double
    let min: Double
    let max: Double

    var body: some View {
        GeometryReader { geo in
            let span = Swift.max(max - min, 1)
            let x0 = CGFloat((low - min) / span) * geo.size.width
            let x1 = CGFloat((high - min) / span) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.max(x1 - x0, 6))
                    .offset(x: x0)
            }
        }
        .frame(height: 6)
    }
}
