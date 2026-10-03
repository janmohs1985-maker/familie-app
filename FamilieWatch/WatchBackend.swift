import Foundation
import Security
import WatchConnectivity

// MARK: - Zugang zu Home Assistant auf der Uhr
//
// Das iPhone schickt Server, Anmelde-Token, Push-Schlüssel und Rolle per WatchConnectivity.
// Die Uhr spricht danach selbst mit Home Assistant (über WLAN oder das iPhone).

struct WatchCredentials: Codable, Equatable {
    var server: String
    var refreshToken: String?
    var longLivedToken: String?
    var pushToken: String?
    var parent: Bool

    var baseURL: URL? { URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))) }
    var clientID: String { (baseURL?.absoluteString ?? server) + "/" }
}

enum WatchKeychain {
    private static let service = "es.mohs.familie.watch"
    private static let account = "ha"

    static func load() -> WatchCredentials? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(WatchCredentials.self, from: d)
    }

    static func save(_ c: WatchCredentials) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum WatchError: LocalizedError {
    case notLinked, http(Int), other(String)
    var errorDescription: String? {
        switch self {
        case .notLinked: return "Öffne Familie einmal auf dem iPhone."
        case .http(let c): return "Home Assistant antwortet nicht (\(c))."
        case .other(let s): return s
        }
    }
}

actor WatchHA {
    static let shared = WatchHA()
    private var access: (token: String, until: Date)?

    private func creds() throws -> WatchCredentials {
        guard let c = WatchKeychain.load(), c.baseURL != nil else { throw WatchError.notLinked }
        return c
    }

    private func token(_ c: WatchCredentials) async throws -> String {
        if let t = c.longLivedToken, !t.isEmpty { return t }
        if let a = access, a.until > Date().addingTimeInterval(60) { return a.token }
        guard let rt = c.refreshToken, let base = c.baseURL else { throw WatchError.notLinked }
        var req = URLRequest(url: base.appending(path: "auth/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": c.clientID]
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["access_token"] as? String else { throw WatchError.http(code) }
        let exp = (obj["expires_in"] as? Double) ?? 1800
        access = (at, Date().addingTimeInterval(exp))
        return at
    }

    private func request(_ path: String, method: String = "GET", body: Any? = nil, query: String? = nil) async throws -> Any? {
        let c = try creds()
        guard let base = c.baseURL else { throw WatchError.notLinked }
        var url = base.appending(path: path)
        if let query { url = URL(string: url.absoluteString + "?" + query) ?? url }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = method
        req.setValue("Bearer " + (try await token(c)), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { access = nil }
        guard (200..<300).contains(code) else { throw WatchError.http(code) }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    func state(_ entity: String) async -> (state: String, attributes: [String: Any])? {
        guard let o = try? await request("api/states/" + entity) as? [String: Any], let s = o["state"] as? String else { return nil }
        return (s, o["attributes"] as? [String: Any] ?? [:])
    }

    func call(_ domain: String, _ service: String, _ data: [String: Any]) async throws {
        _ = try await request("api/services/\(domain)/\(service)", method: "POST", body: data)
    }

    func callResponse(_ domain: String, _ service: String, _ data: [String: Any]) async throws -> [String: Any] {
        let r = try await request("api/services/\(domain)/\(service)", method: "POST", body: data, query: "return_response")
        let o = r as? [String: Any] ?? [:]
        return o["service_response"] as? [String: Any] ?? o
    }
}

// MARK: - Verbindung zum iPhone

final class WatchLink: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchLink()
    @Published var linked = WatchKeychain.load() != nil
    @Published var parent = WatchKeychain.load()?.parent ?? false
    /// Gym-Plan mit Gewichten vom iPhone (nur bei Jan)
    @Published var gym: WGymData? = WatchLink.decodeGym(UserDefaults.standard.string(forKey: "gymData"))

    static func decodeGym(_ s: String?) -> WGymData? {
        guard let d = s?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WGymData.self, from: d)
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func take(_ ctx: [String: Any]) {
        if let g = ctx["gym"] as? String, let data = Self.decodeGym(g) {
            UserDefaults.standard.set(g, forKey: "gymData")
            DispatchQueue.main.async { self.gym = data }
        }
        guard let server = ctx["server"] as? String, !server.isEmpty else { return }
        let c = WatchCredentials(server: server, refreshToken: ctx["refreshToken"] as? String,
                                 longLivedToken: ctx["longLivedToken"] as? String,
                                 pushToken: ctx["pushToken"] as? String, parent: ctx["parent"] as? Bool ?? false)
        WatchKeychain.save(c)
        DispatchQueue.main.async {
            self.linked = true
            self.parent = c.parent
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if !session.receivedApplicationContext.isEmpty { take(session.receivedApplicationContext) }
        if WatchKeychain.load() == nil, session.isReachable {
            session.sendMessage(["bitte": "zugang"], replyHandler: { self.take($0) }, errorHandler: nil)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) { take(ctx) }
    func session(_ session: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { take(info) }
}
