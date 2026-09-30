import SwiftUI

// MARK: - Zuhause in fünf Bereichen
//
// Räume · Energie & Technik · Haushalt · Sicherheit · Familie & Dokumente.
// Jeder Bereich zeigt auf der Übersicht ein, zwei Kennzahlen und führt zu seinen Seiten.

enum HomeArea: String, CaseIterable, Identifiable, Hashable {
    case energie, haushalt, sicherheit, familie
    var id: String { rawValue }

    var title: String {
        switch self {
        case .energie: "Energie & Technik"
        case .haushalt: "Haushalt"
        case .sicherheit: "Sicherheit"
        case .familie: "Familie & Dokumente"
        }
    }
    var symbol: String {
        switch self {
        case .energie: "bolt.fill"
        case .haushalt: "washer.fill"
        case .sicherheit: "shield.lefthalf.filled"
        case .familie: "person.2.fill"
        }
    }
    var color: Color {
        switch self {
        case .energie: Color(red: 0.91, green: 0.64, blue: 0.09)
        case .haushalt: Color(red: 0.08, green: 0.64, blue: 0.72)
        case .sicherheit: Color(red: 0.90, green: 0.28, blue: 0.30)
        case .familie: Color(red: 0.56, green: 0.36, blue: 0.94)
        }
    }
}

// MARK: Kennzahlen

@MainActor
extension AppStore {
    var lightsOn: Int {
        states.values.filter { $0.entity_id.hasPrefix("light.") && $0.state == "on" && $0.attr("entity_id") == nil }.count
    }

    /// Offene Fenster / Türen laut Kontakt-Sensoren (nil = keine Sensoren gefunden)
    func openContacts(_ classes: Set<String>) -> Int? {
        let list = states.values.filter {
            $0.entity_id.hasPrefix("binary_sensor.") && classes.contains($0.attr("device_class")?.string ?? "") && !$0.isUnavailable
        }
        guard !list.isEmpty else { return nil }
        return list.filter { $0.state == "on" }.count
    }

    var runningAppliances: Int { LaundryConfig.devices.filter { laundryIsRunning($0) }.count }

    func allowsArea(_ a: HomeArea) -> Bool {
        let parent = isParent && activeKid == nil
        switch a {
        case .energie: return parent || [KidFeature.strom, .heizung, .beschattung, .internet, .pool, .bewaesserung].contains(where: { allows($0) })
        case .haushalt: return [KidFeature.waesche, .saugroboter, .essensplan, .musik].contains(where: { allows($0) })
        case .sicherheit: return parent || [KidFeature.haustuer, .rauchmelder].contains(where: { allows($0) })
        case .familie: return parent || allows(.stundenplan) || allows(.schulmappe)
        }
    }
}

// MARK: Status-Chips oben

