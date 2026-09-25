import SwiftUI

@main
struct FamilyHubApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.indigo)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.isLoggedIn {
                store.startPolling()
                Task { await store.refreshAll() }
            } else if phase == .background {
                store.stopPolling()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.isLoggedIn {
                TabView {
                    TodayView()
                        .tabItem { Label("Heute", systemImage: "house.fill") }
                    CalendarView()
                        .tabItem { Label("Kalender", systemImage: "calendar") }
                    ListsView()
                        .tabItem { Label("Listen", systemImage: "checklist") }
                    ControlsView()
                        .tabItem { Label("Steuern", systemImage: "switch.2") }
                }
                .task { store.startPolling(); await store.refreshAll() }
            } else {
                LoginView()
            }
        }
        .animation(.default, value: store.isLoggedIn)
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
