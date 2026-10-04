import Foundation

// MARK: - Scoring (rep §3; meals §1.16)

/// Composite part. `score`/`points` are null when data is missing (rep §3.2).
struct CompositePart: Codable, Sendable, Hashable { let key: String; let zh: String; let weight: Double; let score: Double?; let points: Double?; let note: String }
struct CompositeScore: Codable, Sendable, Hashable { let score: Double?; let parts: [CompositePart]; let missing: [String] }
struct CategoryResult: Codable, Sendable { let key: String; let zh: String; let score: Double; let source: String; let note: String }

/// rep §3.4. `target`, `ideal` and `limit` are **absent** unless the item kind defines them.
struct ScoreItem: Codable, Sendable, Identifiable {
    let key: String; let category: String; let zh: String; let value: Double; let unit: String; let targetText: String
    let target: Double?; let ideal: Double?; let limit: Double?; let status: ScoreStatus
    let score: Double; let points: Double; let maxPoints: Double; let message: String; let sources: [String]
    var id: String { key }
}

/// HEI component. `best`/`worst` are present only on the period `hei` (rep §3.5, §6.2).
struct HeiComponent: Codable, Sendable, Identifiable { let key: String; let zh: String; let score: Double; let max: Double; let value: Double; let unit: String; let hint: String; let best: Double?; let worst: Double?; var id: String { key } }
struct HeiResult: Codable, Sendable { let total: Double; let components: [HeiComponent] }
struct MarNutrient: Codable, Sendable { let key: String; let zh: String; let intake: Double; let target: Double; let nar: Double }
struct MarResult: Codable, Sendable { let value: Double; let nutrients: [MarNutrient] }
struct HazardResult: Codable, Sendable, Identifiable { let key: String; let zh: String; let iarc: String; let dose: Double; let unit: String; let foods: [String]; let message: String; let sources: [String]; var id: String { key } }

/// rep §3.8. All kcal, unrounded.
struct EnergyResult: Codable, Sendable {
    let intake: Double; let resting: Double; let restingSource: String; let active: Double; let activeSource: String
    let exerciseKcal: Double; let tef: Double; let tdee: Double; let method: String; let target: Double; let balance: Double
}
struct MacroPct: Codable, Sendable { let protein: Double; let carb: Double; let fat: Double; let satFat: Double; let addedSugar: Double; let alcohol: Double }
struct Completeness: Codable, Sendable { let level: String; let note: String }
struct TopLists: Codable, Sendable { let issues: [String]; let wins: [String] }

/// rep §3.1. When `hasData == false`: `score`/`hei`/`mar` are null and `categories`/`items`/`hazards`/`top` are empty.
struct DailyScore: Codable, Sendable {
    let date: String; let hasData: Bool; let score: Double?; let total: CompositeScore; let categories: [CategoryResult]
    let items: [ScoreItem]; let hei: HeiResult?; let mar: MarResult?; let hazards: [HazardResult]; let energy: EnergyResult
    let totals: Vec; let groups: Vec; let macroPct: MacroPct; let upfPct: Double
    let mealCount: Int; let itemCount: Int; let fastFoodMeals: Int; let completeness: Completeness; let top: TopLists
    let weightKg: Double; let weighedToday: Double?; let version: Int?
    func item(_ key: String) -> ScoreItem? { items.first { $0.key == key } }
}
