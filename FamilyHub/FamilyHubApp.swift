import SwiftUI

@main
struct FamilyHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .overlay { LockOverlay() }
                .tint(.indigo)
                .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        }
        .onChange(of: scenePhase) { _, phase in
            AppLock.shared.sceneChanged(phase)
            if phase == .active, store.isLoggedIn {
                store.startPolling()
                Task {
                    await store.refreshAll()
                    await store.reportDevice()
                    await PushState.shared.refresh()
                    await LocalReminders.reschedule(store)
                }
            } else if phase == .background {
                store.stopPolling()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("startAnimation") private var startAnimation = true
    @AppStorage("lastUserName") private var lastUserName = ""
    @State private var splashDone = false

    var body: some View {
        Group {
            if store.isLoggedIn {
                MainTabs()
                .task {
                    store.startPolling()
                    await store.refreshAll()
                    await PushState.shared.setup()
                    await store.reportDevice()
                    await LocalReminders.reschedule(store)
                }
                .onChange(of: hiddenTabs) { _, hidden in
                    if hidden.contains(store.selectedTab) { store.selectedTab = "heute" }
                }
            } else {
                LoginView()
            }
        }
        .overlay {
            if store.isLoggedIn && startAnimation && !splashDone {
                SplashView(pictures: store.pictures, name: lastUserName.isEmpty ? nil : lastUserName) {
                    splashDone = true
                }
                .transition(.opacity)
            }
        }
        .onChange(of: myName) { _, n in if let n { lastUserName = n } }
        .onOpenURL { url in
            splashDone = true
            store.openLink(url)
        }
        .animation(.default, value: store.isLoggedIn)
    }

    /// Tabs, die für das aktuelle Kind ausgeblendet sind
    private var hiddenTabs: [String] {
        [store.allows(.kalender) ? nil : "kalender", store.allows(.listen) ? nil : "listen"].compactMap { $0 }
    }

    /// Name des angemeldeten Familienmitglieds (für die Begrüßung beim nächsten Start)
    private var myName: String? {
        if let p = store.myParentID { return FamilyConfig.parent(p)?.name }
        if let k = store.detectedKid { return FamilyConfig.kid(k)?.name }
        return nil
    }
}

/// Die fünf Tabs mit schwebender Glas-Leiste. Tabs bleiben erhalten (Navigation, Scrollposition),
/// werden aber erst beim ersten Öffnen gebaut.
struct MainTabs: View {
    @Environment(AppStore.self) private var store
    @State private var visited: Set<String> = ["heute"]
    @State private var keyboard = KeyboardWatch.shared
    @State private var push = PushState.shared

    var body: some View {
        let tabs = specs
        ZStack {
            ForEach(tabs) { t in
                if visited.contains(t.id) || t.id == store.selectedTab {
                    let on = t.id == store.selectedTab
                    content(t.id)
                        .opacity(on ? 1 : 0)
                        .allowsHitTesting(on)
                        .accessibilityHidden(!on)
                        .zIndex(on ? 1 : 0)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboard.visible {
                GlassTabBar(tabs: tabs, selection: Bindable(store).selectedTab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: keyboard.visible)
        .onChange(of: store.selectedTab, initial: true) { _, t in visited.insert(t) }
        // neues Push-Token → sofort an Family Hub melden
        .onChange(of: push.token) { _, _ in Task { await store.reportDevice(force: true) } }
        // Mitteilung angetippt → passende Seite öffnen
        .onChange(of: push.pendingLink, initial: true) { _, link in
            guard let link else { return }
            push.pendingLink = nil
            if let url = URL(string: "familie://" + link) { store.openLink(url) }
        }
    }

    private var specs: [TabSpec] {
        var out = [TabSpec(id: "heute", title: "Heute", symbol: "sun.max.fill")]
        if store.allows(.kalender) { out.append(TabSpec(id: "kalender", title: "Kalender", symbol: "calendar")) }
        out.append(TabSpec(id: "aufgaben", title: "Aufgaben", symbol: "checkmark.circle.fill", badge: store.choreBadge))
        if store.allows(.listen) {
            let open = (store.todoItems[FamilyConfig.shoppingList] ?? []).filter { !$0.done }.count
            out.append(TabSpec(id: "listen", title: "Listen", symbol: "cart.fill", badge: open))
        }
        out.append(TabSpec(id: "zuhause", title: "Zuhause", symbol: "house.fill"))
        return out
    }

    @ViewBuilder private func content(_ id: String) -> some View {
        switch id {
        case "kalender": CalendarView()
        case "aufgaben": ChoresView()
        case "listen": ListsView()
        case "zuhause": ControlsView()
        default: TodayView()
        }
    }
}

/// Kleine Fehlerleiste, die oben eingeblendet wird.
struct ErrorBanner: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let err = store.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).font(.footnote).lineLimit(3)
                Spacer()
                Button { store.lastError = nil } label: { Image(systemName: "xmark").font(.footnote) }
                    .buttonStyle(.plain)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Sperre bzw. Sichtschutz über der ganzen App
struct LockOverlay: View {
    @State private var lock = AppLock.shared

    var body: some View {
        Group {
            if lock.locked {
                LockScreen()
            } else if lock.covered {
                PrivacyCover()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.locked)
        .task { if lock.locked { await lock.unlock() } }
    }
}
