import SwiftUI

// MARK: - Zuhause in fünf Bereichen
//
// Räume · Energie & Technik · Haushalt · Sicherheit · Familie & Dokumente.
// Jeder Bereich zeigt auf der Übersicht ein, zwei Kennzahlen und führt zu seinen Seiten.

enum HomeArea: String, CaseIterable, Identifiable, Hashable {
    case auto, fitness, energie, draussen, haushalt, sicherheit, familie, technik, sonstiges
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .fitness: "Fitness"
        case .energie: "Energie"
        case .draussen: "Garten & Draußen"
        case .haushalt: "Haushalt"
        case .sicherheit: "Sicherheit"
        case .familie: "Familie"
        case .technik: "Technik"
        case .sonstiges: "Sonstiges"
        }
    }
    var symbol: String {
        switch self {
        case .auto: "car.side.fill"
        case .fitness: "figure.strengthtraining.traditional"
        case .energie: "bolt.fill"
        case .draussen: "tree.fill"
        case .haushalt: "washer.fill"
        case .sicherheit: "shield.lefthalf.filled"
        case .familie: "person.2.fill"
        case .technik: "server.rack"
        case .sonstiges: "square.grid.2x2.fill"
        }
    }
    var color: Color {
        switch self {
        case .auto: Color(red: 0.20, green: 0.70, blue: 0.40)
        case .fitness: Color(red: 1.0, green: 0.48, blue: 0.10)
        case .energie: Color(red: 0.91, green: 0.64, blue: 0.09)
        case .draussen: Color(red: 0.25, green: 0.62, blue: 0.85)
        case .haushalt: Color(red: 0.08, green: 0.64, blue: 0.72)
        case .sicherheit: Color(red: 0.90, green: 0.28, blue: 0.30)
        case .familie: Color(red: 0.56, green: 0.36, blue: 0.94)
        case .technik: Color(red: 0.36, green: 0.40, blue: 0.85)
        case .sonstiges: Color(red: 0.43, green: 0.47, blue: 0.54)
        }
    }
}

// MARK: Kennzahlen

@MainActor
extension AppStore {
    /// Keine „echten“ Lampen: Status-LEDs von Netzwerkgeräten, Drucker, Browser-Bildschirme, Anzeigen
    static func isRealLight(_ id: String) -> Bool {
        let skip = ["light.access_point_", "light.us_8_", "light.usw_", "light.udm_", "light.browser_mod_", "light.x1c_", "light.awtrix", "light.tuya_01"]
        if skip.contains(where: { id.hasPrefix($0) }) { return false }
        if id.contains("indicator") || id.hasSuffix("_screen") || id.contains("druckraum") { return false }
        return true
    }

