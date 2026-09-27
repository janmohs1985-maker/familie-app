import SwiftUI

// MARK: - Stundenpläne
//
// Hier werden die Stundenpläne gepflegt. Tag 0 = Montag … 4 = Freitag.
// Ein Kind ohne Eintrag zeigt „Noch kein Stundenplan hinterlegt“.

struct Lesson: Hashable {
    let start: String      // "08:00"
    let end: String
    let subject: String
    var isBreak: Bool { subject == "Pause" }
}

enum Timetables {
    private static func L(_ s: String, _ e: String, _ sub: String) -> Lesson { Lesson(start: s, end: e, subject: sub) }

    /// Emma – Grundschule, Schuljahr 2026/27
    static let emma: [[Lesson]] = [
        // Montag
        [L("08:00", "08:45", "WiB"), L("08:45", "09:30", "Info"), L("09:30", "09:50", "Pause"),
         L("09:50", "10:35", "Sport"), L("10:35", "11:20", "Sport"), L("11:20", "11:30", "Pause"),
         L("11:30", "12:15", "Deutsch"), L("12:15", "13:00", "Mathe")],
        // Dienstag
        [L("08:00", "08:45", "Deutsch"), L("08:45", "09:30", "Mathe"), L("09:30", "09:50", "Pause"),
         L("09:50", "10:35", "Ethik"), L("10:35", "11:20", "Ethik"), L("11:20", "11:30", "Pause"),
         L("11:30", "12:15", "Förder")],
        // Mittwoch
        [L("08:00", "08:45", "Deutsch"), L("08:45", "09:30", "Mathe"), L("09:30", "09:50", "Pause"),
         L("09:50", "10:35", "NT"), L("10:35", "11:20", "NT"), L("11:20", "11:30", "Pause"),
         L("11:30", "12:15", "Englisch"), L("12:15", "13:00", "Englisch"), L("13:00", "13:30", "Pause"),
         L("13:30", "14:15", "Kunst"), L("14:15", "15:00", "Kunst")],
        // Donnerstag
        [L("08:00", "08:45", "Deutsch"), L("08:45", "09:30", "Mathe"), L("09:30", "09:50", "Pause"),
         L("09:50", "10:35", "GPG"), L("10:35", "11:20", "GPG"), L("11:20", "11:30", "Pause"),
         L("11:30", "12:15", "WG"), L("12:15", "13:00", "WG")],
        // Freitag
        [L("08:00", "08:45", "Deutsch"), L("08:45", "09:30", "Mathe"), L("09:30", "09:50", "Pause"),
         L("09:50", "10:35", "Englisch"), L("10:35", "11:20", "Englisch"), L("11:20", "11:30", "Pause"),
         L("11:30", "12:15", "Musik"), L("12:15", "13:00", "Musik")],
    ]

    /// Leoni – Klasse 3a, Schuljahr 2026/27 (Beginn 7:45; Stunden à 45 Min., Pausen 20 und 10 Min. angenommen)
    static let leoni: [[Lesson]] = [
        // Montag
        [L("07:45", "08:30", "Deutsch"), L("08:30", "09:15", "Deutsch"), L("09:15", "09:35", "Pause"),
         L("09:35", "10:20", "Mathe"), L("10:20", "11:05", "Mathe"), L("11:05", "11:15", "Pause"),
         L("11:15", "12:00", "Englisch"), L("12:00", "12:45", "HSU")],
        // Dienstag
        [L("07:45", "08:30", "Sport"), L("08:30", "09:15", "Sport"), L("09:15", "09:35", "Pause"),
         L("09:35", "10:20", "Kunst"), L("10:20", "11:05", "Kunst"), L("11:05", "11:15", "Pause"),
         L("11:15", "12:00", "WG"), L("12:00", "12:45", "WG")],
        // Mittwoch
        [L("07:45", "08:30", "Mathe"), L("08:30", "09:15", "Mathe"), L("09:15", "09:35", "Pause"),
         L("09:35", "10:20", "Deutsch"), L("10:20", "11:05", "Musik"), L("11:05", "11:15", "Pause"),
         L("11:15", "12:00", "Religion / Ethik"), L("12:00", "12:45", "Religion / Ethik")],
        // Donnerstag
        [L("07:45", "08:30", "Mathe"), L("08:30", "09:15", "Deutsch"), L("09:15", "09:35", "Pause"),
         L("09:35", "10:20", "Deutsch / Sport (14-tägig)"), L("10:20", "11:05", "Deutsch / Sport (14-tägig)")],
        // Freitag
        [L("07:45", "08:30", "HSU"), L("08:30", "09:15", "HSU"), L("09:15", "09:35", "Pause"),
         L("09:35", "10:20", "Mathe"), L("10:20", "11:05", "Deutsch"), L("11:05", "11:15", "Pause"),
         L("11:15", "12:00", "Flex")],
    ]

    static func plan(for kid: String) -> [[Lesson]] {
        switch kid {
        case "emma": return emma
        case "leoni": return leoni
        default: return []
        }
    }

    static func lessons(kid: String, day: Int) -> [Lesson] {
        let p = plan(for: kid)
        return day < p.count ? p[day] : []
    }

