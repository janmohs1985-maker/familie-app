import SwiftUI

// MARK: - Kalender: oben die Woche auf einen Blick, darunter alles Weitere nach Monaten

enum CalMath {
    /// Kalender mit Montag als erstem Wochentag
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }()

    static func weekStart(offset: Int) -> Date {
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return cal.date(byAdding: .weekOfYear, value: offset, to: start) ?? start
    }

    static func days(from start: Date) -> [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    static func sorted(_ list: [HAEvent]) -> [HAEvent] {
        list.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            return a.start < b.start
        }
    }

    /// Termine, die an diesem Tag stattfinden (auch mehrtägige)
    static func events(_ all: [HAEvent], on day: Date) -> [HAEvent] {
        let s = cal.startOfDay(for: day)
        guard let e = cal.date(byAdding: .day, value: 1, to: s) else { return [] }
        return sorted(all.filter { $0.start < e && $0.end > s })
    }

    static func isMultiDay(_ ev: HAEvent) -> Bool {
        guard ev.allDay else { return false }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: ev.start), to: cal.startOfDay(for: ev.end)).day ?? 1
        return days > 1
    }

    /// „2.–6. Nov.“ bzw. „30. Okt. – 3. Nov.“
    static func span(_ ev: HAEvent) -> String {
        let last = ev.allDay ? (cal.date(byAdding: .day, value: -1, to: ev.end) ?? ev.end) : ev.end
        let de = Locale(identifier: "de_DE")
        if cal.isDate(ev.start, equalTo: last, toGranularity: .month) {
            return "\(cal.component(.day, from: ev.start)).–" + last.formatted(.dateTime.day().month(.abbreviated).locale(de))
        }
        return ev.start.formatted(.dateTime.day().month(.abbreviated).locale(de)) + " – "
            + last.formatted(.dateTime.day().month(.abbreviated).locale(de))
    }

    static func time(_ ev: HAEvent) -> String {
        if isMultiDay(ev) { return span(ev) }
        if ev.allDay { return "Ganztägig" }
        return ev.start.formatted(date: .omitted, time: .shortened)
    }
}

struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false
    @State private var showFree = false
    @State private var weekOffset = 0

    private var weekStart: Date { CalMath.weekStart(offset: weekOffset) }
    private var weekEnd: Date { CalMath.cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart }

    private struct MonthGroup: Identifiable {
        let month: Date
        let events: [HAEvent]
        var id: Date { month }
    }

    /// Alles nach der angezeigten Woche, nach Monaten gruppiert
    private var months: [MonthGroup] {
        let cal = CalMath.cal
        let later = store.events.filter { $0.start >= weekEnd }
        var buckets: [Date: [HAEvent]] = [:]
        for e in later {
            let m = cal.dateInterval(of: .month, for: e.start)?.start ?? e.start
            buckets[m, default: []].append(e)
        }
        return buckets.keys.sorted().map { m in
            MonthGroup(month: m, events: buckets[m]!.sorted { $0.start < $1.start })
        }
    }

    private var weekCount: Int {
        store.events.filter { $0.start < weekEnd && $0.end > max(weekStart, Date()) }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.calendars.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Kalender", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("In Home Assistant ist noch kein Familienkalender eingerichtet.")
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ErrorBanner()
                            weekCard
                            if months.isEmpty {
                                Text("Danach steht noch nichts im Kalender.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            ForEach(months) { g in monthCard(g) }
                        }
                        .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .refreshable { await store.refreshCalendar() }
            .navigationTitle("Kalender")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { TimetableView(kid: store.activeKid) } label: {
                        Label("Stundenplan", systemImage: "graduationcap")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !store.writableCalendars.isEmpty {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showFree = true } label: { Image(systemName: "calendar.badge.checkmark") }
                        .accessibilityLabel("Freie Tage finden")
                }
            }
            .sheet(isPresented: $showAdd) { AddEventView() }
            .sheet(item: Bindable(store).eventToShow) { e in EventDetailView(event: e) }
            .sheet(isPresented: $showFree) { FreeDaysView() }
        }
    }

    // MARK: Woche

    private var weekTitle: String {
        switch weekOffset {
        case 0: return "Diese Woche"
        case 1: return "Nächste Woche"
        default: return "KW \(CalMath.cal.component(.weekOfYear, from: weekStart))"
        }
    }

    private var weekRange: String {
        let de = Locale(identifier: "de_DE")
        let last = CalMath.cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return weekStart.formatted(.dateTime.day().month(.abbreviated).locale(de)) + " – "
            + last.formatted(.dateTime.day().month(.abbreviated).locale(de))
    }

    private var weekSubtitle: String {
        let n = weekCount
        if n == 0 { return weekRange }
        let word = n == 1 ? "Termin" : "Termine"
        return weekRange + " · \(n) " + word
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(weekTitle).font(.title3.weight(.bold))
                    Text(weekSubtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if weekOffset > 0 {
                    Button("Heute") { withAnimation { weekOffset = 0 } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
                Button { withAnimation { weekOffset -= 1 } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .disabled(weekOffset == 0)
                Button { withAnimation { weekOffset += 1 } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .disabled(weekOffset >= 12)
            }
            VStack(spacing: 0) {
                let days = CalMath.days(from: weekStart)
                ForEach(days.indices, id: \.self) { i in
                    if i > 0 { Divider().padding(.leading, 52) }
                    WeekDayRow(day: days[i], events: CalMath.events(store.events, on: days[i]))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -60, weekOffset < 12 { withAnimation { weekOffset += 1 } }
            if v.translation.width > 60, weekOffset > 0 { withAnimation { weekOffset -= 1 } }
        })
    }

    // MARK: Monate

    private func monthCard(_ g: MonthGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.month.formatted(.dateTime.month(.wide).locale(Locale(identifier: "de_DE"))))
                    .font(.title3.weight(.bold))
                if CalMath.cal.component(.year, from: g.month) != CalMath.cal.component(.year, from: Date()) {
                    Text(String(CalMath.cal.component(.year, from: g.month)))
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(g.events.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(g.events.indices, id: \.self) { i in
                    if i > 0 { Divider().padding(.leading, 52) }
                    MonthEventRow(event: g.events[i])
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Ein Tag in der Wochenübersicht
struct WeekDayRow: View {
    @Environment(AppStore.self) private var store
    let day: Date
    let events: [HAEvent]

    private var isToday: Bool { CalMath.cal.isDateInToday(day) }
    private var isPast: Bool { day < CalMath.cal.startOfDay(for: Date()) }
    private var isWeekend: Bool { CalMath.cal.isDateInWeekend(day) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "de_DE"))).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isToday ? Color.accentColor : (isWeekend ? .secondary : .primary))
                Text("\(CalMath.cal.component(.day, from: day))")
                    .font(.title3.weight(isToday ? .bold : .semibold))
                    .foregroundStyle(isToday ? .white : .primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isToday ? Color.accentColor : .clear))
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: 5) {
                if events.isEmpty {
                    Text(isPast ? "–" : "Nichts geplant")
                        .font(.subheadline).foregroundStyle(.tertiary)
                        .padding(.top, 14)
                } else {
                    ForEach(events) { e in WeekEventPill(event: e) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, events.isEmpty ? 0 : 6)
        }
        .padding(.vertical, 8)
        .opacity(isPast ? 0.45 : 1)
    }
}

struct WeekEventPill: View {
    @Environment(AppStore.self) private var store
    let event: HAEvent

    private var timeLabel: String {
        event.allDay ? "ganzt." : event.start.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        let color = store.color(for: event.calendarID)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            Text(timeLabel)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(event.summary).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            EventOwnerBadge(event: event, size: 18)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { store.eventToShow = event }
    }
}

/// Termin in der Monatsliste mit Datums-Kästchen
struct MonthEventRow: View {
    @Environment(AppStore.self) private var store
    let event: HAEvent

    var body: some View {
        let color = store.color(for: event.calendarID)
        let de = Locale(identifier: "de_DE")
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                Text(event.start.formatted(.dateTime.weekday(.abbreviated).locale(de)).uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(color)
                Text("\(CalMath.cal.component(.day, from: event.start))")
                    .font(.title3.weight(.bold))
            }
            .frame(width: 40, height: 44)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    EventOwnerBadge(event: event, size: 18)
                    Text(event.summary).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(CalMath.time(event))
                    if let name = store.calendars.first(where: { $0.entity_id == event.calendarID })?.name {
                        Text("·")
                        Text(name)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let loc = event.location, !loc.isEmpty {
                    Label(loc, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { store.eventToShow = event }
    }
}

struct AddEventView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var who = WhoSelection()
    @State private var allDay = false
    @State private var start = AddEventView.nextFullHour()
    @State private var end = AddEventView.nextFullHour().addingTimeInterval(3600)
    @State private var location = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var error: String?

    init() {}

    /// Vorbelegt mit einem Tag (aus „Freie Tage finden“): ganztägig
    init(day: Date) {
        let start = Calendar.current.startOfDay(for: day)
        _start = State(initialValue: start)
        _end = State(initialValue: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
        _allDay = State(initialValue: true)
    }

    static func nextFullHour() -> Date {
        let cal = Calendar.current
        let now = Date()
        return cal.date(bySettingHour: cal.component(.hour, from: now) + 1 > 23 ? 23 : cal.component(.hour, from: now) + 1,
                        minute: 0, second: 0, of: now) ?? now
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $title)
                    LocationField(text: $location)
                    TextField("Notiz (optional)", text: $notes, axis: .vertical)
                }
                Section("Für wen?") {
                    WhoPicker(selection: $who)
                }
                Section {
                    Toggle("Ganztägig", isOn: $allDay)
                    DatePicker("Beginn", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ende", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Neuer Termin")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if who.isEmpty { who = WhoSelection.initial(store) } }
            .onChange(of: start) { old, new in
                // Dauer beibehalten, wenn der Beginn verschoben wird
                end = end.addingTimeInterval(new.timeIntervalSince(old))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || who.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await store.createEvent(calendar: who.calendar, title: title.trimmingCharacters(in: .whitespaces),
                                        start: start, end: max(end, start), allDay: allDay,
                                        location: location.trimmingCharacters(in: .whitespaces),
                                        notes: EventPeople.compose(notes: notes, people: who.peopleForMarker))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Wem gehört der Termin? Kleines Gesicht neben dem Termin

enum CalendarOwner {
    /// Kalender → Person (Foto aus Home Assistant); Familienkalender bekommt ein Haus-Symbol
    static let persons: [String: String] = [
        "calendar.jan": "person.mohs",
        "calendar.vanessa": "person.vanessa",
        "calendar.emma": "person.emma",
        "calendar.leoni": "person.leoni",
    ]
    static let family: Set<String> = ["calendar.personlicher_kalender"]
}

struct CalendarOwnerBadge: View {
    @Environment(AppStore.self) private var store
    let calendarID: String
    var size: CGFloat = 20

    var body: some View {
        if let pid = CalendarOwner.persons[calendarID], let p = FamilyConfig.people.first(where: { $0.id == pid }) {
            Avatar(image: store.pictures[pid], name: p.name, color: p.color,
                   initialFont: .system(size: size * 0.5, weight: .bold), ring: 1.5)
                .frame(width: size, height: size)
                .accessibilityLabel(p.name)
        } else if CalendarOwner.family.contains(calendarID) {
            Image(systemName: "house.fill")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(store.color(for: calendarID).gradient, in: Circle())
                .accessibilityLabel("Familie")
        }
    }
}


// MARK: - Ort mit Vorschlägen (zuletzt benutzte Orte)

struct LocationField: View {
    @Environment(AppStore.self) private var store
    @Binding var text: String

    /// Orte aus den geladenen Terminen, häufigste zuerst
    private var suggestions: [String] {
        var count: [String: Int] = [:]
        for e in store.events { if let l = e.location?.trimmingCharacters(in: .whitespaces), !l.isEmpty { count[l, default: 0] += 1 } }
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        return count.sorted { $0.value > $1.value }.map(\.key)
            .filter { q.isEmpty || ($0.lowercased().contains(q) && $0.lowercased() != q) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField("Ort", text: $text)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { text = s }
                                .font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Termin antippen: Details, für Jan & Vanessa bearbeiten/löschen

struct EventDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let event: HAEvent

    @State private var title = ""
    @State private var who = WhoSelection()
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var location = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var loaded = false

    private var editable: Bool { store.canEditEvents && event.uid != nil }
    private var calendarName: String {
        store.calendars.first { $0.entity_id == event.calendarID }?.name ?? event.calendarID
    }

    var body: some View {
        NavigationStack {
            Form {
                if editable { editForm } else { readOnly }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle(editable ? "Termin bearbeiten" : "Termin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(editable ? "Abbrechen" : "Fertig") { dismiss() } }
                if editable {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Sichern") { Task { await save() } }
                                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .confirmationDialog(event.isSeries ? "Ganze Serie löschen?" : "Termin löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(event.isSeries ? "Alle Termine der Serie löschen" : "Löschen", role: .destructive) { Task { await delete() } }
            } message: {
                Text(event.isSeries ? "„\(event.summary)“ ist ein Serientermin – gelöscht werden alle Termine der Serie."
                                    : "„\(event.summary)“ wird aus dem Kalender gelöscht.")
            }
            .onAppear(perform: load)
            .onChange(of: start) { old, new in
                if loaded { end = end.addingTimeInterval(new.timeIntervalSince(old)) }
            }
        }
    }

    @ViewBuilder private var editForm: some View {
        Section {
            TextField("Titel", text: $title)
            LocationField(text: $location)
            TextField("Notiz", text: $notes, axis: .vertical)
        }
        Section("Für wen?") {
            WhoPicker(selection: $who)
        }
        Section {
            Toggle("Ganztägig", isOn: $allDay).disabled(event.isSeries)
            DatePicker("Beginn", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                .disabled(event.isSeries)
            DatePicker("Ende", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                .disabled(event.isSeries)
        } footer: {
            if event.isSeries {
                Text("Serientermin: Titel, Ort und Notiz gelten für die ganze Serie. Die Uhrzeit bitte direkt im Kalender ändern.")
            }
        }
        Section {
            Button(role: .destructive) { confirmDelete = true } label: {
                Label(event.isSeries ? "Serie löschen" : "Termin löschen", systemImage: "trash")
            }
        }
    }

    @ViewBuilder private var readOnly: some View {
        Section {
            Text(event.summary).font(.headline)
            LabeledContent("Wann", value: CalMath.time(event))
            LabeledContent("Tag", value: event.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            if let l = event.location, !l.isEmpty { LabeledContent("Ort", value: l) }
            LabeledContent("Kalender", value: calendarName)
            if !event.participants.isEmpty {
                LabeledContent("Dabei", value: FamilyConfig.people.filter { event.participants.contains($0.id) }.map(\.name).joined(separator: ", "))
            }
        }
        if !event.notes.isEmpty {
            Section("Notiz") { Text(event.notes) }
        }
        if store.isParent == false || store.activeKid != nil {
            Section { Text("Termine ändern können Mama und Papa.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        guard !loaded else { return }
        title = event.summary
        who = WhoSelection(event: event)
        allDay = event.allDay
        start = event.start
        // ganztägig: Ende ist exklusiv → letzter Tag anzeigen
        end = event.allDay ? (Calendar.current.date(byAdding: .day, value: -1, to: event.end) ?? event.end) : event.end
        location = event.location ?? ""
        notes = event.notes
        DispatchQueue.main.async { loaded = true }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await store.updateEvent(event, calendar: who.calendar, title: title.trimmingCharacters(in: .whitespaces),
                                        start: start, end: max(end, start), allDay: allDay,
                                        location: location.trimmingCharacters(in: .whitespaces),
                                        notes: EventPeople.compose(notes: notes, people: who.peopleForMarker))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await store.deleteEvent(event)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}


// MARK: - Für wen? Gesichter antippen (mehrere möglich) oder „Familie“
//
// 1 Person → ihr eigener Kalender. Mehrere → Familienkalender mit „👥 Dabei: …“ in der Notiz (einmal, nicht doppelt).
// „Familie“ (oder alle vier) → Familienkalender ohne Zusatz.

struct WhoSelection: Equatable {
    var people: Set<String> = []     // person.*
    var family = false

    var isEmpty: Bool { people.isEmpty && !family }

    static let familyCalendar = CalendarOwner.family.first ?? "calendar.personlicher_kalender"
    static func calendar(of person: String) -> String? { CalendarOwner.persons.first { $0.value == person }?.key }

    var everyone: Bool { people.count == FamilyConfig.people.count }

    var calendar: String {
        if !family, people.count == 1, let p = people.first, let c = Self.calendar(of: p) { return c }
        return Self.familyCalendar
    }
    /// Für die „Dabei“-Zeile: nur bei 2–3 Personen
    var peopleForMarker: [String] {
        family || everyone || people.count < 2 ? [] : FamilyConfig.people.map(\.id).filter { people.contains($0) }
    }

    init() {}

    init(event: HAEvent) {
        if let p = CalendarOwner.persons[event.calendarID] {
            people = [p]
        } else if !event.participants.isEmpty {
            people = Set(event.participants)
        } else {
            family = true
        }
    }

    @MainActor static func initial(_ store: AppStore) -> WhoSelection {
        var w = WhoSelection()
        if let me = store.myKey,
           let p = FamilyConfig.parent(me)?.person ?? FamilyConfig.kid(me)?.person {
            w.people = [p]
        } else {
            w.family = true
        }
        return w
    }
}

struct WhoPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: WhoSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(FamilyConfig.people) { p in face(p) }
                familyButton
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var hint: String {
        if selection.family || selection.everyone { return "Kommt in den Familienkalender." }
        let names = FamilyConfig.people.filter { selection.people.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "Bitte mindestens eine Person wählen."
        case 1: return "Kommt in den Kalender von \(names[0])."
        default: return "Kommt einmal in den Familienkalender – mit \(names.joined(separator: " & ")) als dabei."
        }
    }

    private func face(_ p: FamilyConfig.Person) -> some View {
        let on = !selection.family && selection.people.contains(p.id)
        return Button {
            selection.family = false
            if on { selection.people.remove(p.id) } else { selection.people.insert(p.id) }
        } label: {
            VStack(spacing: 4) {
                Avatar(image: store.pictures[p.id], name: p.name, color: p.color, initialFont: .headline, ring: on ? 2.5 : 0)
                    .frame(width: 42, height: 42)
                    .opacity(on ? 1 : 0.35)
                Text(p.name).font(.caption2.weight(.semibold)).foregroundStyle(on ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.name) \(on ? "ausgewählt" : "nicht ausgewählt")")
    }

    private var familyButton: some View {
        let on = selection.family
        let color = store.color(for: WhoSelection.familyCalendar)
        return Button {
            selection.family.toggle()
            if selection.family { selection.people = [] }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "house.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(color.gradient, in: Circle())
                    .opacity(on ? 1 : 0.35)
                Text("Familie").font(.caption2.weight(.semibold)).foregroundStyle(on ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// Gesichter zum Termin: eigener Kalender → eine Person; Familienkalender mit „Dabei“ → mehrere; sonst Haus
struct EventOwnerBadge: View {
    @Environment(AppStore.self) private var store
    let event: HAEvent
    var size: CGFloat = 20

    var body: some View {
        let people = event.participants
        if people.count > 1 {
            HStack(spacing: -size * 0.35) {
                ForEach(FamilyConfig.people.filter { people.contains($0.id) }) { p in
                    Avatar(image: store.pictures[p.id], name: p.name, color: p.color,
                           initialFont: .system(size: size * 0.5, weight: .bold), ring: 1.5)
                        .frame(width: size, height: size)
                }
            }
            .accessibilityLabel(FamilyConfig.people.filter { people.contains($0.id) }.map(\.name).joined(separator: " und "))
        } else {
            CalendarOwnerBadge(calendarID: event.calendarID, size: size)
        }
    }
}