struct HomeStatusChips: View {
    @Environment(AppStore.self) private var store

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
                         doors == 0 ? .green : .orange)
                }
                if let windows {
                    chip(windows == 0 ? "window.vertical.closed" : "window.vertical.open",
                         windows == 0 ? "Fenster zu" : (windows == 1 ? "1 Fenster offen" : "\(windows) Fenster offen"),
                         windows == 0 ? .green : .orange)
                }
                let lights = store.lightsOn
                chip(lights > 0 ? "lightbulb.fill" : "lightbulb", lights == 1 ? "1 Licht an" : "\(lights) Lichter an",
                     lights > 0 ? .yellow : .secondary)
                if store.runningAppliances > 0 {
                    chip("washer.fill", "Wäsche läuft", .teal)
                }
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(text).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Color(.systemBackground).opacity(0.6), in: Capsule())
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
                    NavigationLink { HomeAreaPage(area: a) } label: { areaCard(a) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .task { if rooms.floors.isEmpty && store.allows(.raeume) { await rooms.load(store) } }
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
        case .energie:
            if store.allows(.strom), let pv = store.num(EnergyConfig.pv) {
                let soc = store.num(EnergyConfig.soc).map { "Akku \(Int($0.rounded())) %" } ?? "Sonne"
                return Facts(big: pv < 20 ? "keine Sonne" : Fmt.watts(pv), small: pv < 20 ? soc : "\(soc) · Sonne")
            }
            return Facts(big: "Technik", small: "Heizung · Pool · Internet")
        case .haushalt:
            let n = store.runningAppliances
            return Facts(big: n == 0 ? "alles aus" : (n == 1 ? "1 läuft" : "\(n) laufen"),
                         small: "Geräte · Essen · Musik")
        case .sicherheit:
            if !store.smokeAlarm.isEmpty { return Facts(big: "RAUCH!", small: "Rauchmelder", alert: true) }
            let windows = store.openContacts(["window"]) ?? 0
            let doors = store.openContacts(["door", "garage_door"]) ?? 0
            let big = windows + doors == 0 ? "alles zu" : "\(windows + doors) offen"
            let ring = store.lastRing.map { "Klingel \(DayText.short($0))" } ?? "Haustür · Rauchmelder"
            return Facts(big: big, small: ring, alert: false)
        case .familie:
            return Facts(big: "Schule", small: store.isParent && store.activeKid == nil ? "Kinder · Dokumente · Karte" : "Stundenplan · Mappe")
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

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var parent: Bool { store.isParent && store.activeKid == nil }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            switch area {
            case .energie: energie
            case .haushalt: haushalt
            case .sicherheit: sicherheit
            case .familie: familie
            }
        }
        .padding(.horizontal)
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showMap) { FamilyMapView() }
    }

    @ViewBuilder private var energie: some View {
        if store.allows(.strom) {
            NavigationLink { EnergyView() } label: { HubTile(title: "Haus & Strom", symbol: "bolt.fill", color: .yellow) }
        }
        if store.allows(.heizung) {
            NavigationLink { HeatingView() } label: { HubTile(title: "Heizung", symbol: "heat.waves", color: .red) }
        }
        if store.allows(.beschattung) {
            NavigationLink { ShadingView() } label: { HubTile(title: "Beschattung", symbol: "blinds.horizontal.closed", color: .orange) }
        }
        if store.allows(.pool) {
            NavigationLink { PoolView() } label: { HubTile(title: "Pool", symbol: "figure.pool.swim", color: .blue) }
        }
        if store.allows(.bewaesserung) {
            NavigationLink { IrrigationView() } label: { HubTile(title: "Bewässerung", symbol: "sprinkler.and.droplets.fill", color: .cyan) }
        }
        if store.allows(.internet) {
            NavigationLink { NetworkView() } label: { HubTile(title: "Internet", symbol: "globe.europe.africa.fill", color: .indigo) }
        }
        if parent {
            NavigationLink { DevicesView() } label: { HubTile(title: "Zigbee-Geräte", symbol: "dot.radiowaves.left.and.right", color: .purple) }
        }
    }

    @ViewBuilder private var haushalt: some View {
        if store.allows(.waesche) {
            NavigationLink { AppliancesView() } label: { HubTile(title: "Haushaltsgeräte", symbol: "washer.fill", color: .teal) }
        }
        if store.allows(.saugroboter) {
            NavigationLink { VacuumsView() } label: { HubTile(title: "Saugroboter", symbol: "fan.fill", color: .mint) }
        }
        if store.allows(.essensplan) {
            NavigationLink { MealPlanView() } label: { HubTile(title: "Essensplan", symbol: "fork.knife", color: .orange) }
        }
        if store.allows(.musik) {
            NavigationLink { MusicView() } label: { HubTile(title: "Musik", symbol: "hifispeaker.2.fill", color: .pink) }
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
        if parent {
            Button { showMap = true } label: { HubTile(title: "Wo sind alle?", symbol: "map.fill", color: .green) }
        }
    }

    @ViewBuilder private var familie: some View {
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
}
