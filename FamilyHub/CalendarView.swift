import SwiftUI

struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false

    private struct DayGroup: Identifiable {
        let day: Date
        let events: [HAEvent]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets: [Date: [HAEvent]] = [:]
        for e in store.events where e.end > Date() || e.allDay && cal.isDateInToday(e.start) {
            // mehrtägige Termine ab heute einsortieren
            let d = max(cal.startOfDay(for: e.start), today)
            buckets[d, default: []].append(e)
        }
        return buckets.keys.sorted().map { d in
            DayGroup(day: d, events: buckets[d]!.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) })
        }
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
                } else if groups.isEmpty {
                    ContentUnavailableView("Keine Termine", systemImage: "calendar",
                                           description: Text("In den nächsten drei Wochen steht nichts an."))
                } else {
                    List {
                        ForEach(groups) { g in
                            Section(DayText.label(g.day)) {
                                ForEach(g.events) { e in EventRow(event: e) }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) { ErrorBanner().padding(.horizontal) }
            .refreshable { await store.refreshCalendar() }
            .navigationTitle("Kalender")
            .toolbar {
                if !store.writableCalendars.isEmpty {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddEventView() }
        }
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
