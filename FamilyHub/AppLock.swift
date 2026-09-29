import SwiftUI
import LocalAuthentication

// MARK: - App-Sperre mit Face ID / Touch ID (Ausweichweg: Code des iPhones)
//
// Einstellung gilt pro iPhone. Die App sperrt sich nach der gewählten Zeit im Hintergrund.
// In der App-Übersicht (App-Wechsler) wird der Inhalt verdeckt.

@MainActor @Observable
final class AppLock {
    static let shared = AppLock()

    var locked: Bool
    var covered = false          // Inhalt verdecken (App-Wechsler)
    var authenticating = false
    var message: String?
    private var backgroundSince: Date?

    static let enabledKey = "appLockEnabled"
    static let timeoutKey = "appLockTimeout"

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// Sekunden im Hintergrund, bevor wieder entsperrt werden muss (0 = sofort)
    var timeout: Int { UserDefaults.standard.integer(forKey: Self.timeoutKey) }

    init() {
        UserDefaults.standard.register(defaults: [Self.timeoutKey: 60])
        locked = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Welche Methode das iPhone anbietet – für die Beschriftung
    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Code"
        }
    }

    static var symbol: String {
        switch biometryName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock.fill"
        }
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard enabled else { covered = false; locked = false; return }
        switch phase {
        case .background:
            if backgroundSince == nil { backgroundSince = Date() }
            covered = true
        case .inactive:
            covered = true
        case .active:
            if let since = backgroundSince, Date().timeIntervalSince(since) >= Double(timeout) {
                locked = true
            }
            backgroundSince = nil
            covered = false
            if locked { Task { await unlock() } }
        @unknown default:
            break
        }
    }

    /// Face ID / Touch ID, bei Fehlschlag Code des iPhones
    @discardableResult
    func unlock(reason: String = "Familie entsperren") async -> Bool {
        guard !authenticating else { return false }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Abbrechen"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // Kein Code auf dem iPhone eingerichtet – Sperre kann nicht greifen
            message = "Auf diesem iPhone ist kein Code eingerichtet."
            locked = false
            return true
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { locked = false; message = nil }
            return ok
        } catch {
            message = nil
            return false
        }
    }

    /// Beim Einschalten einmal bestätigen lassen
    func setEnabled(_ on: Bool) async -> Bool {
        if on {
            let ok = await unlock(reason: "App-Sperre einschalten")
            guard ok else { return false }
        }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        locked = false
        return true
    }
}

/// Sperrbildschirm über der ganzen App
struct LockScreen: View {
    @State private var lock = AppLock.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "house.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 22))
                Text("Familie ist gesperrt").font(.title3.weight(.semibold))
                if let m = lock.message {
                    Text(m).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Entsperren", systemImage: AppLock.symbol)
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(lock.authenticating)
            }
        }
        .transition(.opacity)
    }
}

/// Nur verdecken (App-Wechsler), ohne Knopf
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Image(systemName: "house.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

/// Einstellungen → Sicherheit
struct AppLockSection: View {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @AppStorage(AppLock.timeoutKey) private var timeout = 60
    @State private var busy = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { v in
                guard !busy else { return }
                busy = true
                Task {
                    _ = await AppLock.shared.setEnabled(v)
                    enabled = AppLock.shared.enabled
                    busy = false
                }
            })) {
                Label("Mit \(AppLock.biometryName) sperren", systemImage: AppLock.symbol)
            }
            if enabled {
                Picker("Sperren nach", selection: $timeout) {
                    Text("Sofort").tag(0)
                    Text("1 Minute").tag(60)
                    Text("5 Minuten").tag(300)
                    Text("15 Minuten").tag(900)
                    Text("1 Stunde").tag(3600)
                }
            }
        } header: {
            Text("Sicherheit")
        } footer: {
            Text("Gilt nur für dieses iPhone. Klappt \(AppLock.biometryName) nicht, geht es mit dem Code des iPhones. In der App-Übersicht wird der Inhalt verdeckt.")
        }
    }
}
