import Foundation

// MARK: - Community (auth §4.5, rep §11)

/// One of the 14 `recent` entries (oldest first); `score` = HEI rounded to an integer, or `null` for no data.
struct RecentScore: Codable, Sendable, Hashable { let date: String; let score: Double? }

/// `GET /users` element. `share_detail` is the caller's effective access (`full | summary | none`).
struct CommunityUser: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let username: String; let display_name: String; let avatar_color: String
    let is_me: Bool; let shared_with_me: Bool; let share_detail: String; let last_log_date: String?
    let streak: Int; let recent: [RecentScore]
}

extension CommunityUser {
    /// Mean of the non-null `recent` scores (web `均分`), or nil when there are none.
    var recentAverage: Double? {
        let scores = recent.compactMap(\.score)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}
