import Foundation
import UIKit

enum HAError: LocalizedError {
    case notConfigured
    case badServer
    case invalidLogin
    case mfaRequired(flowID: String)
    case http(Int, String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Noch nicht angemeldet."
        case .badServer: return "Die Server-Adresse ist ungültig."
        case .invalidLogin: return "Benutzername oder Passwort ist falsch."
        case .mfaRequired: return "Bitte den Code aus der Authentifizierungs-App eingeben."
        case .http(let code, let body):
            if code == 401 { return "Nicht berechtigt – bitte neu anmelden." }
            return "Home Assistant meldet Fehler \(code). \(body.prefix(160))"
        case .unexpected(let s): return s
        }
    }
}

/// Spricht mit der REST-API von Home Assistant.
actor HAClient {
    private(set) var credentials: Credentials?
    private let session: URLSession
    private let onCredentialsChange: @Sendable (Credentials?) -> Void

    init(credentials: Credentials?, onCredentialsChange: @escaping @Sendable (Credentials?) -> Void) {
        self.credentials = credentials
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        self.onCredentialsChange = onCredentialsChange
    }

    // MARK: - Anmeldung

    /// Startet den Login-Flow (wie die HA-Weboberfläche) und liefert Tokens.
    func login(server: String, username: String, password: String, mfaCode: String? = nil, pendingFlowID: String? = nil) async throws {
        var creds = Credentials(server: server)
        guard let base = creds.baseURL, base.scheme?.hasPrefix("http") == true else { throw HAError.badServer }

        var flowID = pendingFlowID
        if flowID == nil {
            let start = try await postJSON(base.appending(path: "auth/login_flow"), [
                "client_id": creds.clientID,
                "handler": ["homeassistant", NSNull()],
                "redirect_uri": creds.clientID + "?auth_callback=1",
            ])
            guard let id = start["flow_id"]?.string else { throw HAError.unexpected("Login konnte nicht gestartet werden.") }
            flowID = id
        }

        var body: [String: Any] = ["client_id": creds.clientID]
        if let mfaCode, pendingFlowID != nil { body["code"] = mfaCode }
        else { body["username"] = username; body["password"] = password }

        let step = try await postJSON(base.appending(path: "auth/login_flow/\(flowID!)"), body)
        switch step["type"]?.string ?? "" {
        case "create_entry":
            guard let code = step["result"]?.string else { throw HAError.unexpected("Kein Anmeldecode erhalten.") }
            let tok = try await tokenRequest(base, ["grant_type": "authorization_code", "code": code, "client_id": creds.clientID])
            creds.refreshToken = tok.refresh
            creds.accessToken = tok.access
            creds.accessExpiry = Date().addingTimeInterval(tok.expiresIn - 60)
            setCredentials(creds)
        case "form" where step["step_id"]?.string == "mfa":
            if pendingFlowID != nil, step["errors"]?.object?.isEmpty == false {
                throw HAError.unexpected("Der Code ist ungültig. Bitte erneut versuchen.")
            }
            throw HAError.mfaRequired(flowID: flowID!)
        default:
            throw HAError.invalidLogin
        }
    }

    func useLongLivedToken(server: String, token: String) async throws {
        let creds = Credentials(server: server, longLivedToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard creds.baseURL != nil else { throw HAError.badServer }
        let old = credentials
        credentials = creds
        do { _ = try await ping() } catch { credentials = old; throw error }
        setCredentials(creds)
    }

    func logout() async {
        if let c = credentials, let base = c.baseURL, let rt = c.refreshToken {
            _ = try? await tokenRequest(base, ["action": "revoke", "token": rt])
        }
        setCredentials(nil)
    }

    private func setCredentials(_ c: Credentials?) {
        credentials = c
        onCredentialsChange(c)
    }

    private func validAccessToken() async throws -> String {
        guard var c = credentials, let base = c.baseURL else { throw HAError.notConfigured }
        if let llt = c.longLivedToken, !llt.isEmpty { return llt }
        if let at = c.accessToken, let exp = c.accessExpiry, exp > Date() { return at }
        guard let rt = c.refreshToken else { throw HAError.notConfigured }
        let tok = try await tokenRequest(base, ["grant_type": "refresh_token", "refresh_token": rt, "client_id": c.clientID])
        c.accessToken = tok.access
        c.accessExpiry = Date().addingTimeInterval(tok.expiresIn - 60)
        setCredentials(c)
        return tok.access
    }

    private func tokenRequest(_ base: URL, _ form: [String: String]) async throws -> (access: String, refresh: String?, expiresIn: Double) {
        var req = URLRequest(url: base.appending(path: "auth/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if form["action"] == "revoke" { return ("", nil, 0) }
        guard code == 200 else {
            // Refresh-Token wurde widerrufen/ist abgelaufen → neu anmelden (nicht bei Serverfehlern 5xx)
            if form["grant_type"] == "refresh_token", [400, 401, 403].contains(code) { setCredentials(nil) }
            throw HAError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let at = json["access_token"]?.string else { throw HAError.unexpected("Ungültige Antwort beim Anmelden.") }
        return (at, json["refresh_token"]?.string, json["expires_in"]?.double ?? 1800)
    }

    private func postJSON(_ url: URL, _ body: [String: Any]) async throws -> JSONValue {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HAError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - API

    private func api(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        guard let base = credentials?.baseURL else { throw HAError.notConfigured }
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry, credentials?.longLivedToken == nil {
            credentials?.accessExpiry = .distantPast        // Token erneuern und einmal wiederholen
            return try await api(path, method: method, query: query, json: json, retry: false)
        }
        guard (200..<300).contains(code) else { throw HAError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    func ping() async throws -> String {
        let data = try await api("api/")
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?["message"]?.string ?? "OK"
    }

    func states() async throws -> [HAState] {
        try JSONDecoder().decode([HAState].self, from: try await api("api/states"))
    }

    func calendars() async throws -> [HACalendar] {
        try JSONDecoder().decode([HACalendar].self, from: try await api("api/calendars"))
    }

    func events(calendar: String, from: Date, to: Date) async throws -> [HAEvent] {
        let data = try await api("api/calendars/\(calendar)", query: [
            URLQueryItem(name: "start", value: HADate.iso.string(from: from)),
            URLQueryItem(name: "end", value: HADate.iso.string(from: to)),
        ])
        let raw = try JSONDecoder().decode([HAEventRaw].self, from: data)
        return raw.compactMap { r in
            let allDay = r.start.dateTime == nil
            guard let s = HADate.parse(r.start.dateTime ?? r.start.date),
                  let e = HADate.parse(r.end.dateTime ?? r.end.date) else { return nil }
            let id = "\(calendar)|\(r.uid ?? r.summary ?? "")|\(r.recurrence_id ?? "")|\(s.timeIntervalSince1970)"
            return HAEvent(id: id, calendarID: calendar, summary: r.summary ?? "(ohne Titel)",
                           location: r.location, description: r.description,
                           start: s, end: e, allDay: allDay)
        }
    }

    @discardableResult
    func call(_ domain: String, _ service: String, _ data: [String: Any] = [:]) async throws -> Data {
        try await api("api/services/\(domain)/\(service)", method: "POST", json: data)
    }

    /// Service mit Rückgabewert (z. B. todo.get_items)
    func callWithResponse(_ domain: String, _ service: String, _ data: [String: Any]) async throws -> JSONValue {
        let raw = try await api("api/services/\(domain)/\(service)", method: "POST",
                                query: [URLQueryItem(name: "return_response", value: nil)], json: data)
        let json = try JSONDecoder().decode(JSONValue.self, from: raw)
        return json["service_response"] ?? json
    }

    func image(path: String) async -> UIImage? {
        guard let base = credentials?.baseURL,
              let url = URL(string: path, relativeTo: base),
              let token = try? await validAccessToken() else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }
}
