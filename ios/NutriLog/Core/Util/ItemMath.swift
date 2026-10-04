import Foundation

// MARK: - Client-side item math (meals §4.1–4.4, web `ItemEditor.tsx` / `LogMeal.tsx`)
// All scaling is linear and unrounded (rounding is display-only). Every division is guarded and every
// non-finite result becomes 0, so a draft can never carry NaN/∞ into a request body.

enum ItemMath {
    /// Grams change (meals §4.1). `grams ≤ 0` or non-finite leaves the item unchanged.
    /// Per-portion values are recomputed from `per100`; hazard notes are dropped; `food_id` is kept on purpose.
    static func rescale(_ item: DraftItem, grams: Double) -> DraftItem {
        guard grams.isFinite, grams > 0 else { return item }
        let f = grams / 100
        var it = item
        it.amount_g = grams
        it.amount_desc = fmt(grams) + " g"
        it.nutrients = scaled(item.per100.nutrients, f)
        it.groups = scaled(item.per100.groups, f)
        it.hazards = item.per100.hazards.map { HazardEntry(key: $0.key, amount: finite($0.amount_per_100g * f), note: nil) }
        return it
    }

    /// Saved meal item → editable draft with derived per-100 g values (meals §4.2). `save_suggested = false`.
    static func toDraft(_ item: MealItem) -> DraftItem {
        let f = item.amount_g > 0 ? 100 / item.amount_g : 1
        let per100 = Per100(
            nutrients: scaled(item.nutrients, f),
            groups: scaled(item.groups, f),
            hazards: item.hazards.map { HazardPer100(key: $0.key, amount_per_100g: finite($0.amount * f), note: nil) }
        )
        return DraftItem(
            name: item.name, amount_g: item.amount_g, amount_desc: item.amount_desc, food_id: item.food_id,
            category: item.category, cooking_method: item.cooking_method, nova_group: item.nova_group,
            confidence: item.confidence, nutrients: item.nutrients, groups: item.groups, hazards: item.hazards,
            notes: item.notes, per100: per100, save_suggested: false, saved_food_id: nil
        )
    }

    /// Direct nutrient edit (meals §4.3): value clamped to ≥ 0, per-100 g kept in sync, **`food_id` unlinked**.
    static func setNutrient(_ item: DraftItem, key: String, value: Double) -> DraftItem {
        let v = clamped(value)
        var it = item
        it.food_id = nil
        it.nutrients[key] = v
        it.per100.nutrients[key] = finite(v * 100 / portion(item))
        return it
    }

    /// Direct food-group edit (meals §4.3): same rules as `setNutrient`.
    static func setGroup(_ item: DraftItem, key: String, value: Double) -> DraftItem {
        let v = clamped(value)
        var it = item
        it.food_id = nil
        it.groups[key] = v
        it.per100.groups[key] = finite(v * 100 / portion(item))
        return it
    }

    /// Adds a flag hazard covering the whole portion: `{key, amount: amount_g}` and `{key, amount_per_100g: 100}`; unlinks `food_id`.
    static func addHazard(_ item: DraftItem, key: String) -> DraftItem {
        var it = item
        it.food_id = nil
        it.hazards.append(HazardEntry(key: key, amount: portion(item), note: nil))
        it.per100.hazards.append(HazardPer100(key: key, amount_per_100g: 100, note: nil))
        return it
    }

    /// Removes hazard `index` from both index-aligned arrays; unlinks `food_id` (as the web does, even for a stale index).
    static func removeHazard(_ item: DraftItem, at index: Int) -> DraftItem {
        var it = item
        it.food_id = nil
        if it.hazards.indices.contains(index) { it.hazards.remove(at: index) }
        if it.per100.hazards.indices.contains(index) { it.per100.hazards.remove(at: index) }
        return it
    }

    /// Sum of `nutrients` over all items (the `合计` line, meals §4.4).
    static func totals(_ items: [DraftItem]) -> Vec {
        var out: Vec = [:]
        for item in items {
            for (k, v) in item.nutrients where v.isFinite {
                out[k, default: 0] += v
            }
        }
        return out
    }

    /// Net exercise kcal = (MET − 1) × kg × hours, never negative (body §9.2).
    static func netKcal(met: Double, weightKg: Double, minutes: Double) -> Double { max(0, (met - 1) * weightKg * minutes / 60) }

    // MARK: Private

    /// Web `it.amount_g || 1`.
    private static func portion(_ item: DraftItem) -> Double { item.amount_g.isFinite && item.amount_g > 0 ? item.amount_g : 1 }
    private static func clamped(_ v: Double) -> Double { v.isFinite ? max(0, v) : 0 }
    private static func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
    private static func scaled(_ v: Vec, _ f: Double) -> Vec { v.mapValues { finite($0 * f) } }
}
