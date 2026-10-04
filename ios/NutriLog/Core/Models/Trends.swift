import Foundation

// MARK: - Trends (rep §10)

/// One calendar day of `GET /trends`. `categories` holds only the available keys (`hei`, `mar`); `{}` with no data.
/// `statuses` covers every ScoreItem except `info` ones; `{}` with no data.
struct TrendDay: Codable, Sendable {
    let date: String; let hasData: Bool; let score: Double?; let total: Double?; let categories: [String: Double]; let hazardCount: Int
    let hei: Double?; let mar: Double?; let intake: Double; let tdee: Double; let target: Double; let exerciseKcal: Double; let energyMethod: String
    let weight: Double?; let trend: Double?; let steps: Double?; let activeKcal: Double?; let completeness: String
    let totals: Vec; let groups: Vec; let macroPct: [String: Double]; let upfPct: Double; let statuses: [String: ScoreStatus]
}

/// Payload can reach about 3 MB for "全部"; decode it off the main actor (inside `APIClient`).
struct TrendsResponse: Codable, Sendable { let start: String; let end: String; let days: [TrendDay] }
