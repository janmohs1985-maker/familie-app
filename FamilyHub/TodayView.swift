import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ErrorBanner()
                    weatherCard
                    peopleCard
                    schoolCard
                    mailboxBanner
                    wasteCard
                    upcomingCard
                    if let t = store.lastUpdate {
                        Text("Aktualisiert \(t.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await store.refreshAll() }
            .navigationTitle(greeting)
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "Guten Morgen"
        case 11..<17: return "Hallo"
        case 17..<22: return "Guten Abend"
        default: return "Gute Nacht"
        }
    }

    // MARK: Wetter

    @ViewBuilder private var weatherCard: some View {
        if let w = store.states[FamilyConfig.weather] {
            let info = WeatherText.info(w.state)
            Card {
                HStack(spacing: 16) {
                    Image(systemName: info.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 44))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.text).font(.headline)
                        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let t = w.attr("temperature")?.double {
                            Text("\(t.formatted(.number.precision(.fractionLength(0))))°")
                                .font(.system(size: 38, weight: .semibold, design: .rounded))
                        }
                        if let h = w.attr("humidity")?.int {
                            Label("\(h) %", systemImage: "humidity").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Familie

    private var peopleCard: some View {
        Card(title: "Familie", symbol: "person.3.fill") {
            HStack(alignment: .top) {
                ForEach(FamilyConfig.people) { p in
                    let st = store.states[p.id]?.state ?? "unknown"
                    let home = st == "home"
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(image: store.pictures[p.id], name: p.name, color: p.color)
                                .frame(width: 58, height: 58)
                            Image(systemName: home ? "house.circle.fill" : "location.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.white, home ? Color.green : Color.gray)
                                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                                .offset(x: 3, y: 3)
                        }
                        Text(p.name).font(.subheadline.weight(.semibold))
                        Text(PersonText.status(st))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Schule

    private struct SchoolInfo: Identifiable {
        let person: FamilyConfig.Person
        let text: String
        var id: String { person.id }
    }

    @ViewBuilder private var schoolCard: some View {
        let kids = FamilyConfig.people.compactMap { p -> SchoolInfo? in
            guard let sensor = p.schoolEnd, let s = store.states[sensor], !s.isUnavailable else { return nil }
            let text = s.attr("friendly")?.string ?? s.state
            return text.isEmpty ? nil : SchoolInfo(person: p, text: text)
        }
        if !kids.isEmpty {
            Card(title: "Schule", symbol: "graduationcap.fill") {
                VStack(spacing: 10) {
                    ForEach(kids) { k in
                        HStack {
                            Circle().fill(k.person.color).frame(width: 10, height: 10)
                            Text(k.person.name).font(.body.weight(.medium))
                            Spacer()
                            Text(k.text).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Briefkasten

    @ViewBuilder private var mailboxBanner: some View {
        if store.states[FamilyConfig.mailbox]?.state == "on" {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Post ist da").font(.headline)
                    Text("Im Briefkasten liegt etwas.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Geleert") {
                    Task {
                        if let c = FamilyConfig.controls.first(where: { $0.id == FamilyConfig.mailbox }) {
                            await store.perform(c)
                        }
                    }
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding()
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Müll

    private var wasteCard: some View {
        Card(title: "Müllabfuhr", symbol: "trash.fill") {
            VStack(spacing: 12) {
                ForEach(FamilyConfig.waste) { w in
                    let s = store.states[w.id]
                    let days = s?.attr("tage_bis")?.int
                    let date = HADate.day.date(from: s?.state ?? "")
                    HStack(spacing: 12) {
                        Image(systemName: w.symbol)
                            .font(.title3).foregroundStyle(w.color)
                            .frame(width: 36, height: 36)
                            .background(w.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name).font(.body.weight(.medium))
                            if let date {
                                Text(date.formatted(.dateTime.weekday(.wide).day().month()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let days {
                            Text(WasteText.relative(days))
                                .font(.subheadline.weight(days <= 1 ? .bold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(WasteText.color(days).opacity(days <= 2 ? 0.2 : 0), in: Capsule())
                                .foregroundStyle(days <= 2 ? AnyShapeStyle(WasteText.color(days)) : AnyShapeStyle(.secondary))
                        }
                    }
                }
            }
        }
    }

    // MARK: Nächste Termine

    @ViewBuilder private var upcomingCard: some View {
        let next = Array(store.events.filter { $0.end > Date() }.prefix(4))
        if !next.isEmpty {
            Card(title: "Nächste Termine", symbol: "calendar") {
                VStack(spacing: 10) {
                    ForEach(next) { e in EventRow(event: e, showDay: true) }
                }
            }
        }
    }
}

// MARK: - Bausteine

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct Avatar: View {
    let image: UIImage?
    let name: String
    let color: Color
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1))).font(.title2.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.gradient)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(color, lineWidth: 2))
    }
}

struct EventRow: View {
    @Environment(AppStore.self) private var store
    let event: HAEvent
    var showDay = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(store.color(for: event.calendarID))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary).font(.body.weight(.medium))
                Text(timeText).font(.caption).foregroundStyle(.secondary)
                if let loc = event.location, !loc.isEmpty {
                    Label(loc, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var timeText: String {
        var parts: [String] = []
        if showDay { parts.append(DayText.label(event.start)) }
        if event.allDay { parts.append("Ganztägig") }
        else { parts.append("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))") }
        if let cal = store.calendars.first(where: { $0.entity_id == event.calendarID }) { parts.append(cal.name) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Texte

enum PersonText {
    static func status(_ s: String) -> String {
        switch s {
        case "home": return "Zuhause"
        case "not_home": return "Unterwegs"
        case "unknown", "unavailable": return "Unbekannt"
        default: return s        // Name der Zone, z. B. "Emma Schule"
        }
    }
}

enum WasteText {
    static func relative(_ d: Int) -> String {
        switch d {
        case ..<0: return "–"
        case 0: return "Heute"
        case 1: return "Morgen"
        default: return "in \(d) Tagen"
        }
    }
    static func color(_ d: Int) -> Color { d <= 0 ? .red : d == 1 ? .orange : .yellow }
}

enum DayText {
    static func label(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Heute" }
        if cal.isDateInTomorrow(d) { return "Morgen" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

enum WeatherText {
    static func info(_ c: String) -> (text: String, symbol: String) {
        switch c {
        case "sunny": return ("Sonnig", "sun.max.fill")
        case "clear-night": return ("Klar", "moon.stars.fill")
        case "partlycloudy": return ("Teilweise bewölkt", "cloud.sun.fill")
        case "cloudy": return ("Bewölkt", "cloud.fill")
        case "fog": return ("Nebel", "cloud.fog.fill")
        case "rainy": return ("Regen", "cloud.rain.fill")
        case "pouring": return ("Starkregen", "cloud.heavyrain.fill")
        case "lightning", "lightning-rainy": return ("Gewitter", "cloud.bolt.rain.fill")
        case "snowy": return ("Schnee", "cloud.snow.fill")
        case "snowy-rainy": return ("Schneeregen", "cloud.sleet.fill")
        case "hail": return ("Hagel", "cloud.hail.fill")
        case "windy", "windy-variant": return ("Windig", "wind")
        default: return ("Wetter", "cloud.sun.fill")
        }
    }
}
