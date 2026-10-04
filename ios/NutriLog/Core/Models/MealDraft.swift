import Foundation

// MARK: - Drafts, meal requests, preview (meals §1.8–1.15, §2.1–2.14)

/// Per-100 g hazard entry `{key, amount_per_100g, note?}` (draft `per100.hazards`, food `hazards100`).
struct HazardPer100: Codable, Sendable, Hashable { var key: String; var amount_per_100g: Double; var note: String? }

extension HazardPer100 {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        key = try c.req("key")
        amount_per_100g = try c.or("amount_per_100g", 0)
        note = try c.opt("note")
    }
}

struct Per100: Codable, Sendable, Hashable { var nutrients: Vec; var groups: Vec; var hazards: [HazardPer100] }

extension Per100 {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        nutrients = try c.or("nutrients", [:])
        groups = try c.or("groups", [:])
        hazards = try c.or("hazards", [])
    }
}

/// Item under review before saving (meals §1.10): AI meal results and `POST /foods/{id}/item`.
/// Sent as-is in `POST/PUT /meals` and `/preview`; the server ignores `per100`, `save_suggested` and `saved_food_id`.
/// When a nutrient, group or hazard is edited, `food_id` must become nil (`ItemMath`), or the server reverts the edit.
struct DraftItem: Codable, Sendable, Hashable, Identifiable {
    var localId: UUID = UUID()      // client-only, not encoded
    var name: String; var amount_g: Double; var amount_desc: String?; var food_id: Int?; var category: String?
    var cooking_method: String?; var nova_group: Int?; var confidence: String?
    var nutrients: Vec; var groups: Vec; var hazards: [HazardEntry]; var notes: String?
    var per100: Per100; var save_suggested: Bool; var saved_food_id: Int?
    var id: UUID { localId }
    enum CodingKeys: String, CodingKey {
        case name, amount_g, amount_desc, food_id, category, cooking_method, nova_group, confidence, nutrients, groups, hazards, notes, per100, save_suggested, saved_food_id
    }
}

extension DraftItem {
    /// Tolerant decoding: `hazards[].note` is absent on library items and `saved_food_id` is client-only.
    /// A draft without `per100` gets one derived from its portion values (meals §4.2), so rescaling still works.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        name = try c.or("name", "")
        amount_g = try c.req("amount_g")
        amount_desc = try c.opt("amount_desc")
        food_id = try c.opt("food_id")
        category = try c.opt("category")
        cooking_method = try c.opt("cooking_method")
        nova_group = try c.flexIntIfPresent("nova_group")
        confidence = try c.opt("confidence")
        nutrients = try c.or("nutrients", [:])
        groups = try c.or("groups", [:])
        hazards = try c.or("hazards", [])
        notes = try c.opt("notes")
        save_suggested = try c.flexBool("save_suggested", or: false)
        saved_food_id = try c.opt("saved_food_id")
        if let p: Per100 = try c.opt("per100") {
            per100 = p
        } else {
            let f = amount_g > 0 ? 100 / amount_g : 1
            per100 = Per100(
                nutrients: nutrients.mapValues { ($0 * f).isFinite ? $0 * f : 0 },
                groups: groups.mapValues { ($0 * f).isFinite ? $0 * f : 0 },
                hazards: hazards.map { HazardPer100(key: $0.key, amount_per_100g: ($0.amount * f).isFinite ? $0.amount * f : 0, note: nil) }
            )
        }
    }
}

/// Result of AI job kind `meal` (meals §1.13). Does not echo the date, time or meal type.
struct MealDraft: Codable, Sendable { var items: [DraftItem]; var summary: String; var assumptions: [String]; var questions: [String]; var sources: [SourceLink]; var provider: String; var model: String }

extension MealDraft {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        items = try c.or("items", [])
        summary = try c.or("summary", "")
        assumptions = try c.or("assumptions", [])
        questions = try c.or("questions", [])
        sources = try c.or("sources", [])
        provider = try c.or("provider", "")
        model = try c.or("model", "")
    }
}

struct MealAIRequest: Encodable, Sendable { let text: String; let date: String; let time: String; let meal_type: String; let photos: [String] }
/// `POST /meals` and `PUT /meals/{id}` (PUT ignores `photos`, `ai_summary`, `ai_model`).
struct MealBody: Encodable, Sendable { let date: String; let time: String; let meal_type: String; let description: String; let photos: [String]; let ai_summary: String; let ai_model: String; let items: [DraftItem] }
struct PreviewMeal: Encodable, Sendable { let meal_type: String; let time: String; let items: [DraftItem]; let replace_meal_id: Int? }
struct PreviewBody: Encodable, Sendable, Hashable { var weight_kg: Double?; var body_fat_pct: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool? }
/// `POST /preview` (meals §2.8, body §4.5). Never send an empty `meal.items`.
struct PreviewRequest: Encodable, Sendable { let date: String; var meal: PreviewMeal?; var activity: ActivityValues?; var body: PreviewBody?; var workouts: [WorkoutDraft]? }
struct PreviewIndices: Decodable, Sendable { let before: HealthIndices; let after: HealthIndices }
struct DayPreview: Decodable, Sendable { let date: String; let before: DailyScore; let after: DailyScore; let indices: PreviewIndices }
struct WaterBody: Encodable, Sendable { let ml: Double; let date: String }
struct WaterResponse: Decodable, Sendable { let ok: Bool; let total_ml: Double }
/// `GET /meals/recent-items` row; filter out `饮用水`.
struct RecentItem: Decodable, Sendable, Hashable { let name: String; let food_id: Int?; let amount_g: Double; let n: Int; let last: String }
/// `url` is `/api/uploads/<id>` (unversioned); the client fetches `api/v1/uploads/<id>` instead.
struct UploadedPhoto: Codable, Sendable, Hashable, Identifiable { let id: String; let url: String }
struct UploadResponse: Decodable, Sendable { let photos: [UploadedPhoto] }
struct AIStatus: Decodable, Sendable { let provider: String; let model: String; let web_search: Bool }
