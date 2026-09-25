import Foundation
import Security

/// Zugangsdaten zu Home Assistant – liegen verschlüsselt in der Schlüsselbund (Keychain).
struct Credentials: Codable, Equatable {
    var server: String                // z. B. https://ha.mohs.es
    var refreshToken: String?         // bei Login mit Benutzer/Passwort
    var accessToken: String?
    var accessExpiry: Date?
    var longLivedToken: String?       // alternativ: langlebiges Token

    var baseURL: URL? { URL(string: server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    var clientID: String { (baseURL?.absoluteString ?? server) + "/" }
}

enum Keychain {
    private static let service = "es.mohs.familie"
    private static let account = "ha-credentials"

    static func load() -> Credentials? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
