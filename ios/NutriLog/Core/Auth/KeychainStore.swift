import Foundation
import Security

// MARK: - Keychain (DESIGN §A.9)

/// Generic-password items under service `com.nutrilog.ios`, accessible after first unlock on this device only
/// (background HealthKit sync must read the token while the phone is locked; never synced to iCloud).
enum KeychainStore {
    static let service = "com.nutrilog.ios"

    /// Inserts or replaces the item. Returns false (and logs the OSStatus) on failure.
    static func save(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account)
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            AppLog.app.error("Keychain save failed for \(account, privacy: .public): OSStatus \(status, privacy: .public)")
            return false
        }
        return true
    }

    static func load(account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default:
            AppLog.app.error("Keychain load failed for \(account, privacy: .public): OSStatus \(status, privacy: .public)")
            return nil
        }
    }

    enum Presence: Sendable, Equatable { case present, absent, unknown }

    /// Whether an item exists, separating "not found" from "could not read" (`errSecInteractionNotAllowed` before the
    /// first unlock). Never wipe anything on `.unknown`.
    static func presence(account: String) -> Presence {
        var query = baseQuery(account)
        query[kSecReturnData] = false
        query[kSecMatchLimit] = kSecMatchLimitOne
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        default: return .unknown
        }
    }

    static func delete(account: String) {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLog.app.error("Keychain delete failed for \(account, privacy: .public): OSStatus \(status, privacy: .public)")
        }
    }

    private static func baseQuery(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
