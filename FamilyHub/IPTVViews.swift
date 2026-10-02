import SwiftUI
import Charts

// MARK: - Streaming-Seite (Entwurf 5 + Ruckler-Protokoll)

struct IPTVView: View {
    @Environment(AppStore.self) private var store
    @State private var st: IPTVStatus?
    @State private var error: String?

    var body: some View {
        ScrollView {
            IPTVContent(st: st, error: error, reload: { setup in await load(setup: setup) })
                .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("Streaming")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func load(setup: Bool = false) async {
        do {
            st = try await store.loadIPTV(setup: setup)
            error = nil
        } catch {
            if st == nil { self.error = error.localizedDescription }
        }
    }
}

enum Neon {
    static let pink = Color(red: 1.0, green: 0.30, blue: 0.48)
    static let pinkDeep = Color(red: 0.06, green: 0.02, blue: 0.035)
    static let green = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let panel = Color(red: 0.045, green: 0.06, blue: 0.086)
    static let line = Color(red: 0.11, green: 0.14, blue: 0.2)
}

/// Inhalt der Streaming-Seite – auch im Netzwerk-Cockpit unter „Streaming“ verwendet
struct IPTVContent: View {
    @Environment(AppStore.self) private var store
    let st: IPTVStatus?
    var error: String?
    let reload: (_ setup: Bool) async -> Void

    @State private var routeBusy: String?
    @State private var setupBusy = false
    @State private var alertBusy = false

    var body: some View {
        VStack(spacing: 14) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
            }
            if let st {
                hero(st)
                statsCard(st)
                controlCard(st)
                rucklerCard(st)
                let older = st.conns.filter { !st.isLive($0) }
                if !older.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vorhin").font(.headline).foregroundStyle(.secondary)
                        ForEach(older.prefix(6)) { c in ConnCard(c: c, st: st, live: false) }
                    }
                }
                if !st.log { logHint(st) }
            } else if error == nil {
                ProgressView("Frage UniFi …").frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }

    // MARK: Läuft gerade

