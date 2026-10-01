import SwiftUI
import MapKit

// MARK: - Bild aus Home Assistant (mit Anmeldung geladen)

struct HAImage: View {
    @Environment(AppStore.self) private var store
    let path: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            if let img = await store.client.image(path: path) { image = img; failed = false } else if image == nil { failed = true }
        }
    }
}

// MARK: - Karte einer Person (nur Eltern)

struct PersonMapView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: FamilyConfig.Person

    @State private var position: MapCameraPosition = .automatic
    @State private var address: String?
    @State private var track: [CLLocationCoordinate2D] = []

    private var state: HAState? { store.states[person.id] }
    private var coord: CLLocationCoordinate2D? { store.coordinate(of: person.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let coord {
                        Map(position: $position) {
                            if track.count > 1 {
                                MapPolyline(coordinates: track).stroke(person.color.opacity(0.7), lineWidth: 4)
                            }
                            if let home = store.homeCoordinate {
                                Annotation("Zuhause", coordinate: home) {
                                    Image(systemName: "house.fill").font(.caption).foregroundStyle(.white)
                                        .padding(6).background(Color.green, in: Circle())
                                }
                            }
                            Annotation(person.name, coordinate: coord) {
                                Avatar(image: store.pictures[person.id], name: person.name, color: person.color)
                                    .frame(width: 44, height: 44)
                                    .shadow(radius: 3)
                            }
                        }
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                    } else {
                        ContentUnavailableView("Kein Standort", systemImage: "location.slash",
                                               description: Text("Für \(person.name) liegt gerade kein Standort vor."))
                    }
                }

                Section {
                    LabeledContent("Ort", value: PersonText.status(state?.state ?? "unknown"))
                    if let since = HADate.parse(state?.last_changed) {
                        LabeledContent("Seit", value: since.formatted(.relative(presentation: .named)))
                    }
                    if let address { LabeledContent("Adresse", value: address) }
                    if let d = store.distanceHome(of: person.id), state?.state != "home" {
                        LabeledContent("Entfernung", value: Measurement(value: d / 1000, unit: UnitLength.kilometers)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                    }
                    if let b = store.battery(of: person.id) {
                        LabeledContent("Akku") {
                            Label("\(b) %", systemImage: batterySymbol(b))
                                .foregroundStyle(b <= 15 ? Color.red : Color.primary)
                        }
                    }
                    if let t = store.locationAge(of: person.id) {
                        LabeledContent("Standort von", value: LocationAge.long(t))
                    }
                    if let acc = state?.attr("gps_accuracy")?.int {
                        LabeledContent("Genauigkeit", value: "± \(acc) m")
                    }
                }

                if let kid = store.kidID(forPerson: person.id) {
                    DoorOpeningsSection(kid: kid)
                }

                if let coord, state?.state != "home" {
                    Section {
                        Button {
                            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
                            item.name = person.name
                            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                        } label: {
                            Label("Route in Apple Karten", systemImage: "car.fill")
                        }
                    }
                }
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .onAppear { store.requestFreshLocations([person.id]) }
            .onChange(of: coord?.latitude) { _, _ in
                guard let c = coord, track.count <= 1 else { return }
                withAnimation(.easeInOut(duration: 0.8)) {
                    position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800))
                }
            }
            .task {
                guard let coord else { return }
                position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 800, longitudinalMeters: 800))
                async let t = store.track(of: person.id)
                async let a = Self.reverseGeocode(coord)
                track = await t
                address = await a
                if track.count > 1 { position = .automatic }
            }
        }
    }

    private func batterySymbol(_ b: Int) -> String {
        switch b {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func reverseGeocode(_ c: CLLocationCoordinate2D) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first
        else { return nil }
        let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = [p.postalCode, p.locality].compactMap { $0 }.joined(separator: " ")
        let parts = [p.name == street ? nil : p.name, street.isEmpty ? nil : street, city.isEmpty ? nil : city].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Ganze Familie auf der Karte

struct FamilyMapView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: FamilyConfig.Person?

    var body: some View {
        NavigationStack {
            Map(initialPosition: .automatic) {
                if let home = store.homeCoordinate {
                    Annotation("Zuhause", coordinate: home) {
                        Image(systemName: "house.fill").font(.caption).foregroundStyle(.white)
                            .padding(6).background(Color.green, in: Circle())
                    }
                }
                ForEach(FamilyConfig.people) { p in
                    if let c = store.coordinate(of: p.id) {
                        Annotation(p.name, coordinate: c) {
                            Button { selected = p } label: {
                                Avatar(image: store.pictures[p.id], name: p.name, color: p.color)
                                    .frame(width: 44, height: 44).shadow(radius: 3)
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    ForEach(FamilyConfig.people) { p in
                        if let t = store.locationAge(of: p.id) {
                            HStack(spacing: 4) {
                                Circle().fill(p.color).frame(width: 7, height: 7)
                                Text(p.name + " " + LocationAge.short(t)).lineLimit(1)
                            }
                        }
                    }
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 8)
            }
            .navigationTitle("Familie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.requestFreshLocations(FamilyConfig.people.map(\.id)) } label: {
                        Image(systemName: "location.circle")
                    }
                    .accessibilityLabel("Standorte jetzt abfragen")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } }
            }
            .onAppear { store.requestFreshLocations() }
            .sheet(item: $selected) { p in PersonMapView(person: p) }
        }
    }
}

// MARK: - Klingel

extension AppStore {
    /// Klingel-Karte auf „Heute“ nur zeigen, wenn es kürzlich geklingelt hat
    var ringRecently: Bool {
        guard let t = lastRing else { return false }
        return Date().timeIntervalSince(t) < 12 * 3600
    }
}

struct DoorbellCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationLink {
            DoorbellView()
        } label: {
            Card(title: "Haustür", symbol: "bell.fill") {
                HStack(spacing: 14) {
                    HAImage(path: "/api/camera_proxy/\(FamilyConfig.doorbellLastRing)?v=\(Int(store.lastRing?.timeIntervalSince1970 ?? 0))")
                        .frame(width: 96, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zuletzt geklingelt").font(.caption).foregroundStyle(.secondary)
                        if let t = store.lastRing {
                            Text(DayText.label(t)).font(.headline)
                            Text(t.formatted(date: .omitted, time: .shortened) + " Uhr").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("–").font(.headline)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct DoorbellView: View {
    @Environment(AppStore.self) private var store
    @State private var liveTick = 0
    @State private var showLive = true
    @State private var zoom: DoorbellRing?
    @State private var deleting: DoorbellRing?
    @State private var confirmAll = false
    @State private var call = false

    private var canDelete: Bool { store.isParent && store.activeKid == nil }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Live", symbol: "video.fill") {
                    if store.states[FamilyConfig.doorbellLive]?.state == "unavailable" {
                        Label("Live-Bild gerade nicht verfügbar", systemImage: "video.slash").foregroundStyle(.secondary)
                    } else {
                        HAImage(path: "/api/camera_proxy/\(FamilyConfig.doorbellLive)?t=\(liveTick)", contentMode: .fit)
                            .aspectRatio(4/3, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if canDelete {
                        Button { call = true } label: {
                            Label("Live & Sprechen", systemImage: "phone.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fullScreenCover(isPresented: $call) { DoorCallView(autoTalk: false) }

                HStack {
                    Text("Letzte Besucher").font(.headline)
                    Spacer()
                    if canDelete && !store.doorbellRings.isEmpty {
                        Button("Alle löschen", role: .destructive) { confirmAll = true }
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 4)
                if store.doorbellRings.isEmpty {
                    Text("Noch keine Aufnahmen. Ab jetzt wird bei jedem Klingeln ein Bild gespeichert (die letzten 10).")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(store.doorbellRings) { r in
                        Button { zoom = r } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HAImage(path: r.imagePath)
                                    .aspectRatio(4/3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(r.time.map { "\(DayText.label($0)), \($0.formatted(date: .omitted, time: .shortened))" } ?? r.label)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if canDelete {
                                Button(role: .destructive) { deleting = r } label: { Label("Löschen", systemImage: "trash") }
                            }
                        }
                    }
                }
                if canDelete && !store.doorbellRings.isEmpty {
                    Text("Bild lange drücken zum Löschen").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Haustür")
        .refreshable { await store.refreshDoorbell() }
        .task {
            await store.refreshDoorbell()
            while !Task.isCancelled {                        // Live-Bild alle 2 Sekunden
                try? await Task.sleep(for: .seconds(2))
                liveTick += 1
            }
        }
        .sheet(item: $zoom) { r in
            NavigationStack {
                HAImage(path: r.imagePath, contentMode: .fit)
                    .background(Color.black)
                    .navigationTitle(r.time.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? r.label)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Fertig") { zoom = nil } }
                        if canDelete {
                            ToolbarItem(placement: .bottomBar) {
                                Button(role: .destructive) { deleting = r } label: { Label("Löschen", systemImage: "trash") }
                                    .tint(.red)
                            }
                        }
                    }
                    .confirmationDialog("Dieses Bild löschen?", isPresented: Binding(get: { deleting != nil && zoom != nil },
                                                                                    set: { if !$0 { deleting = nil } }),
                                        titleVisibility: .visible) {
                        Button("Löschen", role: .destructive) {
                            if let d = deleting { Task { await store.deleteDoorbellRing(d); deleting = nil; zoom = nil } }
                        }
                    }
            }
        }
        .confirmationDialog("Dieses Bild löschen?", isPresented: Binding(get: { deleting != nil && zoom == nil },
                                                                        set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let d = deleting { Task { await store.deleteDoorbellRing(d); deleting = nil } }
            }
        }
        .confirmationDialog("Alle Besucher-Bilder löschen?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive) {
                let all = store.doorbellRings
                Task { for r in all { await store.deleteDoorbellRing(r) } }
            }
        } message: {
            Text("Einträge und Bilder werden endgültig entfernt.")
        }
    }
}


enum LocationAge {
    static func short(_ t: Date) -> String {
        let m = Int(Date().timeIntervalSince(t) / 60)
        if m < 1 { return "jetzt" }
        if m < 60 { return "\(m) Min." }
        if m < 24 * 60 { return "\(m / 60) Std." }
        return "\(m / 1440) T."
    }
    static func long(_ t: Date) -> String {
        let m = Int(Date().timeIntervalSince(t) / 60)
        if m < 1 { return "gerade eben" }
        return "vor " + short(t) + " (" + t.formatted(date: .omitted, time: .shortened) + ")"
    }
}
