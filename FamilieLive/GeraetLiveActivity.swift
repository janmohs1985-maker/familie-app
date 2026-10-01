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
            LockScreenView(state: context.state, geraet: context.attributes.geraet)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let s = context.state
            let stopp = context.attributes.geraet == "bewaesserung" && !s.fertig
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.fertig ? "checkmark.circle.fill" : s.symbol)
                        .font(.title2)
                        .foregroundStyle(s.fertig ? .green : geraetFarbe(s))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeText(state: s).font(.title3.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.titel).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !s.info.isEmpty { Text(s.info).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Progress(state: s)
                        if stopp { StopButton() }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: s.fertig ? "checkmark.circle.fill" : s.symbol)
                    .foregroundStyle(s.fertig ? .green : geraetFarbe(s))
            } compactTrailing: {
                TimeText(state: s, short: true).font(.caption.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: s.fertig ? "checkmark" : s.symbol)
                    .foregroundStyle(s.fertig ? .green : geraetFarbe(s))
            }
        }
    }
}

private func geraetFarbe(_ s: GeraetAttributes.ContentState) -> Color {
    let y = s.symbol
    if y.contains("dishwasher") { return .teal }
    if y.contains("dryer") || y.contains("oven") { return .orange }
    if y.contains("cloud") { return .cyan }
    if y.contains("bolt") { return .green }
    if y.contains("sprinkler") || y.contains("drop") || y.contains("tree") || y.contains("spigot") { return .green }
    return .blue
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

private struct LockScreenView: View {
    let state: GeraetAttributes.ContentState
    var geraet: String = ""

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.fertig ? "checkmark.circle.fill" : state.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(state.fertig ? .green : geraetFarbe(state))
                .frame(width: 48, height: 48)
                .background((state.fertig ? Color.green : geraetFarbe(state)).opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.titel).font(.headline)
                    Spacer()
                    TimeText(state: state).font(.title3.monospacedDigit().weight(.bold))
                }
                if !state.info.isEmpty {
                    Text(state.info).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Progress(state: state)
                if geraet == "bewaesserung" && !state.fertig { StopButton() }
            }
        }
    }
}

/// Restzeit (Countdown), sonst „läuft seit“, fertig → „Fertig“
private struct TimeText: View {
    let state: GeraetAttributes.ContentState
    var short = false

    var body: some View {
        if state.fertig {
            Text(short ? "fertig" : "Fertig").foregroundStyle(.green)
        } else if state.ende > Date().timeIntervalSince1970 {
            Text(timerInterval: Date()...Date(timeIntervalSince1970: state.ende), countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Date(timeIntervalSince1970: state.start), style: .timer)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct Progress: View {
    let state: GeraetAttributes.ContentState

    var body: some View {
        if state.fertig {
            Text("Fertig – ausräumen").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        } else if state.ende > state.start, state.ende > Date().timeIntervalSince1970 {
            ProgressView(timerInterval: Date(timeIntervalSince1970: state.start)...Date(timeIntervalSince1970: state.ende),
                         countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(geraetFarbe(state))
        } else {
            Text("läuft …").font(.caption).foregroundStyle(.secondary)
        }
    }
}
