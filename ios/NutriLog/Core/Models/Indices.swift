import Foundation

// MARK: - Indices (rep §5): `/day.indices` (7-day window) and `/period.indices` (whole period)

/// LE8 component (always 8, fixed order). `value` is `"—"` when there is no data.
struct Le8Component: Codable, Sendable, Identifiable { let key: String; let zh: String; let points: Double?; let value: String; let rule: String; let missing: String; var id: String { key } }
struct Le8Result: Codable, Sendable { let score: Double?; let category: KeyZh?; let available: Int; let components: [Le8Component] }
/// WCRF component (always 7). `points` is null when there is no data; `upf` has `max == 0` and is never scored.
struct WcrfComponent: Codable, Sendable, Identifiable { let key: String; let zh: String; let points: Double?; let max: Double; let detail: String; let rule: String; var id: String { key } }
/// `score` is always a number (rep §15).
struct WcrfResult: Codable, Sendable { let score: Double; let max: Double; let components: [WcrfComponent] }
struct MepaItem: Codable, Sendable, Identifiable { let key: String; let zh: String; let criterion: String; let value: Double; let unit: String; let met: Bool; var id: String { key } }
/// `null` when fewer than 3 days are logged.
struct MepaResult: Codable, Sendable { let score: Int; let days: Int; let items: [MepaItem] }
/// Minutes per week are null when the window has no exercise rows and no `exercise_min`.
struct PhysicalActivitySummary: Codable, Sendable { let le8MinPerWeek: Double?; let mvpaMinPerWeek: Double?; let strengthDays: Int }
struct HealthIndices: Codable, Sendable {
    let windowDays: Int; let loggedDays: Int; let mepa: MepaResult?; let le8: Le8Result; let wcrf: WcrfResult
    let pa: PhysicalActivitySummary; let sleepHours: Double?
}
