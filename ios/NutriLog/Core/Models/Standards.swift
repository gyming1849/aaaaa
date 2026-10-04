import Foundation

// MARK: - Standards (rep §9)

/// `dv` and `note` are absent when undefined. `group`: energy | macro | carb | fat | mineral | vitamin | other.
struct NutrientDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let en: String; let unit: String; let group: String; let decimals: Int; let dv: Double?; let note: String?; var id: String { key } }
struct FoodGroupDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let unit: String; let note: String; var id: String { key } }
/// `from`: group | nutrient | flag. `key` is absent for `flag`.
struct HazardDose: Codable, Sendable { let from: String; let unit: String; let key: String? }
struct HazardDef: Codable, Sendable, Identifiable {
    let key: String; let zh: String; let en: String; let iarc: String; let category: String; let risk: String; let detect: String
    let examples: String; let dose: HazardDose; let refAmount: Double; let aiFlag: Bool?; let sources: [String]; let advice: String
    var id: String { key }
}
/// `iarc` may be `"3"`.
struct HazardInfoOnly: Codable, Sendable { let zh: String; let iarc: String; let examples: String; let why: String }
struct HeiDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let en: String; let max: Double; let kind: String; let best: Double; let worst: Double; let unit: String; let hint: String; var id: String { key } }
/// MET table entry; `speedKmh`/`code` may be absent. `intensity`: light | moderate | vigorous.
struct ActivityDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let met: Double; let speedKmh: Double?; let code: String?; let intensity: String; var id: String { key } }
struct ActivityLevelDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let pal: Double; let desc: String; var id: String { key } }
/// `url` may be `""` (id `system`).
struct SourceDef: Codable, Sendable, Identifiable { let id: String; let org: String; let title: String; let year: String; let url: String }
struct LifeStage: Codable, Sendable, Identifiable { let id: String; let zh: String }

/// `GET /standards/meta` (rep §9.0). Static; cache it keyed by `version`.
struct Meta: Codable, Sendable {
    let version: Int; let nutrients: [NutrientDef]; let foodGroups: [FoodGroupDef]; let hazards: [HazardDef]; let hazardsInfoOnly: [HazardInfoOnly]
    let hei: [HeiDef]; let activities: [ActivityDef]; let activityLevels: [ActivityLevelDef]; let sources: [SourceDef]
    let lifeStages: [LifeStage]; let marNutrients: [String]; let heiUsMean: Double; let conditions: [ConditionDef]
}

/// `values[i]` belongs to `lifeStages[i]`; `null` = not determined (shown as `ND`).
struct DriIntakeRow: Codable, Sendable { let kind: String; let values: [Double?] }
struct DriUpperRow: Codable, Sendable { let appliesToTotal: Bool; let note: String?; let values: [Double?] }
/// `GET /standards/dri` (rep §9.4). Render rows in `Vocab.intakeOrder` / `Vocab.upperOrder`.
struct DriTables: Codable, Sendable { let lifeStages: [LifeStage]; let intake: [String: DriIntakeRow]; let upper: [String: DriUpperRow]; let sodiumCdrr: [Double]; let proteinPerKg: [Double] }