    private func hero(_ s: IPTVStatus) -> some View {
        let live = s.conns.filter { s.isLive($0) }
        let main = live.first
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if s.streaming {
                    Text("LIVE").font(.caption2.weight(.heavy)).tracking(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Neon.pink, in: RoundedRectangle(cornerRadius: 7))
                    if let start = s.sessionStart {
                        Text("seit \(start.formatted(date: .omitted, time: .shortened)) · \(duration(since: start))")
                            .font(.caption).foregroundStyle(Neon.pink.opacity(0.85))
                    }
                } else {
                    Text("GERADE RUHIG").font(.caption2.weight(.heavy)).tracking(1).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 14) {
                Image(systemName: icon(main?.geraet ?? "pc"))
                    .font(.title2).foregroundStyle(Neon.pink)
                    .frame(width: 56, height: 56)
                    .background(Neon.pink.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(main?.geraet ?? (s.streaming ? "Stream läuft" : "Niemand schaut gerade"))
                        .font(.title3.weight(.heavy)).lineLimit(1)
                    Text(main.map { [$0.ip, $0.netz].filter { !$0.isEmpty }.joined(separator: " · ") }
                         ?? (s.streaming ? "Gerät erscheint beim nächsten Kanalwechsel" : "Port \(String(s.port))"))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            // Weg: Zuhause → VPN → Server
            HStack(spacing: 0) {
                pathNode("house", "Zuhause", .secondary)
                Rectangle().fill(main?.viaVPN ?? true ? Neon.green : .orange).frame(height: 2)
                pathNode("lock.shield", shortVPN(s.tunnelName), main?.viaVPN ?? true ? Neon.green : .orange)
                Rectangle().fill(main?.viaVPN ?? true ? Neon.green : .orange).frame(height: 2)
                pathNode("server.rack", main.map { $0.ort.isEmpty ? $0.ziel : $0.ort.components(separatedBy: ",").first ?? $0.ort } ?? "Server", Neon.pink)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Rate.text(s.rx)).font(.system(size: 46, weight: .heavy, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Text(Rate.unit(s.rx)).font(.headline).foregroundStyle(.secondary)
                Spacer()
                let recent = s.ruckler.first.map { Date.now.timeIntervalSince($0.ende) < 600 } ?? false
                Text(recent ? "hakt" : (s.streaming ? "stabil" : ""))
                    .font(.caption.weight(.bold)).foregroundStyle(recent ? Color.orange : Neon.green)
            }

            chart(s)

            if let r = s.ruckler.first, Calendar.current.isDateInToday(r.start) {
                Label("Letzter Ruckler \(r.start.formatted(date: .omitted, time: .shortened)): \(fmt(r.von)) → \(fmt(r.auf)) Mbit/s für \(dauerText(r.dauer))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(Neon.pinkDeep, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Neon.pink.opacity(0.35)))
    }

    @ViewBuilder private func chart(_ s: IPTVStatus) -> some View {
        let pts = s.verlauf
        if pts.count < 2 {
            Text("Verlauf wird aufgezeichnet …").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            let from = pts.first?.t ?? .now
            Chart {
                ForEach(s.ruckler.filter { $0.ende >= from }) { r in
                    RectangleMark(xStart: .value("von", r.start), xEnd: .value("bis", max(r.ende, r.start.addingTimeInterval(10))))
                        .foregroundStyle(Color.orange.opacity(0.18))
                }
                ForEach(pts) { p in
                    AreaMark(x: .value("Zeit", p.t), y: .value("Mbit/s", p.rx / 1_000_000))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Neon.pink.opacity(0.4), Neon.pink.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Zeit", p.t), y: .value("Mbit/s", p.rx / 1_000_000))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Neon.pink)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(d, specifier: "%.0f")") } }
                }
            }
            .frame(height: 100)
        }
    }

    private func pathNode(_ symbol: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 84)
    }

    // MARK: Verbindung

    private func statsCard(_ s: IPTVStatus) -> some View {
        let live = s.conns.filter { s.isLive($0) }
        let heute = s.ruckler.filter { Calendar.current.isDateInToday($0.start) }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Verbindung").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                stat("Server", live.first?.ziel ?? "–", small: true)
                stat("Verbindungen", "\(live.reduce(0) { $0 + $1.anzahl })")
                stat("Ruckler heute", "\(heute)", color: heute > 0 ? .orange : Neon.green)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Neon.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Neon.line))
    }

    private func stat(_ title: String, _ value: String, small: Bool = false, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(small ? .footnote.weight(.bold) : .title3.weight(.heavy)).foregroundStyle(color)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Schalter

    private func controlCard(_ s: IPTVStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(s.routen) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Über VPN streamen").font(.subheadline.weight(.bold))
                        Text("Port \(String(s.port)) · \(shortVPN(r.name))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if routeBusy == r.id { ProgressView() }
                    Toggle("Über VPN streamen", isOn: Binding(get: { r.an }, set: { want in
                        routeBusy = r.id
                        Task {
                            _ = await store.setVPNRoute(r.id, on: want)
                            await reload(false)
                            routeBusy = nil
                        }
                    }))
                    .labelsHidden().tint(Neon.green).disabled(routeBusy != nil)
                }
                Divider()
            }
            HStack {
                Image(systemName: "bell.badge").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Melden, wenn der Stream hakt").font(.subheadline.weight(.bold))
                    Text("Push, wenn der Tunnel beim Schauen einbricht").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if alertBusy { ProgressView() }
                Toggle("Melden, wenn der Stream hakt", isOn: Binding(get: { s.melden }, set: { want in
                    alertBusy = true
                    Task {
                        await store.setIPTVAlert(want)
                        await reload(false)
                        alertBusy = false
                    }
                }))
                .labelsHidden().tint(.orange).disabled(alertBusy)
            }
        }
        .padding(16)
        .background(Neon.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Neon.line))
    }

    // MARK: Ruckler-Protokoll

    private func rucklerCard(_ s: IPTVStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ruckler-Protokoll").font(.headline)
                Spacer()
                Text("\(s.ruckler.count)").font(.subheadline.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
            if s.ruckler.isEmpty {
                Text("Noch keine Ruckler erkannt. Family Hub schaut alle 10 Sekunden auf den Tunnel – auch wenn die App zu ist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(s.ruckler.prefix(12)) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(dayTime(r.start)).font(.footnote.weight(.bold)).foregroundStyle(.orange)
                        .frame(width: 74, alignment: .leading).monospacedDigit()
                    Text("\(fmt(r.von)) → \(fmt(r.auf)) Mbit/s").font(.footnote).monospacedDigit()
                    Spacer()
                    Text(dauerText(r.dauer)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !s.sessions.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Seh-Sitzungen").font(.subheadline.weight(.bold))
                ForEach(s.sessions.prefix(6)) { x in
                    HStack(spacing: 10) {
                        Text(dayTime(x.start)).font(.footnote).monospacedDigit().frame(width: 74, alignment: .leading)
                        Text(dauerText(Int(x.ende.timeIntervalSince(x.start)))).font(.footnote)
                        Text("Ø \(fmt(x.mbit)) Mbit/s").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(x.ruckler == 0 ? "ruhig" : "\(x.ruckler)× gehakt")
                            .font(.caption.weight(.semibold)).foregroundStyle(x.ruckler == 0 ? Neon.green : .orange)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Neon.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Neon.line))
    }

    private func logHint(_ s: IPTVStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Geräte-Erkennung einrichten", systemImage: "info.circle.fill").font(.headline)
            Text("Damit sichtbar wird, welches Gerät über Port \(String(s.port)) streamt, legt die App in UniFi eine Erlauben-und-Protokollieren-Regel an. Am Verkehr ändert sie nichts.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                setupBusy = true
                Task { await reload(true); setupBusy = false }
            } label: {
                HStack { if setupBusy { ProgressView() }; Text("Protokoll-Regel anlegen") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(setupBusy)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    // MARK: Hilfen

    private func icon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("tv") || n.contains("fire") || n.contains("shield") { return "tv" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        return "desktopcomputer"
    }
    private func shortVPN(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("fra") { return "VPN Frankfurt" }
        if n.contains("ams") { return "VPN Amsterdam" }
        return name.count > 14 ? "VPN" : name
    }
    private func fmt(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func dauerText(_ s: Int) -> String {
        if s < 90 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
    private func duration(since d: Date) -> String { dauerText(Int(Date.now.timeIntervalSince(d))) }
    private func dayTime(_ d: Date) -> String {
        let t = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return t }
        if Calendar.current.isDateInYesterday(d) { return "gest. " + t }
        return d.formatted(.dateTime.day().month(.twoDigits)) + " " + t
    }
}
