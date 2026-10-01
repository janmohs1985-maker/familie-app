import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FamilieLiveBundle: WidgetBundle {
    var body: some Widget {
        GeraetLiveActivity()
    }
}

struct GeraetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GeraetAttributes.self) { context in
            Group {
                if context.state.isCar {
                    CarLockScreen(state: context.state)
                } else {
                    LockScreenView(state: context.state, geraet: context.attributes.geraet)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let farbe = geraetFarbe(s)
            let stopp = context.attributes.geraet == "bewaesserung" && !s.fertig
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        SymbolBadge(state: s, size: 36)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.titel).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(s.fertig ? "fertig" : (s.isCar ? "lädt" : "läuft"))
                                .font(.caption2).foregroundStyle(s.fertig ? .green : .secondary)
                        }
                    }
                    .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        if s.isCar, let soc = s.soc {
                            Text("\(Int(soc)) %").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(farbe)
                            if !s.fertig { EndText(state: s).font(.caption2).foregroundStyle(.secondary) }
                        } else {
                            TimeText(state: s).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(s.fertig ? .green : farbe)
                            if !s.fertig, s.ende > Date().timeIntervalSince1970 {
                                EndText(state: s).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if s.isCar {
                            CarBattery(state: s, height: 12)
                            CarDetails(state: s)
                        } else {
                            if !s.info.isEmpty { Text(s.info).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Progress(state: s, height: 8)
                            if stopp { StopButton() }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: s.fertig ? "checkmark.circle.fill" : s.symbol)
                    .foregroundStyle(s.fertig ? .green : farbe)
            } compactTrailing: {
                if s.isCar, let soc = s.soc, !s.fertig {
                    Text("\(Int(soc))%").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(farbe)
                } else {
                    TimeText(state: s, short: true).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(s.fertig ? .green : farbe)
                        .frame(maxWidth: 52)
                }
            } minimal: {
                if s.isCar, let soc = s.soc, !s.fertig {
                    ProgressView(value: min(1, soc / 100)) { Image(systemName: "bolt.fill").font(.system(size: 8)) }
                        .progressViewStyle(.circular).tint(farbe)
                } else {
                    Image(systemName: s.fertig ? "checkmark" : s.symbol).foregroundStyle(s.fertig ? .green : farbe)
                }
            }
            .keylineTint(farbe)
        }
    }
}

// MARK: Farben & Bausteine

extension GeraetAttributes.ContentState {
    var isCar: Bool { soc != nil || symbol.contains("car") }
}

private func geraetFarbe(_ s: GeraetAttributes.ContentState) -> Color {
    let y = s.symbol
    if y.contains("car") || y.contains("bolt") { return .green }
    if y.contains("dishwasher") { return .teal }
    if y.contains("dryer") || y.contains("oven") { return .orange }
    if y.contains("cloud") { return .cyan }
    if y.contains("sprinkler") || y.contains("drop") || y.contains("tree") || y.contains("spigot") { return .mint }
    if y.contains("fan") { return .indigo }
    return .blue
}

