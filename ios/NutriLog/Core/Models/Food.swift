import Foundation

// MARK: - Foods (meals §1.12, §1.14, §2.15–2.21; web2 §5.9, §6.5)

enum FoodScope: String, Sendable { case all, mine }

/// Library entry (`GET /foods`, `GET /foods/{id}`). Note `aliases` is a comma-joined **string** here.
/// `""` and `null` are equivalent for `brand`, `serving_desc`, `ingredients` and `notes`.
struct Food: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let owner_id: Int; let visibility: String; let name: String; let brand: String?; let aliases: String
    let category: String?; let serving_g: Double?; let serving_desc: String?; let per100: Vec; let groups100: Vec
    let hazards100: [HazardPer100]; let nova_group: Int?; let ingredients: String?; let label_fields: [String]
    let source: String; let source_urls: [SourceLink]; let notes: String?; let use_count: Int
    let created_at: String?; let updated_at: String?; let owner_name: String?; let mine: Bool
}

extension Food {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.req("id")
        owner_id = try c.flexInt("owner_id", or: 0)
        visibility = try c.or("visibility", "private")
        name = try c.or("name", "")
        brand = try c.opt("brand")
        // A string in responses, but tolerate the request form (an array) too.
        if let list = try? c.decodeIfPresent([String].self, forKey: "aliases") {
            aliases = list.joined(separator: ",")
        } else {
            aliases = try c.or("aliases", "")
        }
        category = try c.opt("category")
        serving_g = try c.opt("serving_g")
        serving_desc = try c.opt("serving_desc")
        per100 = try c.or("per100", [:])
        groups100 = try c.or("groups100", [:])
        hazards100 = try c.or("hazards100", [])
        nova_group = try c.flexIntIfPresent("nova_group")
        ingredients = try c.opt("ingredients")
        label_fields = try c.or("label_fields", [])
        source = try c.or("source", "manual")
        source_urls = try c.or("source_urls", [])
        notes = try c.opt("notes")
        use_count = try c.flexInt("use_count", or: 0)
        created_at = try c.opt("created_at")
        updated_at = try c.opt("updated_at")
        owner_name = try c.opt("owner_name")
        mine = try c.flexBool("mine", or: false)
    }

    /// `aliases` split for display and editing (`[,，、]+`, trimmed, empties removed).
    var aliasList: [String] { FoodInput.splitAliases(aliases) }

    /// Full-replace body for `PUT /foods/{id}`: round-trips every field, including the non-editable
    /// `groups100`, `hazards100`, `label_fields` and `source_urls` (meals §2.18).
    func toInput() -> FoodInput {
        FoodInput(
            name: name, brand: brand ?? "", aliases: aliasList, category: category ?? "other", serving_g: serving_g,
            serving_desc: serving_desc ?? "", per100: per100, groups100: groups100, hazards100: hazards100,
            nova_group: nova_group, ingredients: ingredients ?? "", label_fields: label_fields, source: source,
            source_urls: source_urls, notes: notes ?? "", visibility: visibility
        )
    }
}

/// Body of `POST /foods` / `PUT /foods/{id}` (meals §2.17). `aliases` is sent as an array.
struct FoodInput: Codable, Sendable, Hashable {
    var name: String; var brand: String; var aliases: [String]; var category: String; var serving_g: Double?; var serving_desc: String
    var per100: Vec; var groups100: Vec; var hazards100: [HazardPer100]; var nova_group: Int?; var ingredients: String
    var label_fields: [String]; var source: String; var source_urls: [SourceLink]; var notes: String; var visibility: String
}

extension FoodInput {
    /// Defaults of the web's manual-entry editor (meals §6.5).
    static func blank() -> FoodInput {
        FoodInput(
            name: "", brand: "", aliases: [], category: "other", serving_g: 100, serving_desc: "",
            per100: [:], groups100: [:], hazards100: [], nova_group: nil, ingredients: "",
            label_fields: [], source: "manual", source_urls: [], notes: "", visibility: "private"
        )
    }

    /// Editor prefill from an AI lookup result (web2 §5.9.3): `source_urls = draft.sources`, private by default.
    init(draft: FoodDraft) {
        self.init(
            name: draft.name, brand: draft.brand, aliases: draft.aliases, category: draft.category, serving_g: draft.serving_g,
            serving_desc: draft.serving_desc, per100: draft.per100, groups100: draft.groups100, hazards100: draft.hazards100,
            nova_group: draft.nova_group, ingredients: draft.ingredients, label_fields: draft.label_fields, source: draft.source,
            source_urls: draft.sources, notes: draft.notes, visibility: "private"
        )
    }

    /// Splits an alias text on `,` `，` `、`, trims whitespace and drops empty entries (web `split(/[,，、]+/)`).
    static func splitAliases(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Result of AI job kind `food` (meals §1.14). `aliases` is an **array** here; there is no `model` field.
struct FoodDraft: Codable, Sendable {
    let name: String; let brand: String; let aliases: [String]; let category: String; let serving_g: Double; let serving_desc: String
    let per100: Vec; let groups100: Vec; let hazards100: [HazardPer100]; let nova_group: Int?; let ingredients: String
    let label_fields: [String]; let confidence: String; let sources: [SourceLink]; let notes: String; let source: String; let provider: String
}

extension FoodDraft {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        name = try c.or("name", "")
        brand = try c.or("brand", "")
        if let list = try? c.decodeIfPresent([String].self, forKey: "aliases") {
            aliases = list
        } else {
            aliases = FoodInput.splitAliases(try c.or("aliases", ""))
        }
        category = try c.or("category", "other")
        serving_g = try c.or("serving_g", 100)
        serving_desc = try c.or("serving_desc", "")
        per100 = try c.or("per100", [:])
        groups100 = try c.or("groups100", [:])
        hazards100 = try c.or("hazards100", [])
        nova_group = try c.flexIntIfPresent("nova_group")
        ingredients = try c.or("ingredients", "")
        label_fields = try c.or("label_fields", [])
        confidence = try c.or("confidence", "medium")
        sources = try c.or("sources", [])
        notes = try c.or("notes", "")
        source = try c.or("source", "ai_estimate")
        provider = try c.or("provider", "")
    }
}

struct FoodAIRequest: Encodable, Sendable { let name: String; let brand: String; let note: String; let photos: [String] }
/// `POST /foods/{id}/item`; `grams == nil` encodes `{}` and the server uses `serving_g ?? 100`.
struct FoodItemRequest: Encodable, Sendable { let grams: Double? }
struct FromItemRequest: Encodable, Sendable { let item: DraftItem; let name: String; let brand: String; let aliases: [String]; let serving_g: Double; let serving_desc: String; let source_urls: [SourceLink]; let visibility: String }
