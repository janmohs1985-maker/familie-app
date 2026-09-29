import SwiftUI

@main
struct FamilyHubApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.indigo)
                .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.isLoggedIn {
                store.startPolling()
                Task { await store.refreshAll(); await store.reportDevice() }
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
                TabView(selection: Bindable(store).selectedTab) {
                    TodayView()
                        .tabItem { Label("Heute", systemImage: "sun.max.fill") }
                        .tag("heute")
                    if store.allows(.kalender) {
                        CalendarView()
                            .tabItem { Label("Kalender", systemImage: "calendar") }
                            .tag("kalender")
                    }
                    ChoresView()
                        .tabItem { Label("Aufgaben", systemImage: "checkmark.circle.fill") }
                        .badge(store.choreBadge)
                        .tag("aufgaben")
                    if store.allows(.listen) {
                        ListsView()
                            .tabItem { Label("Listen", systemImage: "cart.fill") }
                            .badge((store.todoItems[FamilyConfig.shoppingList] ?? []).filter { !$0.done }.count)
                            .tag("listen")
                    }
                    ControlsView()
                        .tabItem { Label("Zuhause", systemImage: "house.fill") }
                        .tag("zuhause")
                }
                .task { store.startPolling(); await store.refreshAll(); await store.reportDevice() }
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
