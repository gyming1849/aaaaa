import Foundation

// MARK: - Session token storage (auth §9, DESIGN §A.9)

/// The app token (`nla_…`), its ISO-8601 expiry and the server that issued it, stored as JSON in the Keychain.
/// `server` (normalised base URL) is nil for items saved before it existed; such a token is never discarded.
struct StoredToken: Codable, Sendable, Equatable {
    let token: String
    let expires_at: String
    var server: String? = nil
}

extension StoredToken {
    /// Expiry date, nil when unknown (e.g. a token injected by a debug launch argument).
    var expiresAt: Date? { Timestamps.iso(expires_at) }

    /// True when the token expires within `days` days of `now`. Unknown expiry → false (never refresh blindly).
    func expires(withinDays days: Int, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < Double(days) * 86_400
    }
}

/// Keychain service `com.nutrilog.ios`, account `session`.
enum TokenStore {
    static let account = "session"

    static func load() -> StoredToken? {
        guard let data = KeychainStore.load(account: account) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredToken.self, from: data), !stored.token.isEmpty else {
            KeychainStore.delete(account: account)
            return nil
        }
        return stored
    }

    /// The stored token, or nil (and the item deleted) when it was issued by a server other than `server`. The Keychain item
    /// survives an app reinstall while the server override in UserDefaults does not: the token must never go to another host.
    static func load(for server: URL) -> StoredToken? {
        guard let stored = load() else { return nil }
        if let origin = stored.server, origin != server.absoluteString {
            AppLog.app.notice("stored token belongs to another server; discarded")
            clear()
            return nil
        }
        return stored
    }

    /// True only when the Keychain definitely has no token item (not when it could not be read, e.g. before the first
    /// unlock). A restored backup or a migrated device ends up here: the `ThisDeviceOnly` item does not move.
    static var isDefinitelyAbsent: Bool { KeychainStore.presence(account: account) == .absent }

    static func save(_ token: StoredToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        _ = KeychainStore.save(data, account: account)
    }

    static func clear() { KeychainStore.delete(account: account) }

    /// True when a token is stored and it expires within `days` days (token refresh trigger, §B.3: 30 days).
    static func nearExpiry(days: Int) -> Bool { load()?.expires(withinDays: days) ?? false }
}