    /// Eingeschaltete Lampen (ohne Gruppen und ohne Status-LEDs), nach Name sortiert
    var lightsOnStates: [HAState] {
        states.values.filter {
            $0.entity_id.hasPrefix("light.") && $0.state == "on" && $0.attr("entity_id") == nil && Self.isRealLight($0.entity_id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var lightsOn: Int { lightsOnStates.count }

    /// Kontakt-Sensoren einer Art – ohne Sammelsensoren („Alle Fenster“) und ohne Tor-Hilfssensoren
    /// wie „Garagentor Geschlossen“ / „Fahren“, die sonst als offen zählen würden
    func contactSensors(_ classes: Set<String>) -> [HAState] {
        states.values.filter { s in
            let id = s.entity_id
            guard id.hasPrefix("binary_sensor."), classes.contains(s.attr("device_class")?.string ?? ""), !s.isUnavailable else { return false }
            if s.attr("entity_id") != nil || id.hasPrefix("binary_sensor.alle_") || id.hasSuffix("_state") { return false }
            if id.contains("geschlossen") || id.contains("fahren") { return false }
            // Gerätetüren (Spülmaschine, Backofen, Dampfgarer, Wärmeschublade, 3D-Drucker …) sind keine Haustüren
            if Self.applianceDoorIDs.contains(id) || ["geschirrspuler", "backofen", "dampfgarer", "warmeschublade", "x1c_", "kuhlschrank", "gefrier", "waschmaschine", "trockner"].contains(where: { id.contains($0) }) { return false }
            return true
        }
    }

    /// Offene Fenster / Türen (nil = keine Sensoren gefunden)
    func openContacts(_ classes: Set<String>) -> Int? {
        let list = contactSensors(classes)
        guard !list.isEmpty else { return nil }
        return list.filter { $0.state == "on" }.count
    }

    func openContactStates(_ classes: Set<String>) -> [HAState] {
        contactSensors(classes).filter { $0.state == "on" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var applianceDoorIDs: Set<String> { Set(MieleConfig.appliances.map(\.door)) }

    /// Laufende Wäsche (Waschmaschine/Trockner)
    var runningAppliances: Int { LaundryConfig.devices.filter { laundryIsRunning($0) }.count }

    /// Alles, was im Haushalt gerade läuft: Wäsche, Miele-Geräte, Saugroboter
    var runningHousehold: [String] {
        var out: [String] = LaundryConfig.devices.filter { laundryIsRunning($0) }.map(\.name)
        out += MieleConfig.appliances.filter { mieleRunning($0) }.map(\.name)
        out += FamilyConfig.vacuums.filter { vacIsCleaning($0) }.map(\.name)
        return out
    }

    func allowsArea(_ a: HomeArea) -> Bool {
        let parent = isParent && activeKid == nil
        switch a {
        case .auto: return parent && hasCar
        case .fitness: return isAdmin           // nur Jan – die Daten liegen auf seinem iPhone
        case .energie: return parent || [KidFeature.strom, .heizung].contains(where: { allows($0) })
        case .draussen: return true
        case .haushalt: return [KidFeature.waesche, .saugroboter, .musik].contains(where: { allows($0) })
                || (allows(.essensplan) && !allows(.listen))
        case .sicherheit: return parent || [KidFeature.haustuer, .rauchmelder].contains(where: { allows($0) })
        case .familie: return parent || allows(.stundenplan) || allows(.schulmappe)
        case .technik: return parent || allows(.internet)
        case .sonstiges: return true
        }
    }
}

// MARK: Status-Chips oben

struct HomeStatusChips: View {
    @Environment(AppStore.self) private var store
    @State private var sheet: HomeListKind?

    var body: some View {
        let windows = store.openContacts(["window"])
        let doors = store.openContacts(["door", "garage_door"])
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !store.smokeAlarm.isEmpty {
                    chip("smoke.fill", "RAUCH!", .red)
                } else if !store.smokeProblems.isEmpty {
                    chip("smoke.fill", "Rauchmelder prüfen", .orange)
                }
                if let doors {
                    chip(doors == 0 ? "door.left.hand.closed" : "door.left.hand.open",
                         doors == 0 ? "Türen zu" : (doors == 1 ? "1 Tür offen" : "\(doors) Türen offen"),
                         doors == 0 ? .green : .orange, open: .doors)
                }
                if let windows {
                    chip(windows == 0 ? "window.vertical.closed" : "window.vertical.open",
                         windows == 0 ? "Fenster zu" : (windows == 1 ? "1 Fenster offen" : "\(windows) Fenster offen"),
                         windows == 0 ? .green : .orange, open: .windows)
                }
                let lights = store.lightsOn
                chip(lights > 0 ? "lightbulb.fill" : "lightbulb", lights == 1 ? "1 Licht an" : "\(lights) Lichter an",
                     lights > 0 ? .yellow : .secondary, open: .lights)
                let running = store.runningHousehold
                if !running.isEmpty {
                    chip("washer.fill", running.count == 1 ? "\(running[0]) läuft" : "\(running.count) Geräte laufen", .teal)
                }
            }
        }
        .scrollClipDisabled()
        .sheet(item: $sheet) { k in HomeStatusSheet(kind: k) }
    }

    private func chip(_ symbol: String, _ text: String, _ color: Color, open: HomeListKind? = nil) -> some View {
        Button {
            if let open { sheet = open }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
                Text(text).font(.footnote.weight(.semibold))
                if open != nil {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color(.systemBackground).opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

enum HomeListKind: String, Identifiable {
    case doors, windows, lights
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doors: "Offene Türen"
        case .windows: "Offene Fenster"
        case .lights: "Lichter an"
        }
    }
}

/// Liste hinter einem Status-Chip: offene Türen/Fenster ansehen, Lichter einzeln oder alle ausschalten
struct HomeStatusSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let kind: HomeListKind
    @State private var busy: Set<String> = []
    @State private var confirmAll = false

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .lights: lightsSection
                case .doors: contactsSection(store.openContactStates(["door", "garage_door"]), empty: "Alle Türen sind zu.", symbol: "door.left.hand.open")
                case .windows: contactsSection(store.openContactStates(["window"]), empty: "Alle Fenster sind zu.", symbol: "window.vertical.open")
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                if kind == .lights && !store.lightsOnStates.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Alle aus", role: .destructive) { confirmAll = true }
                    }
                }
            }
            .confirmationDialog("Alle \(store.lightsOn) Lichter ausschalten?", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Alle ausschalten", role: .destructive) { allOff() }
                Button("Abbrechen", role: .cancel) { }
            }
            .refreshable { await store.refreshStates() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Lichter

    @ViewBuilder private var lightsSection: some View {
        let lights = store.lightsOnStates
        if lights.isEmpty {
            Section { Label("Alle Lichter sind aus.", systemImage: "lightbulb").foregroundStyle(.secondary) }
        } else {
            Section {
                ForEach(lights) { l in lightRow(l) }
            } footer: {
                Text("Antippen schaltet die Lampe aus. Status-LEDs von Netzwerkgeräten zählen nicht mit.")
            }
        }
    }

    private func lightRow(_ l: HAState) -> some View {
        let bri: Int? = l.attr("brightness")?.double.map { Int(($0 / 255 * 100).rounded()) }
        return Button {
            turnOff([l.entity_id])
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(lightColor(l))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name).foregroundStyle(.primary)
                    Text(sinceText(l, prefix: "an")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy.contains(l.entity_id) {
                    ProgressView()
                } else {
                    if let bri { Text("\(bri) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Image(systemName: "power").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityLabel("\(l.name) ausschalten")
        .swipeActions { Button("Aus") { turnOff([l.entity_id]) }.tint(.orange) }
    }

    private func lightColor(_ l: HAState) -> Color {
        if let rgb = l.attr("rgb_color")?.array?.compactMap(\.double), rgb.count == 3 {
            return Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
        }
        return .yellow
    }

    private func allOff() {
        turnOff(store.lightsOnStates.map(\.entity_id))
    }

    private func turnOff(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        busy.formUnion(ids)
        Task {
            do {
                try await store.client.call("light", "turn_off", ["entity_id": ids])
                try? await Task.sleep(for: .milliseconds(800))
                await store.refreshStates()
            } catch { store.report(error) }
            busy.subtract(ids)
        }
    }

    // MARK: Türen / Fenster

    @ViewBuilder private func contactsSection(_ list: [HAState], empty: String, symbol: String) -> some View {
        if list.isEmpty {
            Section { Label(empty, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        } else {
            Section {
                ForEach(list) { s in
                    HStack(spacing: 12) {
                        Image(systemName: symbol).foregroundStyle(.orange).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name)
                            Text(sinceText(s, prefix: "offen")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func sinceText(_ s: HAState, prefix: String) -> String {
        guard let d = HADate.parse(s.last_changed) else { return prefix }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .full
        return "\(prefix) seit " + f.localizedString(for: d, relativeTo: Date()).replacingOccurrences(of: "vor ", with: "")
    }
}

// MARK: Übersicht (Eltern und Kinder – Kinder sehen nur freigegebene Bereiche)

struct HomeAreasOverview: View {
    @Environment(AppStore.self) private var store
    @State private var rooms = RoomsModel.shared
    @AppStorage("roomsFloor") private var floorID = "eg"

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.allows(.raeume) { roomsCard }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(HomeArea.allCases.filter { store.allowsArea($0) }) { a in
                    NavigationLink {
                        if a == .fitness { FitnessView() } else { HomeAreaPage(area: a) }
                    } label: { areaCard(a) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .task { if rooms.floors.isEmpty && store.allows(.raeume) { await rooms.load(store) } }
        .task {
            // Bahnübergang für die Karte „Sonstiges“ aktuell halten, solange die Übersicht sichtbar ist
            while !Task.isCancelled {
                await RailModel.shared.refreshIfStale(maxAge: 60)
                if store.isAdmin { await FitnessModel.shared.refreshIfAllowed() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // Räume: breite Karte mit Stockwerken
    private var roomsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink { RoomsPage() } label: {
                HStack(spacing: 12) {
                    areaIcon("house.fill", Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Räume").font(.headline)
                        Text(roomsSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !rooms.floors.isEmpty {
                HStack(spacing: 6) {
                    ForEach(rooms.floors) { f in
                        let on = f.id == floorID
                        NavigationLink { RoomsPage() } label: {
                            Text(f.name)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { floorID = f.id })
                    }
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    private var roomsSubtitle: String {
        let l = store.lightsOn
        return l == 0 ? "Alle Lichter aus" : (l == 1 ? "1 Licht an" : "\(l) Lichter an")
    }

    private func areaCard(_ a: HomeArea) -> some View {
        let f = facts(a)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                areaIcon(a.symbol, a.color)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Text(f.big)
                .font(.title3.weight(.heavy).monospacedDigit())
                .foregroundStyle(f.alert ? Color.red : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(a.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(f.small).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
    }

    private func areaIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private struct Facts { var big: String; var small: String; var alert = false }

    private func facts(_ a: HomeArea) -> Facts {
        switch a {
        case .auto:
            let soc = store.num(CarConfig.soc)
            let st = store.carStatusText
            return Facts(big: soc.map { "\(Int($0)) %" } ?? "–",
                         small: (st == "lädt" ? "lädt · " : "") + store.chargeMode.title)
        case .energie:
            if store.allows(.strom), let pv = store.num(EnergyConfig.pv) {
                let soc = store.num(EnergyConfig.soc).map { "Akku \(Int($0.rounded())) %" } ?? "Sonne"
                return Facts(big: pv < 20 ? "keine Sonne" : Fmt.watts(pv), small: pv < 20 ? soc : "\(soc) · Sonne")
            }
            return Facts(big: "Energie", small: "Strom · Heizung")
        case .draussen:
            let rain = store.states[WeatherConfig.stationRain]?.state == "on"
            let t = store.outsideTemp.map { String(format: "%.0f°", $0) } ?? "–"
            return Facts(big: t, small: rain ? "es regnet · Pool · Garten" : "Wetter · Pool · Garten")
        case .haushalt:
            let running = store.runningHousehold
            let n = running.count
            return Facts(big: n == 0 ? "alles aus" : (n == 1 ? "1 läuft" : "\(n) laufen"),
                         small: n == 0 ? "Geräte · Sauger · Musik" : running.joined(separator: " · "))
        case .sicherheit:
            if !store.smokeAlarm.isEmpty { return Facts(big: "RAUCH!", small: "Rauchmelder", alert: true) }
            let windows = store.openContacts(["window"]) ?? 0
            let doors = store.openContacts(["door", "garage_door"]) ?? 0
            let big = windows + doors == 0 ? "alles zu" : "\(windows + doors) offen"
            let ring = store.lastRing.map { "Klingel \(DayText.short($0))" } ?? "Haustür · Rauchmelder"
            return Facts(big: big, small: ring, alert: false)
        case .familie:
            return Facts(big: "Familie", small: store.isParent && store.activeKid == nil ? "Karte · Schule · Dokumente" : "Stundenplan · Mappe")
        case .technik:
            let newCam = FrigateModel.shared.newEvents.count
            if store.isParent && store.activeKid == nil && newCam > 0 {
                return Facts(big: "\(newCam) neu", small: "Kameras · Internet · Streaming")
            }
            return Facts(big: "Netz", small: store.isParent && store.activeKid == nil ? "Internet · Kameras · Streaming" : "Internet · VPN · Streaming")
        case .fitness:
            let fit = FitnessModel.shared
            let goal = UserDefaults.standard.object(forKey: "fitGoalKg") as? Double ?? FitnessConfig.defaultGoalKg
            guard let w = fit.currentWeight?.value else {
                let n = fit.workouts(since: FitnessModel.startOfWeek).count
                return Facts(big: fit.loaded == nil ? "Fitness" : "\(n)× Training", small: "Gewicht · Trainings · Plan")
            }
            let rest = w - goal
            return Facts(big: FitFmt.num(w, 1) + " kg",
                         small: rest > 0 ? "noch \(FitFmt.num(rest, 1)) kg bis \(FitFmt.kg(goal))" : "Ziel erreicht!")
        case .sonstiges:
            let rail = RailModel.shared
            guard let next = rail.nextPass else { return Facts(big: "Bahn", small: "DB Status") }
            let min = max(0, Int(next.pass.timeIntervalSinceNow / 60))
            return Facts(big: min == 0 ? "Zug jetzt" : "Zug \(min) Min.",
                         small: rail.closedNow != nil ? "Bahnübergang zu" : "Bahnübergang offen")
        }
    }
}

extension DayText {
    /// „07:48“ heute, sonst „Mo 07:48“
    static func short(_ d: Date) -> String {
        let t = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return t }
        return d.formatted(.dateTime.weekday(.abbreviated)) + " " + t
    }
}

// MARK: Seite eines Bereichs

struct HomeAreaPage: View {
    let area: HomeArea

    var body: some View {
        ScrollView {
            HomeAreaTiles(area: area)
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle(area.title)
    }
}

struct RoomsPage: View {
    var body: some View {
        ScrollView {
            RoomsOverview().padding(.top, 8).padding(.bottom, 24)
        }
        .background(AppBackground())
        .navigationTitle("Räume")
    }
}

/// Die Kacheln eines Bereichs (dieselben Seiten wie bisher, nur neu sortiert)
struct HomeAreaTiles: View {
    @Environment(AppStore.self) private var store
    let area: HomeArea
    @State private var showMap = false
    @State private var showWeather = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var parent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        VStack(spacing: 12) {
            if area == .auto { CarCard().padding(.horizontal) }
            if area == .technik && parent {
                NavigationLink { CamerasView() } label: { CameraPreviewCard() }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                switch area {
                case .auto: auto
                case .energie: energie
                case .draussen: draussen
                case .haushalt: haushalt
                case .sicherheit: sicherheit
                case .familie: familie
                case .technik: technik
                case .sonstiges: sonstiges
                case .fitness: EmptyView()
                }
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showMap) { FamilyMapView() }
        .sheet(isPresented: $showWeather) { WeatherSheet().presentationDetents([.large]) }
    }

    @ViewBuilder private var auto: some View {
        NavigationLink { CarPage() } label: { HubTile(title: "Laden & Status", symbol: "ev.charger.fill", color: .green) }
        NavigationLink { CarHistoryPage() } label: { HubTile(title: "Verlauf", symbol: "clock.arrow.circlepath", color: .blue) }
    }

    @ViewBuilder private var energie: some View {
        if store.allows(.strom) {
            NavigationLink { EnergyView() } label: { HubTile(title: "Haus & Strom", symbol: "bolt.fill", color: .yellow) }
        }
        if store.allows(.heizung) {
            NavigationLink { HeatingView() } label: { HubTile(title: "Heizung", symbol: "heat.waves", color: .red) }
        }
    }

    @ViewBuilder private var draussen: some View {
        Button { showWeather = true } label: { HubTile(title: "Wetter", symbol: "cloud.sun.rain.fill", color: .cyan) }
        if store.allows(.pool) {
            NavigationLink { PoolView() } label: { HubTile(title: "Pool", symbol: "figure.pool.swim", color: .blue) }
        }
        if store.allows(.bewaesserung) {
            NavigationLink { IrrigationView() } label: { HubTile(title: "Bewässerung", symbol: "sprinkler.and.droplets.fill", color: .mint) }
        }
        if store.allows(.beschattung) {
            NavigationLink { ShadingView() } label: { HubTile(title: "Beschattung", symbol: "blinds.horizontal.closed", color: .orange) }
        }
    }

    @ViewBuilder private var haushalt: some View {
        if store.allows(.waesche) {
            NavigationLink { AppliancesView() } label: { HubTile(title: "Haushaltsgeräte", symbol: "washer.fill", color: .teal) }
        }
        if store.allows(.saugroboter) {
            NavigationLink { VacuumsView() } label: { HubTile(title: "Saugroboter", symbol: "fan.fill", color: .mint) }
        }
        if store.allows(.musik) {
            NavigationLink { MusicView() } label: { HubTile(title: "Musik", symbol: "hifispeaker.2.fill", color: .pink) }
        }
        // Essensplan steht im Tab „Listen“ (oben links) – hier nur, wer keine Listen sieht
        if store.allows(.essensplan) && !store.allows(.listen) {
            NavigationLink { MealPlanView() } label: { HubTile(title: "Essensplan", symbol: "fork.knife", color: .orange) }
        }
    }

    @ViewBuilder private var sicherheit: some View {
        if store.allows(.haustuer) {
            NavigationLink { DoorbellView() } label: { HubTile(title: "Haustür", symbol: "bell.fill", color: .yellow) }
        }
        if store.allows(.rauchmelder) {
            NavigationLink { SmokeView() } label: {
                HubTile(title: store.smokeAlarm.isEmpty ? (store.smokeProblems.isEmpty ? "Rauchmelder" : "Rauchmelder ⚠︎") : "RAUCH!",
                        symbol: "smoke.fill", color: store.smokeAlarm.isEmpty ? .gray : .red)
            }
        }
    }

    @ViewBuilder private var familie: some View {
        if parent {
            Button { showMap = true } label: { HubTile(title: "Wo sind alle?", symbol: "map.fill", color: .green) }
        }
        if store.allows(.stundenplan) || store.allows(.schulmappe) {
            NavigationLink { KidsHubView() } label: {
                HubTile(title: store.activeKid == nil ? "Schule & Kinder" : "Schule", symbol: "graduationcap.fill", color: .teal)
            }
        }
        if parent {
            NavigationLink { DocumentsView() } label: {
                HubTile(title: "Dokumente & Paperless", symbol: "doc.text.magnifyingglass", color: .indigo)
            }
        }
        if store.isAdmin && store.activeKid == nil {
            NavigationLink { KidsAdminView() } label: {
                HubTile(title: "Für die Kinder", symbol: "figure.2.and.child.holdinghands", color: .pink)
            }
        }
    }

    @ViewBuilder private var technik: some View {
        if store.allows(.internet) {
            NavigationLink { NetworkView() } label: { HubTile(title: "Netzwerk", symbol: "network", color: .indigo) }
        }
        if parent && store.allows(.internet) {
            NavigationLink { WorldTrafficView() } label: { HubTile(title: "Weltkarte", symbol: "globe.americas.fill", color: .teal) }
            NavigationLink { IPTVView() } label: { HubTile(title: "Streaming", symbol: "play.tv.fill", color: .pink) }
        }
        if parent {
            NavigationLink { CamerasView() } label: { HubTile(title: "Kameras", symbol: "video.fill", color: .indigo) }
            NavigationLink { EventsFeedView() } label: { HubTile(title: "Kamera-Ereignisse", symbol: "film.stack", color: .blue) }
            NavigationLink { DevicesView() } label: { HubTile(title: "Zigbee-Geräte", symbol: "dot.radiowaves.left.and.right", color: .purple) }
        }
    }

    @ViewBuilder private var sonstiges: some View {
        NavigationLink { RailCrossingView() } label: { HubTile(title: "DB Status", symbol: "tram.fill", color: .red) }
    }
}
