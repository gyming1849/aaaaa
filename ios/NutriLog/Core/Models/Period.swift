import Foundation

// MARK: - Period & reports (rep §6–§8)

/// Per ScoreItem key: how many logged days had each status (`info` items excluded). Includes `hei_*` items.
struct ItemStat: Codable, Sendable, Identifiable { let key: String; let zh: String; let category: String; let good: Int; let ok: Int; let warn: Int; let bad: Int; let days: Int; var id: String { key } }
struct PeriodCheck: Codable, Sendable, Identifiable { let key: String; let zh: String; let value: Double; let unit: String; let targetText: String; let status: ScoreStatus; let score: Double; let message: String; let sources: [String]; var id: String { key } }
/// Sorted by `days` descending. No `foods`, no message.
struct PeriodHazard: Codable, Sendable, Identifiable { let key: String; let zh: String; let iarc: String; let dose: Double; let unit: String; let days: Int; var id: String { key } }
struct PeriodEnergy: Codable, Sendable {
    let avgIntake: Double?; let avgTdee: Double; let totalBalance: Double; let predictedChangeKg: Double
    let trendStart: Double?; let trendEnd: Double?; let actualChangeKg: Double?; let empiricalTdee: Double?; let ratePerWeek: Double?
}
/// One per day, unrounded. `score` = HEI, `total` = daily composite.
struct PeriodSeriesPoint: Codable, Sendable { let date: String; let score: Double?; let total: Double?; let intake: Double; let tdee: Double; let weight: Double?; let trend: Double? }
struct WeeklySummary: Codable, Sendable, Hashable { let headline: String; let summary: String; let wins: [String]; let issues: [String]; let actions: [String] }

/// `GET /period` = PeriodScore + `aiSummary` + `full` (rep §6.2). `score` is the LE8 period score; `total` is the composite.
struct PeriodScore: Codable, Sendable {
    let start: String; let end: String; let days: Int; let daysLogged: Int; let avgHei: Double?; let avgMar: Double?
    let score: Double?; let total: CompositeScore; let category: KeyZh?; let indices: HealthIndices; let hei: HeiResult?
    let avgTotals: Vec; let avgGroups: Vec; let itemStats: [ItemStat]; let checks: [PeriodCheck]; let hazards: [PeriodHazard]
    let energy: PeriodEnergy; let series: [PeriodSeriesPoint]; let aiSummary: WeeklySummary?; let full: Bool
}
struct PeriodSummaryRequest: Encodable, Sendable { let start: String; let end: String }
/// `GET /reports` row (rep §8). `score` is the LE8 score at generation time; `created_at` is SQLite UTC.
struct ReportListItem: Decodable, Sendable, Identifiable { let id: Int; let period: String; let start_date: String; let end_date: String; let score: Double?; let ai_summary: WeeklySummary?; let created_at: String }
