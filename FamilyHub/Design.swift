import SwiftUI
import UIKit

// MARK: - Design: „Glas + Klar“
//
// Glas (Material) nur für Kopfbereiche und die schwebende Tab-Leiste,
// Inhalte auf ruhigen, klaren Karten. Hell/Dunkel folgt dem iPhone.

enum DS {
    static let cardRadius: CGFloat = 22
    static let glassRadius: CGFloat = 28
    static let tileRadius: CGFloat = 18
}

// MARK: Hintergrund mit sanftem Farbschimmer oben

struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Color(.systemGroupedBackground)
                Circle()
                    .fill(Color(red: 0.42, green: 0.36, blue: 0.91).opacity(dark ? 0.55 : 0.32))
                    .frame(width: w * 1.1, height: w * 1.1)
                    .blur(radius: 80)
                    .offset(x: -w * 0.45, y: -w * 0.55)
                Circle()
                    .fill(Color(red: 0.08, green: 0.64, blue: 0.72).opacity(dark ? 0.40 : 0.26))
                    .frame(width: w * 0.9, height: w * 0.9)
                    .blur(radius: 80)
                    .offset(x: w * 0.55, y: -w * 0.40)
                Circle()
                    .fill(Color(red: 0.84, green: 0.31, blue: 0.55).opacity(dark ? 0.24 : 0.14))
                    .frame(width: w * 0.8, height: w * 0.8)
                    .blur(radius: 90)
                    .offset(x: w * 0.15, y: w * 0.10)
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Flächen

struct GlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = DS.glassRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? 0.14 : 0.75), lineWidth: 1))
            .shadow(color: Color(red: 0.16, green: 0.12, blue: 0.47).opacity(scheme == .dark ? 0 : 0.10), radius: 18, y: 8)
    }
}

struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = DS.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 12, y: 5)
    }
}

extension View {
    func glassSurface(radius: CGFloat = DS.glassRadius) -> some View { modifier(GlassSurface(radius: radius)) }
    func cardSurface(radius: CGFloat = DS.cardRadius) -> some View { modifier(CardSurface(radius: radius)) }
}

// MARK: Fortschrittsring

struct ProgressRing: View {
    var progress: Double?          // nil = unbekannt (nur Spur)
    var color: Color
    var label: String
    var size: CGFloat = 56
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            if let p = progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, p)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(label)
                .font(.system(size: size * 0.23, weight: .bold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(lineWidth + 2)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

// MARK: Schwebende Tab-Leiste

struct TabSpec: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    var badge: Int = 0
}

struct GlassTabBar: View {
    let tabs: [TabSpec]
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { t in
                tabButton(t)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.6), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 18, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }

    private func tabButton(_ t: TabSpec) -> some View {
        let on = t.id == selection
        return Button {
            if !on { UISelectionFeedbackGenerator().selectionChanged() }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { selection = t.id }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: t.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) { badge(t.badge) }
                Text(t.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if on {
                    Capsule()
                        .fill(Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.13))
                        .matchedGeometryEffect(id: "auswahl", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.badge > 0 ? "\(t.title), \(t.badge)" : t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func badge(_ n: Int) -> some View {
        if n > 0 {
            Text(n > 99 ? "99+" : "\(n)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Color.red, in: Capsule())
                .offset(x: 11, y: -5)
        }
    }
}

/// Tastatur sichtbar? (Tab-Leiste dann ausblenden)
@MainActor @Observable
final class KeyboardWatch {
    static let shared = KeyboardWatch()
    var visible = false
    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardWatch.shared.visible = true }
        }
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardWatch.shared.visible = false }
        }
    }
}
