import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var showSettings = false
    @State private var mapPerson: FamilyConfig.Person?
    @State private var showFamilyMap = false
    @State private var showWeather = false
    @State private var showArrange = false
    private var orderRaw: String { store.todayOrderRaw }
    private var hiddenCards: Set<String> { store.todayHidden }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    ErrorBanner()
                    AppUpdateBanner()
                    // 1. Aktuell: was gerade läuft, dann was ansteht
                    let upcoming = store.upcomingItems(includeWaste: show(.waste))
                        .filter { !Dismissed.shared.isHidden(store.dismissKeyUpcoming($0)) }
                    if showNowHeader(upcoming) {
                        TodaySectionHeader(title: "Aktuell")
                    }
                    ForEach(nowCards) { k in card(k) }
                    if !upcoming.isEmpty {
                        UpcomingCard(items: upcoming)
                    }

                    // 2. Heute: Termine als Zeitleiste
                    if show(.upcoming) {
                        TodaySectionHeader(title: "Heute", action: store.allows(.kalender) ? "Kalender" : nil) {
                            store.selectedTab = "kalender"
                        }
                        TodayTimeline()
                    }

                    // 3. Alles andere in der gewohnten Reihenfolge
                    let rest = restCards
                    if !rest.isEmpty {
                        TodaySectionHeader(title: "Außerdem")
                    }
                    ForEach(rest) { k in card(k) }
                    if let t = store.lastUpdate {
                        Text("Aktualisiert \(t.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    if store.isAdmin {
                        Button { showArrange = true } label: {
                            Label("Heute anordnen", systemImage: "arrow.up.arrow.down")
                                .font(.footnote)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .background(AppBackground())
            .refreshable {
                await store.refreshAll()
                await ExamsModel.shared.load(store)
                await NotificationHistory.shared.load(store)
            }
            .task { if !ExamsModel.shared.loaded { await ExamsModel.shared.load(store) } }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.isAdmin {
                    Button { showArrange = true } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                NotificationHistoryButton()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showArrange) { TodayArrangeView() }
            .onChange(of: store.route) { _, r in openPersonRoute(r) }
            .onAppear { openPersonRoute(store.route) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWeather) { WeatherSheet().presentationDetents([.large]) }
            .sheet(item: $mapPerson) { p in PersonMapView(person: p) }
            .sheet(isPresented: $showFamilyMap) { FamilyMapView() }
        }
    }

    @ViewBuilder private func card(_ k: TodayCardKind) -> some View {
        switch k {
        case .weather: weatherCard
        case .mailbox: mailboxBanner.dismissable(store.dismissKeyMailbox)
        case .doorbell: if store.ringRecently { DoorbellCard().dismissable(store.dismissKeyDoorbell) }
        case .laundry: LaundryTodayCard()
        case .kitchen: KitchenTodayCard().dismissable(store.dismissKeyKitchen)
        case .safety: SafetyTodayCard()
        case .parentTodos: ParentTodosTodayCard()
        case .music: MusicTodayCard()
        case .vacuum: VacuumTodayCard().dismissable(store.dismissKeyVacuum)
        case .people: peopleCard
        case .school: schoolCard
        case .freizeit: FreizeitTodayCard()
        case .meal: MealTodayCard()
        case .waste: wasteCard
        case .upcoming: upcomingCard
        }
    }

    private func openPersonRoute(_ r: String?) {
        guard let r, r.hasPrefix("person:") else { return }
        store.route = nil
        let id = String(r.dropFirst("person:".count))
        if canSeeMap, let p = FamilyConfig.people.first(where: { $0.id == id }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { mapPerson = p }
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

    /// Karte sichtbar? (nicht ausgeblendet und für diese Person erlaubt)
    private func show(_ k: TodayCardKind) -> Bool {
        !hiddenCards.contains(k.rawValue) && store.todayCardAvailable(k)
    }

    /// „Aktuell“: Meldungen und laufende Geräte – erscheinen nur bei Bedarf
    private static let nowKinds: [TodayCardKind] = [.safety, .doorbell, .mailbox, .laundry, .kitchen, .vacuum, .music]
    private var nowCards: [TodayCardKind] { Self.nowKinds.filter { show($0) } }

    /// Rest in der Reihenfolge von „Heute anordnen“ (Wetter/Familie stehen im Kopf, Müll/Termine oben)
    private var restCards: [TodayCardKind] {
        let skip: Set<TodayCardKind> = Set(Self.nowKinds + [.weather, .people, .waste, .upcoming])
        return TodayCardKind.ordered(orderRaw).filter { !skip.contains($0) && show($0) }
    }

    private func showNowHeader(_ upcoming: [UpcomingItem]) -> Bool {
        if !upcoming.isEmpty { return true }
        if FamilyConfig.vacuums.contains(where: { store.vacIsCleaning($0) }) && !Dismissed.shared.isHidden(store.dismissKeyVacuum) { return true }
        if store.runningAppliances > 0 || store.ringRecently { return true }
        if show(.music), FamilyConfig.speakers.contains(where: { store.speakerState($0.id)?.state == "playing" }) { return true }
        if store.states[FamilyConfig.mailbox]?.state == "on" { return true }
        return !store.smokeAlarm.isEmpty || !store.smokeProblems.isEmpty
    }

    // MARK: Kopfbereich (Glas): Begrüßung, Wetter, Familie

    private var myFirstName: String? {
        if let p = store.myParentID { return FamilyConfig.parent(p)?.name }
        if let k = store.detectedKid { return FamilyConfig.kid(k)?.name }
        return nil
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(myFirstName.map { "\(greeting),\n\($0)" } ?? greeting)
                        .font(.system(size: 32, weight: .heavy))
                        .tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                heroWeather
            }
            if let l = store.lightning {
                Label("Blitz \(Int(l.km.rounded())) km entfernt\(l.direction.map { " im \($0)" } ?? "")",
                      systemImage: "cloud.bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(l.km < 10 ? Color.red : Color.orange)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(FamilyConfig.people) { p in personChip(p) }
            }
            if canSeeMap {
                Button { showFamilyMap = true } label: {
                    Label("Alle auf der Karte", systemImage: "map.fill")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    @ViewBuilder private var heroWeather: some View {
        if let w = store.states[FamilyConfig.weather] {
            let info = WeatherText.info(w.state)
            Button { showWeather = true } label: {
                VStack(alignment: .trailing, spacing: 0) {
                    Image(systemName: info.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 28))
                    if let t = store.outsideTemp {
                        Text("\(t.formatted(.number.precision(.fractionLength(0))))°")
                            .font(.system(size: 30, weight: .light).monospacedDigit())
                    }
                    Text(info.text)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wetter: \(info.text)")
        }
    }

    private func personChip(_ p: FamilyConfig.Person) -> some View {
        let st = store.states[p.id]?.state ?? "unknown"
        let home = st == "home"
        let keyTime: Date? = store.kidID(forPerson: p.id)
            .flatMap { store.doorOpenings(kid: $0).first?.time }
            .flatMap { Calendar.current.isDateInToday($0) ? $0 : nil }
        return Button {
            if canSeeMap { mapPerson = p }
        } label: {
            HStack(spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    Avatar(image: store.pictures[p.id], name: p.name, color: p.color, initialFont: .caption.bold(), ring: 0)
                        .frame(width: 30, height: 30)
                    Circle()
                        .fill(home ? Color.green : Color(.systemGray3))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(keyTime.map { "\(PersonText.status(st)) · \($0.formatted(date: .omitted, time: .shortened))" } ?? PersonText.status(st))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .padding(.trailing, 4)
            .background(Color(.systemBackground).opacity(0.55), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(canSeeMap)
    }

    // MARK: Wetter

    @ViewBuilder private var weatherCard: some View {
        if let w = store.states[FamilyConfig.weather] {
            let info = WeatherText.info(w.state)
            Button { showWeather = true } label: {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
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
                                if let t = store.outsideTemp {
                                    Text("\(t.formatted(.number.precision(.fractionLength(0))))°")
                                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                                }
                                HStack(spacing: 8) {
                                    if let wind = store.num(WeatherConfig.stationWind) ?? w.attr("wind_speed")?.double {
                                        Label("\(Int(wind.rounded())) km/h", systemImage: "wind")
                                    }
                                    if let h = w.attr("humidity")?.int {
                                        Label("\(h) %", systemImage: "humidity")
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let l = store.lightning {
                            Label("Blitz \(Int(l.km.rounded())) km entfernt\(l.direction.map { " im \($0)" } ?? "")",
                                  systemImage: "cloud.bolt.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(l.km < 10 ? Color.red : Color.orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Familie

    /// Karte nur für Eltern (nicht in der Kinder-Vorschau)
    private var canSeeMap: Bool { store.isParent && store.activeKid == nil }

    private var peopleCard: some View {
        Card(title: "Familie", symbol: "person.3.fill") {
            HStack(alignment: .top) {
                ForEach(FamilyConfig.people) { p in
                    let st = store.states[p.id]?.state ?? "unknown"
                    let home = st == "home"
                    Button {
                        if canSeeMap { mapPerson = p }
                    } label: {
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
                        if let kid = store.kidID(forPerson: p.id),
                           let last = store.doorOpenings(kid: kid).first, Calendar.current.isDateInToday(last.time) {
                            Label(last.time.formatted(date: .omitted, time: .shortened), systemImage: "key.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(canSeeMap)
                }
            }
            if canSeeMap {
                Button { showFamilyMap = true } label: {
                    Label("Alle auf der Karte", systemImage: "map.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Schule

    private struct SchoolInfo: Identifiable {
        let person: FamilyConfig.Person
        let text: String
        var id: String { person.id }
    }

    /// Schulende: zuerst aus dem Stundenplan in der App, sonst aus dem HA-Sensor.
    private func schoolText(for p: FamilyConfig.Person) -> String? {
        let kidID = FamilyConfig.kids.first { $0.person == p.id }?.id
        if let kidID, !Timetables.plan(for: kidID).isEmpty {
            let day = ChoreText.todayIndex
            guard day <= 4, let end = Timetables.schoolEnd(kid: kidID, day: day) else { return "Heute frei" }
            return "bis \(end) Uhr"
        }
        guard let sensor = p.schoolEnd, let s = store.states[sensor], !s.isUnavailable else { return nil }
        let text = s.attr("friendly")?.string ?? s.state
        return text.isEmpty ? nil : text
    }

    @ViewBuilder private var schoolCard: some View {
        // Kinder sehen nur sich selbst
        let visible = FamilyConfig.people.filter { p in
            guard let own = store.activeKid else { return true }
            return FamilyConfig.kid(own)?.person == p.id
        }
        let kids = visible.compactMap { p -> SchoolInfo? in
            schoolText(for: p).map { SchoolInfo(person: p, text: $0) }
        }
        if !kids.isEmpty {
            NavigationLink {
                TimetableView(kid: store.activeKid)
            } label: {
                Card(title: "Schule", symbol: "graduationcap.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(kids) { k in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Circle().fill(k.person.color).frame(width: 10, height: 10)
                                    Text(k.person.name).font(.body.weight(.medium))
                                    Spacer()
                                    Text(k.text).foregroundStyle(.secondary)
                                }
                                if let kidID = FamilyConfig.kids.first(where: { $0.person == k.person.id })?.id,
                                   ChoreText.todayIndex <= 4 {
                                    let subjects = Timetables.subjects(kid: kidID, day: ChoreText.todayIndex)
                                    if !subjects.isEmpty {
                                        Text(subjects.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            .padding(.leading, 18)
                                    }
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Text("Stundenplan").font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
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
                    Task { await store.clearMailbox() }
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
        .cardSurface()
    }
}

struct Avatar: View {
    let image: UIImage?
    let name: String
    let color: Color
    var initialFont: Font = .title2.bold()
    var ring: CGFloat = 2
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1))).font(initialFont).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.gradient)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(color, lineWidth: ring))
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
            EventOwnerBadge(event: event, size: 24)
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
