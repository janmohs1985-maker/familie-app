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
            }
            .sheet(isPresented: $showAdd) { AddEventView() }
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
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: false, vertical: true)
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
                Text(event.summary).font(.subheadline.weight(.semibold)).lineLimit(2)
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
    }
}

struct AddEventView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var calendarID = ""
    @State private var allDay = false
    @State private var start = AddEventView.nextFullHour()
    @State private var end = AddEventView.nextFullHour().addingTimeInterval(3600)
    @State private var location = ""
    @State private var saving = false
    @State private var error: String?

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
                    TextField("Ort (optional)", text: $location)
                }
                Section {
                    Picker("Kalender", selection: $calendarID) {
                        ForEach(store.writableCalendars) { c in
                            Label { Text(c.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(store.color(for: c.entity_id)) }
                                .tag(c.entity_id)
                        }
                    }
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
            .onAppear { if calendarID.isEmpty { calendarID = store.writableCalendars.first?.entity_id ?? "" } }
            .onChange(of: start) { old, new in
                // Dauer beibehalten, wenn der Beginn verschoben wird
                end = end.addingTimeInterval(new.timeIntervalSince(old))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Sichern") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || calendarID.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await store.createEvent(calendar: calendarID, title: title.trimmingCharacters(in: .whitespaces),
                                        start: start, end: max(end, start), allDay: allDay, location: location)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
