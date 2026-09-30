import SwiftUI

// MARK: - Heute: „Aktuell“ (was ansteht) und „Heute“ (Zeitleiste)

struct TodaySectionHeader: View {
    let title: String
    var action: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let action, let onTap {
                Button(action, action: onTap).font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}

// MARK: Was ansteht

struct UpcomingItem: Identifiable {
    enum Kind { case waste, exam(Exam), todo(ParentTodo) }
    let id: String
    let kind: Kind
    let date: Date
    let tag: String
    let tagColor: Color
    let symbol: String
    let title: String
    let subtitle: String
}

@MainActor
extension AppStore {
    /// Müll (heute/morgen), Klassenarbeiten (nächste 7 Tage), eigene Eltern-Aufgaben (fällig bis morgen)
    func upcomingItems(includeWaste: Bool) -> [UpcomingItem] {
        var out: [UpcomingItem] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        if includeWaste {
            for w in FamilyConfig.waste {
                guard let s = states[w.id], let days = s.attr("tage_bis")?.int, (0...1).contains(days) else { continue }
                let evening = days == 1 && cal.component(.hour, from: Date()) >= 12
                out.append(UpcomingItem(
                    id: "muell-" + w.id, kind: .waste,
                    date: cal.date(byAdding: .day, value: days, to: today) ?? today,
                    tag: days == 0 ? "HEUTE" : (evening ? "HEUTE ABEND" : "MORGEN"),
                    tagColor: days == 0 ? .red : .orange,
                    symbol: w.symbol,
                    title: days == 0 ? "\(w.name) wird heute abgeholt" : "\(w.name) rausstellen",
                    subtitle: days == 0 ? "Abholung heute" : "Abholung morgen früh"))
            }
        }

        let kidFilter = activeKid
        for e in ExamsModel.shared.items where e.upcoming && e.daysLeft <= 7 {
            if let k = kidFilter, e.kid != k { continue }
            let kidName = FamilyConfig.kid(e.kid)?.name ?? ""
            let who = kidFilter == nil && !kidName.isEmpty ? " · \(kidName)" : ""
            out.append(UpcomingItem(
                id: "arbeit-" + e.id, kind: .exam(e), date: e.date,
                tag: ExamConfig.countdown(e.daysLeft).uppercased(),
                tagColor: e.daysLeft <= 1 ? .red : (e.daysLeft <= 3 ? .orange : .indigo),
                symbol: "pencil.and.list.clipboard",
                title: e.title + who,
                subtitle: e.topic.isEmpty ? (e.prepared ? "schon gelernt" : "Klassenarbeit") : e.topic))
        }

        if canUseParentTodos {
            let tomorrowEnd = cal.date(byAdding: .day, value: 2, to: today) ?? today
            for t in myOpenTodos {
                guard let due = t.due, due < tomorrowEnd else { continue }
                let tag = t.isOverdue ? "ÜBERFÄLLIG" : (t.isToday ? "HEUTE" : "MORGEN")
                out.append(UpcomingItem(
                    id: "todo-" + t.uid, kind: .todo(t), date: due,
                    tag: tag, tagColor: t.isOverdue ? .red : .orange,
                    symbol: "checklist",
                    title: t.title,
                    subtitle: t.note.isEmpty ? "Eure Aufgaben" : t.note))
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}

struct UpcomingCard: View {
    @Environment(AppStore.self) private var store
    let items: [UpcomingItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { i, item in
                VStack(spacing: 0) {
                    if i > 0 { Divider().padding(.leading, 50) }
                    row(item)
                }
                .dismissable(store.dismissKeyUpcoming(item))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder private func row(_ item: UpcomingItem) -> some View {
        switch item.kind {
        case .exam(let e):
            if let kid = FamilyConfig.kid(e.kid) {
                NavigationLink { ExamsView(kid: kid) } label: { content(item) { examButton(e) } }
                    .buttonStyle(.plain)
            } else {
                content(item) { examButton(e) }
            }
        case .todo(let t):
            NavigationLink { ParentTodosView() } label: { content(item) { todoButton(t) } }
                .buttonStyle(.plain)
        case .waste:
            content(item) { EmptyView() }
        }
    }

    private func content<Trailing: View>(_ item: UpcomingItem, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.tagColor)
                .frame(width: 38, height: 38)
                .background(item.tagColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.tag)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(item.tagColor)
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func examButton(_ e: Exam) -> some View {
        Button {
            var x = e
            x.prepared.toggle()
            Task { await ExamsModel.shared.save(x, store: store) }
        } label: {
            if e.prepared {
                Label("Gelernt", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(minWidth: 44, minHeight: 36)
            } else {
                Text("Gelernt")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.13), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: e.prepared)
        .accessibilityLabel(e.prepared ? "Gelernt, zurücknehmen" : "Als gelernt markieren")
    }

    private func todoButton(_ t: ParentTodo) -> some View {
        Button {
            Task { await store.setParentTodo(t, done: true) }
        } label: {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 36)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Erledigt")
    }
}

// MARK: Zeitleiste für heute

struct TodayTimeline: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let now = Date()
        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let today = store.events.filter { $0.end > now && $0.start < endOfDay }
        let list: [HAEvent] = today.isEmpty ? Array(store.events.filter { $0.start >= endOfDay }.prefix(3)) : Array(today.prefix(6))

        VStack(alignment: .leading, spacing: 0) {
            if today.isEmpty {
                Text(list.isEmpty ? "Keine Termine" : "Heute nichts mehr – als Nächstes:")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                if i > 0 || today.isEmpty { Divider().padding(.leading, 60) }
                row(e, showDay: today.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func row(_ e: HAEvent, showDay: Bool) -> some View {
        let running = !e.allDay && e.start <= Date() && e.end > Date()
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                if showDay {
                    Text(DayText.label(e.start)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Text(e.allDay ? "ganztags" : e.start.formatted(date: .omitted, time: .shortened))
                    .font(e.allDay ? .caption.weight(.semibold) : .subheadline.weight(.bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 48, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(store.color(for: e.calendarID))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.summary).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle(e, running: running)).font(.caption).foregroundStyle(running ? Color.accentColor : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            CalendarOwnerBadge(calendarID: e.calendarID, size: 22)
        }
        .padding(.vertical, 10)
    }

    private func subtitle(_ e: HAEvent, running: Bool) -> String {
        if running { return "läuft gerade · bis \(e.end.formatted(date: .omitted, time: .shortened))" }
        var parts: [String] = []
        if !e.allDay { parts.append("bis \(e.end.formatted(date: .omitted, time: .shortened))") }
        if let loc = e.location, !loc.isEmpty { parts.append(loc) }
        else if let cal = store.calendars.first(where: { $0.entity_id == e.calendarID }) { parts.append(cal.name) }
        return parts.joined(separator: " · ")
    }
}
