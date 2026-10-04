import Foundation

// MARK: - Day, meals, raw rows (rep §2, meals §1.9/§1.11, body §2)

/// Per-portion hazard entry `{key, amount, note?}` (meals §1.7). `note` is often absent;
/// legacy rows may even lack `amount`, which then reads as 0 ("use refAmount").
struct HazardEntry: Codable, Sendable, Hashable { var key: String; var amount: Double; var note: String? }

extension HazardEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        key = try c.req("key")
        amount = try c.or("amount", 0)
        note = try c.opt("note")
    }
}

/// Item inside a saved meal (meals §1.9). Optional strings may be `""` or `null`; treat both as empty.
struct MealItem: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let meal_id: Int; let name: String; let amount_g: Double; let nutrients: Vec; let groups: Vec
    let hazards: [HazardEntry]; let nova_group: Int?; let category: String?; let amount_desc: String?; let food_id: Int?
    let cooking_method: String?; let confidence: String?; let notes: String?
}

extension MealItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.req("id")
        meal_id = try c.req("meal_id")
        name = try c.or("name", "")
        amount_g = try c.req("amount_g")
        nutrients = try c.or("nutrients", [:])
        groups = try c.or("groups", [:])
        hazards = try c.or("hazards", [])
        nova_group = try c.flexIntIfPresent("nova_group")
        category = try c.opt("category")
        amount_desc = try c.opt("amount_desc")
        food_id = try c.opt("food_id")
        cooking_method = try c.opt("cooking_method")
        confidence = try c.opt("confidence")
        notes = try c.opt("notes")
    }
}

/// `GET /day/{date}` → `meals[]` (meals §1.11). `photos` are upload ids (filenames), not URLs.
/// The water pseudo-meal has `description == "饮水"`; hide it from meal lists.
struct Meal: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let time: String; let meal_type: String; let description: String
    let photos: [String]; let ai_summary: String?; let items: [MealItem]
    var isWater: Bool { description == "饮水" }
    var kcal: Double { items.reduce(0) { $0 + $1.nutrients.v("energy_kcal") } }
}

extension Meal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.req("id")
        date = try c.req("date")
        time = try c.req("time")
        meal_type = try c.or("meal_type", "other")
        description = try c.or("description", "")
        photos = try c.or("photos", [])
        ai_summary = try c.opt("ai_summary")
        items = try c.or("items", [])
    }
}

/// Raw `activity_days` row (body §2.2). There is no id; the key is `date`. `steps` may be non-integral.
struct ActivityDay: Codable, Sendable, Hashable {
    let date: String; let steps: Double?; let active_kcal: Double?; let resting_kcal: Double?; let distance_km: Double?
    let exercise_min: Double?; let sleep_hours: Double?; let stand_hours: Double?; let source: String; let updated_at: String?
}

/// Raw `exercises` row (body §2.3). `in_device` is an SQLite 0/1 integer.
struct Exercise: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let time: String; let description: String; let activity_key: String?
    let met: Double; let duration_min: Double; let distance_km: Double?; let kcal: Double; let in_device: Int
    let avg_hr: Double?; let device_kcal: Double?; let source: String; let created_at: String?
    let external_id: String?; let source_name: String?          // present after server migration v3
    /// HealthKit workouts only (migration v3, DESIGN §C.1/§C.9): ISO-8601 start/end with offset and the raw
    /// `HKWorkoutActivityType`; null on manual/AI rows and absent on old servers.
    let started_at: String?; let ended_at: String?; let hk_activity_type: Int?
    var inDevice: Bool { in_device != 0 }
}

extension Exercise {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.req("id")
        date = try c.req("date")
        time = try c.or("time", "12:00")
        description = try c.or("description", "")
        activity_key = try c.opt("activity_key")
        met = try c.req("met")
        duration_min = try c.req("duration_min")
        distance_km = try c.opt("distance_km")
        kcal = try c.or("kcal", 0)
        in_device = try c.flexInt("in_device", or: 0)
        avg_hr = try c.opt("avg_hr")
        device_kcal = try c.opt("device_kcal")
        source = try c.or("source", "manual")
        created_at = try c.opt("created_at")
        external_id = try c.opt("external_id")
        source_name = try c.opt("source_name")
        started_at = try c.opt("started_at")
        ended_at = try c.opt("ended_at")
        hk_activity_type = try c.flexIntIfPresent("hk_activity_type")
    }
}

/// Raw `body_metrics` row (body §2.1). `bp_treated` is an SQLite 0/1 integer.
struct BodyMetric: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let time: String; let weight_kg: Double?; let body_fat_pct: Double?; let waist_cm: Double?
    let sbp: Double?; let dbp: Double?; let bp_treated: Int; let note: String?; let source: String; let created_at: String?
    let external_id: String?; let source_name: String?
}

extension BodyMetric {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.req("id")
        date = try c.req("date")
        time = try c.or("time", "22:00")
        weight_kg = try c.opt("weight_kg")
        body_fat_pct = try c.opt("body_fat_pct")
        waist_cm = try c.opt("waist_cm")
        sbp = try c.opt("sbp")
        dbp = try c.opt("dbp")
        bp_treated = try c.flexInt("bp_treated", or: 0)
        note = try c.opt("note")
        source = try c.or("source", "manual")
        created_at = try c.opt("created_at")
        external_id = try c.opt("external_id")
        source_name = try c.opt("source_name")
    }

    var bpTreated: Bool { bp_treated != 0 }
}

/// Raw `lab_results` row (body §2.4). Values in mg/dL (HbA1c in %); flags are SQLite 0/1 integers.
struct LabResult: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let total_chol: Double?; let hdl: Double?; let non_hdl: Double?; let ldl: Double?
    let lipid_treated: Int; let fasting_glucose: Double?; let hba1c: Double?; let diabetes: Int; let note: String?; let created_at: String?
}

extension LabResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.req("id")
        date = try c.req("date")
        total_chol = try c.opt("total_chol")
        hdl = try c.opt("hdl")
        non_hdl = try c.opt("non_hdl")
        ldl = try c.opt("ldl")
        lipid_treated = try c.flexInt("lipid_treated", or: 0)
        fasting_glucose = try c.opt("fasting_glucose")
        hba1c = try c.opt("hba1c")
        diabetes = try c.flexInt("diabetes", or: 0)
        note = try c.opt("note")
        created_at = try c.opt("created_at")
    }

    var lipidTreated: Bool { lipid_treated != 0 }
    var hasDiabetes: Bool { diabetes != 0 }
}

/// `GET /day/{date}` (rep §2.2). With `full == false`, `meals`/`exercises` are empty and messages are stripped.
struct DayResponse: Codable, Sendable {
    let date: String; let indices: HealthIndices; let score: DailyScore; let targets: Targets; let meals: [Meal]
    let activity: ActivityDay?; let exercises: [Exercise]; let body: [BodyMetric]; let weightTrend: Double?; let full: Bool
    var visibleMeals: [Meal] { meals.filter { !$0.isWater } }
    var waterMl: Double { meals.first(where: { $0.isWater })?.items.first?.amount_g ?? 0 }
}
