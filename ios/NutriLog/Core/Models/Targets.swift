import Foundation

// MARK: - Targets (auth §4.6, rep §4)
// `intake`, `upper` and `limits` are dictionaries whose JSON key order is meaningful (rep §0.7):
// render rows in `Vocab.intakeOrder`, `Vocab.upperOrder` and `Targets.limitOrder`.

/// `note` is absent except on `protein_g` and `fiber_g`.
struct IntakeTarget: Codable, Sendable { let key: String; let value: Double; let kind: String; let source: String; let note: String? }
/// `note` is present only on rows with `appliesToTotal == false`.
struct UpperTarget: Codable, Sendable { let value: Double; let appliesToTotal: Bool; let note: String? }
struct LimitTarget: Codable, Sendable { let key: String; let zh: String; let unit: String; let ideal: Double; let limit: Double; let idealSource: String; let limitSource: String; let note: String? }
struct ProteinTargets: Codable, Sendable { let rdaG: Double; let idealLowG: Double; let idealHighG: Double; let perKgRda: Double }
/// `[lo, hi]` percent of energy. `n6`/`n3` are server extras missing from the web type.
struct Amdr: Codable, Sendable { let protein: [Double]; let carb: [Double]; let fat: [Double]; let n6: [Double]?; let n3: [Double]? }

struct Targets: Codable, Sendable {
    let date: String; let age: Int; let sex: String; let lifeStage: String; let lifeStageZh: String; let physiology: String; let sensitive: Bool
    let weightKg: Double; let heightCm: Double; let bmi: Double; let bmiCategory: KeyZh; let referenceWeightKg: Double
    let bmr: Double; let eer: Double; let eerMethod: String; let goal: String; let goalDeltaKcal: Double; let energyTarget: Double; let energyFloor: Double
    let protein: ProteinTargets
    let intake: [String: IntakeTarget]; let upper: [String: UpperTarget]; let limits: [String: LimitTarget]
    let amdr: Amdr; let addedSugarPerMealG: Double; let aspartameAdiMg: Double
    static let limitOrder = ["sodium_mg", "added_sugars_g", "sat_fat_pct", "trans_fat_g", "alcohol_g", "caffeine_mg", "upf_pct"]
}

extension Targets {
    /// `intake` rows in the server's INTAKE order (rep §9.4); keys missing from the response are skipped.
    var orderedIntake: [IntakeTarget] { Vocab.intakeOrder.compactMap { intake[$0] } }
    /// `limits` rows in `limitOrder`.
    var orderedLimits: [LimitTarget] { Targets.limitOrder.compactMap { limits[$0] } }
}
