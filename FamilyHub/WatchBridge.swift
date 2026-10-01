import Foundation
import WatchConnectivity

// MARK: - Apple Watch: Zugang an die Uhr übergeben
//
// Die Watch-App spricht selbst mit Home Assistant. Dafür bekommt sie vom iPhone Server, Anmelde-Token,
// Push-Schlüssel (für „Alle rufen“) und ob dieses iPhone einem Elternteil gehört.

final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    func start() {
        guard WCSession.isSupported() else { return }
        if WCSession.default.delegate == nil { WCSession.default.delegate = self }
        if WCSession.default.activationState == .activated { push() } else { WCSession.default.activate() }
    }

    private func context() -> [String: Any] {
        guard let c = Keychain.load() else { return [:] }
        var ctx: [String: Any] = ["server": c.server, "parent": UserDefaults.standard.bool(forKey: SiriHA.parentKey)]
        if let t = c.refreshToken { ctx["refreshToken"] = t }
        if let t = c.longLivedToken { ctx["longLivedToken"] = t }
        if let t = UserDefaults.standard.string(forKey: "pushToken") { ctx["pushToken"] = t }
        return ctx
    }

    func push() {
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        let ctx = context()
        guard !ctx.isEmpty else { return }
        try? s.updateApplicationContext(ctx)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated { push() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { push() }

    /// Uhr fragt aktiv nach dem Zugang (z. B. direkt nach der Installation)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(context())
    }
}
