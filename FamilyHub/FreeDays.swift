import SwiftUI

// MARK: - Kalender: freie Tage finden
//
// Personen + Wochentage (z. B. Sa + So) + Tageszeit wählen → die nächsten Wochen, in denen an allen
// gewählten Tagen niemand der Gewählten einen Termin hat. Familienkalender zählt für alle,
// Feiertage und Schulferien zählen nicht als belegt. Für Kinder zählt Schule (Mo–Fr vormittags) als belegt,
// außer in den Ferien oder an Feiertagen.

struct FreeDaysView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var people: Set<String> = Set(FamilyConfig.people.map(\.id))
    @State private var weekdays: Set<Int> = [7, 1]           // Calendar.weekday: 1 = So, 2 = Mo … 7 = Sa
    @State private var fromHour = 0                           // 0 = ganzer Tag, 14, 18
    @State private var schoolCounts = true
    @State private var searching = false
    @State private var results: [FreeWeek] = []
    @State private var checkedWeeks = 0
    @State private var searched = false
    @State private var addDay: DayItem?

    private static let order = [2, 3, 4, 5, 6, 7, 1]             // Mo … So
    private static let short = [1: "So", 2: "Mo", 3: "Di", 4: "Mi", 5: "Do", 6: "Fr", 7: "Sa"]
    private static let holidayCalendars = ["calendar.schulferien_bayern", "calendar.deutschland_by"]

    struct FreeWeek: Identifiable {
        let days: [Date]
        var id: Date { days[0] }
    }

    private var kidSelected: Bool {
        FamilyConfig.kids.contains { people.contains($0.person) }
    }
    private var weekdaySelected: Bool { !weekdays.isDisjoint(with: [2, 3, 4, 5, 6]) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wer soll frei sein?") {
                    HStack(spacing: 10) {
                        ForEach(FamilyConfig.people) { p in personChip(p) }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(Self.order, id: \.self) { d in dayChip(d) }
                    }
                    .padding(.vertical, 4)
                    HStack {
                        preset("Wochenende", [7, 1])
                        preset("Fr–So", [6, 7, 1])
                        preset("Ein Tag Sa", [7])
                    }
                } header: {
                    Text("An welchen Tagen?")
                } footer: {
                    Text("Alle gewählten Tage einer Woche müssen frei sein.")
                }

                Section {
                    Picker("Tageszeit", selection: $fromHour) {
                        Text("Ganzer Tag").tag(0)
                        Text("Ab 14 Uhr").tag(14)
                        Text("Ab 18 Uhr").tag(18)
                    }
                    .pickerStyle(.segmented)
                    if kidSelected && weekdaySelected && fromHour == 0 {
                        Toggle("Schule zählt als belegt", isOn: $schoolCounts)
                    }
                } header: {
                    Text("Wann am Tag?")
                } footer: {
                    Text("Feiertage und Schulferien zählen nicht als Termin.")
                }

                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Label("Freie Tage suchen", systemImage: "magnifyingglass")
                            Spacer()
                            if searching { ProgressView() }
                        }
                    }
                    .disabled(searching || people.isEmpty || weekdays.isEmpty)
                }

                if searched {
                    resultsSection
                }
            }
            .navigationTitle("Freie Tage finden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
            .sheet(item: $addDay) { item in AddEventView(day: item.day) }
        }
    }

    // MARK: Ergebnis

    @ViewBuilder private var resultsSection: some View {
        Section {
            if results.isEmpty {
                Label("In den nächsten \(checkedWeeks) Wochen ist nichts komplett frei.", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { w in
                Button { addDay = DayItem(day: w.days[0]) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(w)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text(subtitle(w)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                    }
                }
            }
        } header: {
            Text(results.isEmpty ? "Ergebnis" : "Als Nächstes frei")
        } footer: {
            if !results.isEmpty { Text("Antippen, um gleich einen Termin anzulegen.") }
        }
    }

    private func title(_ w: FreeWeek) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EE d. MMM"
        if w.days.count == 1 { return f.string(from: w.days[0]) }
        return f.string(from: w.days[0]) + " – " + f.string(from: w.days[w.days.count - 1])
    }

    private func subtitle(_ w: FreeWeek) -> String {
        let weeks = Calendar.current.dateComponents([.weekOfYear], from: Calendar.current.startOfDay(for: Date()), to: w.days[0]).weekOfYear ?? 0
        let when = weeks == 0 ? "diese Woche" : (weeks == 1 ? "nächste Woche" : "in \(weeks) Wochen")
        let time = fromHour == 0 ? "ganztags" : "ab \(fromHour) Uhr"
        return "\(when) · \(time) frei"
    }

    // MARK: Auswahl

    private func personChip(_ p: FamilyConfig.Person) -> some View {
        let on = people.contains(p.id)
        return Button {
            if on { people.remove(p.id) } else { people.insert(p.id) }
        } label: {
            VStack(spacing: 4) {
                Avatar(image: store.pictures[p.id], name: p.name, color: p.color, initialFont: .headline, ring: on ? 2.5 : 0)
                    .frame(width: 44, height: 44)
                    .opacity(on ? 1 : 0.35)
                Text(p.name).font(.caption2.weight(.semibold)).foregroundStyle(on ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.name) \(on ? "ausgewählt" : "nicht ausgewählt")")
    }

    private func dayChip(_ d: Int) -> some View {
        let on = weekdays.contains(d)
        return Button {
            if on { weekdays.remove(d) } else { weekdays.insert(d) }
        } label: {
            Text(Self.short[d] ?? "")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func preset(_ title: String, _ days: Set<Int>) -> some View {
        Button(title) { weekdays = days }
            .buttonStyle(.bordered)
            .font(.caption)
    }

    // MARK: Suche

    private func search() async {
        searching = true
        defer { searching = false; searched = true }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weeks = 26
        guard let end = cal.date(byAdding: .day, value: weeks * 7 + 7, to: today) else { return }

        // Kalender der Gewählten + Familienkalender
        let personCals = CalendarOwner.persons.filter { people.contains($0.value) }.map(\.key)
        let blockCals = Array(Set(personCals).union(CalendarOwner.family))
        var busy: [HAEvent] = []
        var holidays: [HAEvent] = []
        let client = store.client!
        await withTaskGroup(of: (String, [HAEvent]).self) { group in
            for c in blockCals + Self.holidayCalendars {
                group.addTask {
                    let ev = (try? await client.events(calendar: c, from: today, to: end)) ?? []
                    return (c, ev)
                }
            }
            for await (c, ev) in group {
                if Self.holidayCalendars.contains(c) { holidays += ev } else { busy += ev }
            }
        }

        let kids = FamilyConfig.kids.filter { people.contains($0.person) }
        let orderIndex = Dictionary(uniqueKeysWithValues: Self.order.enumerated().map { ($1, $0) })
        let wanted = weekdays.sorted { (orderIndex[$0] ?? 0) < (orderIndex[$1] ?? 0) }

        // Wochenanfang (Montag) dieser Woche
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        comps.weekday = 2
        guard var monday = cal.date(from: comps) else { return }
        if monday > today { monday = cal.date(byAdding: .day, value: -7, to: monday) ?? monday }

        var found: [FreeWeek] = []
        var checked = 0
        for w in 0..<weeks {
            guard let weekStart = cal.date(byAdding: .day, value: w * 7, to: monday) else { continue }
            let days: [Date] = wanted.compactMap { wd in
                cal.date(byAdding: .day, value: orderIndex[wd] ?? 0, to: weekStart)
            }
            guard let first = days.first, first >= today else { continue }
            checked += 1
            let free = days.allSatisfy { day in
                isFree(day, busy: busy, holidays: holidays, kids: !kids.isEmpty)
            }
            if free { found.append(FreeWeek(days: days)) }
            if found.count >= 8 { break }
        }
        results = found
        checkedWeeks = checked
    }

    private func isFree(_ day: Date, busy: [HAEvent], holidays: [HAEvent], kids: Bool) -> Bool {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart),
              let windowStart = cal.date(byAdding: .hour, value: fromHour, to: dayStart) else { return false }

        // Termine im Zeitfenster
        let blocked = busy.contains { e in
            if e.allDay { return e.start < dayEnd && e.end > dayStart }
            return e.start < dayEnd && e.end > windowStart
        }
        if blocked { return false }

        // Schule (Kinder, Mo–Fr, ganzer Tag) – außer Ferien/Feiertag
        if kids && schoolCounts && fromHour == 0 {
            let wd = cal.component(.weekday, from: day)
            if (2...6).contains(wd) {
                let off = holidays.contains { $0.start < dayEnd && $0.end > dayStart }
                if !off { return false }
            }
        }
        return true
    }
}

struct DayItem: Identifiable {
    let day: Date
    var id: Date { day }
}