private struct SymbolBadge: View {
    let state: GeraetAttributes.ContentState
    var size: CGFloat = 48
    var body: some View {
        let farbe = state.fertig ? Color.green : geraetFarbe(state)
        Image(systemName: state.fertig ? "checkmark" : state.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [farbe, farbe.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopIrrigationIntent()) {
            Label("Stopp", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .tint(.red)
    }
}

/// Restzeit (Countdown), sonst „läuft seit“, fertig → „Fertig“
private struct TimeText: View {
    let state: GeraetAttributes.ContentState
    var short = false

    var body: some View {
        if state.fertig {
            Text(short ? "fertig" : "Fertig")
        } else if state.ende > Date().timeIntervalSince1970 {
            Text(timerInterval: Date()...Date(timeIntervalSince1970: state.ende), countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Date(timeIntervalSince1970: state.start), style: .timer)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// „fertig 18:40“
private struct EndText: View {
    let state: GeraetAttributes.ContentState
    var body: some View {
        if state.ende > Date().timeIntervalSince1970 {
            Text("fertig \(Date(timeIntervalSince1970: state.ende).formatted(date: .omitted, time: .shortened))")
        } else if state.isCar, let kw = state.kw {
            Text(kwText(kw))
        }
    }
}

private func kwText(_ kw: Double) -> String {
    (kw >= 10 ? String(format: "%.0f kW", kw) : String(format: "%.1f kW", kw)).replacingOccurrences(of: ".", with: ",")
}

private struct Progress: View {
    let state: GeraetAttributes.ContentState
    var height: CGFloat = 8

    var body: some View {
        if state.fertig {
            Label(state.info.isEmpty ? "Fertig" : state.info, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        } else if state.ende > state.start, state.ende > Date().timeIntervalSince1970 {
            ProgressView(timerInterval: Date(timeIntervalSince1970: state.start)...Date(timeIntervalSince1970: state.ende),
                         countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(geraetFarbe(state))
                .scaleEffect(x: 1, y: height / 4, anchor: .center)
                .frame(height: height)
        } else {
            Text("läuft …").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Geräte (Wäsche, Spülmaschine, Ofen, Sauger, Bewässerung)

private struct LockScreenView: View {
    let state: GeraetAttributes.ContentState
    var geraet: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SymbolBadge(state: state)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.titel).font(.headline).foregroundStyle(.white)
                        if !state.fertig, !state.info.isEmpty {
                            Text(state.info).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        TimeText(state: state).font(.title2.monospacedDigit().weight(.bold))
                            .foregroundStyle(state.fertig ? .green : .white)
                        if !state.fertig { EndText(state: state).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                    }
                }
                Progress(state: state)
                if geraet == "bewaesserung" && !state.fertig { StopButton() }
            }
        }
    }
}

// MARK: Auto laden

/// Akku-Balken: aktueller Ladestand, Ziel als Strich
private struct CarBattery: View {
    let state: GeraetAttributes.ContentState
    var height: CGFloat = 16

    var body: some View {
        let soc = min(100, max(0, state.soc ?? 0))
        let ziel = min(100, max(0, state.ziel ?? 100))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [.green.opacity(0.7), .green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * soc / 100))
                if ziel < 100 && !state.fertig {
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: 2, height: height + 6)
                        .offset(x: g.size.width * ziel / 100 - 1)
                }
            }
        }
        .frame(height: height)
    }
}

/// ☀️ PV · 🔋 Hausakku · 🔌 Netz – woher der Strom gerade kommt
private struct SourceBar: View {
    let pv: Double, akku: Double, netz: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    if pv > 0.01 { Capsule().fill(.yellow).frame(width: max(4, (g.size.width - 4) * pv)) }
                    if akku > 0.01 { Capsule().fill(.purple).frame(width: max(4, (g.size.width - 4) * akku)) }
                    if netz > 0.01 { Capsule().fill(.blue).frame(width: max(4, (g.size.width - 4) * netz)) }
                }
            }
            .frame(height: 5)
            HStack(spacing: 10) {
                if pv > 0.01 { legend("sun.max.fill", .yellow, pv) }
                if akku > 0.01 { legend("battery.75percent", .purple, akku) }
                if netz > 0.01 { legend("powerplug.fill", .blue, netz) }
            }
            .font(.caption2.weight(.medium).monospacedDigit())
        }
    }

    private func legend(_ symbol: String, _ color: Color, _ v: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(Int((v * 100).rounded())) %").foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct CarDetails: View {
    let state: GeraetAttributes.ContentState

    var body: some View {
        if state.fertig {
            Label(state.info.isEmpty ? "Fertig geladen" : state.info, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if let kw = state.kw, kw > 0 {
                        Label(kwText(kw), systemImage: "bolt.fill").foregroundStyle(.green)
                    }
                    if let z = state.ziel { Label("Ziel \(Int(z)) %", systemImage: "flag.checkered").foregroundStyle(.white.opacity(0.8)) }
                    Spacer(minLength: 0)
                    if state.ende > Date().timeIntervalSince1970 {
                        Text(timerInterval: Date()...Date(timeIntervalSince1970: state.ende), countsDown: true)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: 70, alignment: .trailing)
                    }
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                if let pv = state.pv, let akku = state.akku, let netz = state.netz {
                    SourceBar(pv: pv, akku: akku, netz: netz)
                }
            }
        }
    }
}

private struct CarLockScreen: View {
    let state: GeraetAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                SymbolBadge(state: state, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.titel).font(.headline).foregroundStyle(.white)
                    Group {
                        if state.fertig {
                            Text("fertig geladen")
                        } else if state.ende > Date().timeIntervalSince1970 {
                            Text("lädt · fertig \(Date(timeIntervalSince1970: state.ende).formatted(date: .omitted, time: .shortened))")
                        } else {
                            Text("lädt")
                        }
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if let soc = state.soc {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(soc))").font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        Text("%").font(.headline)
                    }
                    .foregroundStyle(state.fertig ? .green : .white)
                }
            }
            CarBattery(state: state)
            CarDetails(state: state)
        }
    }
}