    /// Ende der letzten echten Stunde an diesem Tag (nil = frei oder kein Plan)
    static func schoolEnd(kid: String, day: Int) -> String? {
        lessons(kid: kid, day: day).last { !$0.isBreak }?.end
    }

    /// Fächer des Tages ohne Pausen und ohne Doppelungen, in Reihenfolge
    static func subjects(kid: String, day: Int) -> [String] {
        var seen = Set<String>()
        return lessons(kid: kid, day: day).filter { !$0.isBreak }.map(\.subject).filter { seen.insert($0).inserted }
    }

    static let dayNamesLong = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]

    static func color(_ subject: String) -> Color {
        switch subject {
        case "Deutsch": return .red
        case "Mathe": return .blue
        case "Englisch": return .purple
        case "Sport": return .green
        case "Musik": return .pink
        case "Kunst", "WG": return .orange
        case "NT", "GPG", "HSU": return .teal
        case "Ethik", "Religion / Ethik": return .indigo
        case "Deutsch / Sport (14-tägig)": return .red
        case "Flex": return .mint
        case "Pause": return .gray
        default: return .brown
        }
    }

    /// Minuten seit Mitternacht für "08:45"
    static func minutes(_ t: String) -> Int {
        let p = t.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }
}

// MARK: - Ansicht

struct TimetableView: View {
    @Environment(AppStore.self) private var store
    @State private var kid: String
    @State private var day: Int

    init(kid: String? = nil) {
        _kid = State(initialValue: kid ?? FamilyConfig.kids.first?.id ?? "")
        _day = State(initialValue: ChoreText.todayIndex)
    }

    private var isToday: Bool { day == ChoreText.todayIndex }

    var body: some View {
        List {
            // Kinder-Auswahl: Kinder sehen nur ihren eigenen Plan
            if store.activeKid == nil && FamilyConfig.kids.count > 1 {
                Picker("Kind", selection: $kid) {
                    ForEach(FamilyConfig.kids) { k in Text(k.name).tag(k.id) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Picker("Tag", selection: $day) {
                ForEach(0..<7, id: \.self) { d in Text(ChoreText.dayNames[d]).tag(d) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            let lessons = Timetables.lessons(kid: kid, day: day)
            Section {
                if Timetables.plan(for: kid).isEmpty {
                    ContentUnavailableView("Noch kein Stundenplan", systemImage: "graduationcap",
                                           description: Text("Für \(FamilyConfig.kid(kid)?.name ?? kid) ist noch kein Plan hinterlegt."))
                } else if lessons.isEmpty {
                    Label("Kein Unterricht", systemImage: "sun.max.fill").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lessons.enumerated()), id: \.offset) { _, l in
                        LessonRow(lesson: l, isNow: isToday && isCurrent(l))
                    }
                }
            } header: {
                Text(Timetables.dayNamesLong[day] + (isToday ? " · Heute" : ""))
            } footer: {
                if let end = Timetables.schoolEnd(kid: kid, day: day) {
                    Text("Schulschluss \(end) Uhr")
                }
            }

            // Freizeit am Nachmittag
            let free = store.activities(kid: kid, day: day)
            if !free.isEmpty || store.canEditFreizeit {
                Section {
                    if free.isEmpty {
                        Text("Nichts eingetragen").foregroundStyle(.secondary)
                    }
                    ForEach(free) { a in ActivityRow(activity: a) }
                    if store.canEditFreizeit {
                        NavigationLink { FreizeitManageView() } label: {
                            Label("Freizeit bearbeiten", systemImage: "pencil")
                        }
                    }
                } header: {
                    Text("Nachmittag · Freizeit")
                }
            }
        }
        .navigationTitle("Stundenplan")
        .toolbar {
            NavigationLink { SchoolDocsView(kid: store.activeKid) } label: {
                Label("Schulmappe", systemImage: "folder.fill")
            }
        }
        .onAppear { if let own = store.activeKid { kid = own } }
    }

    private func isCurrent(_ l: Lesson) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return now >= Timetables.minutes(l.start) && now < Timetables.minutes(l.end)
    }
}

struct LessonRow: View {
    let lesson: Lesson
    let isNow: Bool

    var body: some View {
        if lesson.isBreak {
            HStack {
                Text(lesson.start).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 48, alignment: .leading)
                Image(systemName: "cup.and.saucer.fill").font(.caption).foregroundStyle(.tertiary)
                Text("Pause · \(Timetables.minutes(lesson.end) - Timetables.minutes(lesson.start)) Min.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isNow { Text("jetzt").font(.caption.bold()).foregroundStyle(.orange) }
            }
            .listRowBackground(Color(.systemGroupedBackground))
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lesson.start).font(.subheadline.monospacedDigit().weight(.semibold))
                    Text(lesson.end).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(width: 48, alignment: .leading)
                RoundedRectangle(cornerRadius: 3).fill(Timetables.color(lesson.subject)).frame(width: 6)
                Text(lesson.subject).font(.body.weight(.medium))
                Spacer()
                if isNow {
                    Text("Jetzt").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange, in: Capsule())
                }
            }
            .padding(.vertical, 2)
            .listRowBackground(isNow ? Color.orange.opacity(0.12) : nil)
        }
    }
}
