import Foundation
import Security

/// Secrets (API keys) live in the login keychain, never in config files.
public enum Keychain {
    /// "dev.krill" is from when the app was called Krill; kept so saved keys stay readable. `KELP_KEYCHAIN_SERVICE` names
    /// another, so tests never touch the real keys. Read at each call: nothing caches the first answer.
    static var service: String { ProcessInfo.processInfo.environment["KELP_KEYCHAIN_SERVICE"] ?? "dev.krill" }

    /// Updates in place, so a failure never leaves the account without its old value (delete-then-add would).
    public static func set(_ value: String, account: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        var s = SecItemUpdate(q as CFDictionary,
                              [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
