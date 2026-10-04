import Foundation

// MARK: - Static vocabularies and zh label maps
// Sources: auth §3.2, §5; meals §1.1–§1.7, §1.12; rep §3.6, §9.1–§9.4, §10.3; web1 §0.6, §4.3 A2; web2 §5.1.5.
// Prefer `app.meta` at runtime for nutrient/hazard/activity definitions; these lists cover ordering and offline labels.

struct MealTypeDef: Sendable, Hashable { let key: String; let zh: String; let defaultTime: String }
struct LabeledKey: Sendable, Hashable { let key: String; let zh: String }
struct ExtraMetric: Sendable, Hashable { let key: String; let zh: String; let unit: String }

enum Sex: String, CaseIterable, Sendable { case male, female
    var zh: String { self == .male ? "男" : "女" } }
enum ActivityLevel: String, CaseIterable, Sendable { case inactive, low_active, active, very_active
    var zh: String { switch self { case .inactive: "久坐"; case .low_active: "轻度活动"; case .active: "活跃"; case .very_active: "非常活跃" } } }
enum Goal: String, CaseIterable, Sendable { case lose, maintain, gain
    var zh: String { switch self { case .lose: "减重"; case .maintain: "维持"; case .gain: "增重" } } }
enum Physiology: String, CaseIterable, Sendable { case none, pregnant, lactating
    var zh: String { switch self { case .none: "无"; case .pregnant: "孕期"; case .lactating: "哺乳期" } } }
enum SodiumMode: String, CaseIterable, Sendable { case cdrr, aha
    var zh: String { self == .cdrr ? "2300 mg（DGA/NASEM）" : "1500 mg（AHA 理想）" } }
enum Nicotine: String, CaseIterable, Sendable { case unknown, never, former_5y, former_1_5y, former_lt1y, ecig, current
    var zh: String { switch self { case .unknown: "不填写（LE8 不计这一项）"; case .never: "从不吸烟"; case .former_5y: "已戒烟 5 年以上"; case .former_1_5y: "已戒烟 1–5 年"; case .former_lt1y: "戒烟不到 1 年"; case .ecig: "使用电子烟"; case .current: "目前吸烟" } } }
enum ShareMode: String, CaseIterable, Sendable { case `private`, `public`, selected
    var zh: String { switch self { case .private: "仅自己"; case .public: "所有成员"; case .selected: "指定成员" } } }
enum ShareDetail: String, CaseIterable, Sendable { case summary, full
    var zh: String { self == .summary ? "仅评分与趋势" : "完整记录（含吃了什么）" } }

extension ActivityLevel {
    /// Web description text (auth §5); `meta.activityLevels[].desc` carries the same text at runtime.
    var desc: String {
        switch self {
        case .inactive: "办公室工作，几乎不运动（PAL 1.0–1.53）"
        case .low_active: "每天步行约 30–60 分钟或少量运动（PAL 1.53–1.68）"
        case .active: "每天中等强度运动约 1 小时（PAL 1.68–1.85）"
        case .very_active: "体力劳动或每天高强度训练（PAL 1.85–2.5）"
        }
    }
}

enum Vocab {
    /// 43 nutrient keys in the server's display order (meals §1.1, rep §9.1).
    static let nutrientOrder: [String] = [
        "energy_kcal", "protein_g", "carb_g", "fat_g", "water_g",
        "fiber_g", "sugars_g", "added_sugars_g",
        "sat_fat_g", "trans_fat_g", "mufa_g", "pufa_g", "linoleic_g", "ala_g", "epa_dha_g", "cholesterol_mg",
        "sodium_mg", "potassium_mg", "calcium_mg", "iron_mg", "magnesium_mg", "phosphorus_mg", "zinc_mg", "copper_mg",
        "manganese_mg", "selenium_ug", "iodine_ug",
        "vit_a_ug", "vit_c_mg", "vit_d_ug", "vit_e_mg", "vit_k_ug", "thiamin_mg", "riboflavin_mg", "niacin_mg",
        "pantothenic_mg", "vit_b6_mg", "biotin_ug", "folate_ug", "vit_b12_ug", "choline_mg",
        "caffeine_mg", "alcohol_g",
    ]
    /// 22 food-group keys (meals §1.2, rep §9.2).
    static let foodGroupOrder: [String] = [
        "fruit_total_cup", "fruit_whole_cup", "veg_total_cup", "veg_dark_green_cup", "legumes_cup",
        "grains_whole_oz", "grains_refined_oz", "dairy_cup", "protein_total_oz", "seafood_oz", "plant_protein_oz",
        "red_meat_g", "processed_meat_g", "poultry_g", "fruit_veg_g", "berries_cup",
        "olive_oil_g", "butter_cream_g", "cheese_g", "nuts_g", "sweets_serv", "ssb_ml",
    ]
    /// Item editor default list, with the `显示全部 43 项` toggle for the rest (meals §1.1).
    static let itemEditorMainNutrients: [String] = [
        "energy_kcal", "protein_g", "carb_g", "fat_g", "sat_fat_g", "trans_fat_g", "sugars_g", "added_sugars_g",
        "fiber_g", "sodium_mg", "cholesterol_mg", "caffeine_mg", "alcohol_g",
    ]
    /// Food-library editor default per-100 g list (meals §1.1, web2 §5.9.4).
    static let foodEditorMainNutrients: [String] = [
        "energy_kcal", "protein_g", "fat_g", "sat_fat_g", "trans_fat_g", "carb_g", "sugars_g", "added_sugars_g",
        "fiber_g", "sodium_mg",
    ]
    /// Nutrient group headings (web `GROUP_ZH`, rep §9.1).
    static let nutrientGroupZh: [String: String] = [
        "energy": "能量", "macro": "宏量营养素", "carb": "碳水与糖", "fat": "脂肪酸",
        "mineral": "矿物质", "vitamin": "维生素", "other": "其他",
    ]
    /// Group order for section headers.
    static let nutrientGroupOrder: [String] = ["energy", "macro", "carb", "fat", "mineral", "vitamin", "other"]
    /// `MEAL_TYPES` (meals §1.6, web1 §0.6).
    static let mealTypes: [MealTypeDef] = [
        MealTypeDef(key: "breakfast", zh: "早餐", defaultTime: "08:00"),
        MealTypeDef(key: "lunch", zh: "午餐", defaultTime: "12:30"),
        MealTypeDef(key: "dinner", zh: "晚餐", defaultTime: "18:30"),
        MealTypeDef(key: "snack", zh: "加餐", defaultTime: "15:30"),
        MealTypeDef(key: "drink", zh: "饮品", defaultTime: "10:00"),
        MealTypeDef(key: "other", zh: "其他", defaultTime: "12:00"),
    ]
    /// `CATEGORY_ZH` in picker order (meals §1.3, web1 §0.6).
    static let categories: [LabeledKey] = [
        LabeledKey(key: "staple", zh: "主食"),
        LabeledKey(key: "vegetable", zh: "蔬菜"),
        LabeledKey(key: "fruit", zh: "水果"),
        LabeledKey(key: "meat", zh: "肉类"),
        LabeledKey(key: "poultry", zh: "禽肉"),
        LabeledKey(key: "seafood", zh: "水产"),
        LabeledKey(key: "egg", zh: "蛋类"),
        LabeledKey(key: "dairy", zh: "奶制品"),
        LabeledKey(key: "soy_legume", zh: "豆制品/豆类"),
        LabeledKey(key: "nut_seed", zh: "坚果种子"),
        LabeledKey(key: "snack", zh: "零食"),
        LabeledKey(key: "dessert", zh: "甜点"),
        LabeledKey(key: "beverage", zh: "饮品"),
        LabeledKey(key: "alcohol", zh: "酒类"),
        LabeledKey(key: "condiment", zh: "调味品"),
        LabeledKey(key: "fast_food", zh: "速食/快餐"),
        LabeledKey(key: "dish", zh: "菜肴"),
        LabeledKey(key: "supplement", zh: "补充剂"),
        LabeledKey(key: "other", zh: "其他"),
    ]
    /// `NOVA_ZH` (meals §1.4). The picker's extra empty option is `未知` (nil).
    static let novaZh: [Int: String] = [1: "未加工", 2: "烹饪原料", 3: "加工食品", 4: "超加工"]
    /// Food-library `source` labels (`SOURCE_ZH`, meals §1.12).
    static let foodSourceZh: [String: String] = [
        "label": "营养标签", "ai_search": "AI 联网查询", "ai_estimate": "AI 估算", "manual": "手动录入",
    ]
    /// The 12 hazards with `dose.from == "flag"`, in `meta.hazards` order (meals §1.7): the only ones offered in "补充风险标记".
    static let flagHazardKeys: [String] = [
        "salted_fish_cantonese", "areca_nut", "aflatoxin_risk", "high_temp_meat", "smoked_food", "acrylamide",
        "pickled_vegetables", "very_hot_beverage", "bracken_fern", "high_mercury_fish", "hijiki", "aspartame",
    ]
    /// `ACTIVE_SRC` for the energy card hint (web1 §4.3 A2), keyed by `EnergyResult.activeSource`.
    static let activeSourceZh: [String: String] = [
        "device": "手机/手表活动能量", "steps": "按步数估算", "exercise": "手动记录的运动", "none": "无活动数据",
    ]
    /// DRI INTAKE key order, 31 keys (rep §9.4).
    static let intakeOrder: [String] = [
        "protein_g", "carb_g", "fiber_g", "linoleic_g", "ala_g", "water_g", "vit_a_ug", "vit_c_mg", "vit_d_ug", "vit_e_mg",
        "vit_k_ug", "thiamin_mg", "riboflavin_mg", "niacin_mg", "vit_b6_mg", "folate_ug", "vit_b12_ug", "pantothenic_mg",
        "biotin_ug", "choline_mg", "calcium_mg", "copper_mg", "iodine_ug", "iron_mg", "magnesium_mg", "manganese_mg",
        "phosphorus_mg", "selenium_ug", "zinc_mg", "potassium_mg", "sodium_mg",
    ]
    /// DRI UPPER key order, 17 keys (rep §9.4).
    static let upperOrder: [String] = [
        "vit_a_ug", "vit_c_mg", "vit_d_ug", "vit_e_mg", "niacin_mg", "vit_b6_mg", "folate_ug", "choline_mg", "calcium_mg",
        "copper_mg", "iodine_ug", "iron_mg", "magnesium_mg", "manganese_mg", "phosphorus_mg", "selenium_ug", "zinc_mg",
    ]
    /// The 11 MAR micronutrients in `MarResult` order (rep §3.6).
    static let marNutrients: [String] = [
        "vit_a_ug", "thiamin_mg", "riboflavin_mg", "niacin_mg", "vit_b6_mg", "folate_ug", "vit_b12_ug", "vit_c_mg",
        "calcium_mg", "iron_mg", "zinc_mg",
    ]
    /// Profile time-zone picker (auth §5); prepend the current value when it is not listed.
    static let timezones: [String] = [
        "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Singapore", "Europe/London",
        "Europe/Berlin", "America/New_York", "America/Chicago", "America/Los_Angeles", "Australia/Sydney",
    ]
    /// Avatar palette (auth §3.2).
    static let avatarColors: [String] = ["#2f7d5b", "#3b6fb6", "#b5523b", "#7a5bb5", "#b58a2f", "#2f8c93", "#b53b72", "#5b7a2f"]
    /// Spoken names for the avatar palette (VoiceOver only; the web uses the bare hex as aria-label).
    static let avatarColorNames: [String: String] = [
        "#2f7d5b": "墨绿", "#3b6fb6": "蓝", "#b5523b": "砖红", "#7a5bb5": "紫",
        "#b58a2f": "土黄", "#2f8c93": "青", "#b53b72": "玫红", "#5b7a2f": "橄榄绿",
    ]
    static let goalRates: [Double] = [0.25, 0.5, 0.75, 1]
    /// `其他指标` of the Trends nutrient explorer (rep §10.3, web2 §5.1.5 (4)), in picker order.
    static let trendsExtraMetrics: [ExtraMetric] = [
        ExtraMetric(key: "macro:satFat", zh: "饱和脂肪供能比", unit: "%"),
        ExtraMetric(key: "macro:addedSugar", zh: "添加糖供能比", unit: "%"),
        ExtraMetric(key: "macro:protein", zh: "蛋白质供能比", unit: "%"),
        ExtraMetric(key: "upf", zh: "超加工食品供能比", unit: "%"),
        ExtraMetric(key: "group:processed_meat_g", zh: "加工肉", unit: "g"),
        ExtraMetric(key: "group:red_meat_g", zh: "红肉", unit: "g"),
        ExtraMetric(key: "group:veg_total_cup", zh: "蔬菜", unit: "杯当量"),
        ExtraMetric(key: "group:fruit_total_cup", zh: "水果", unit: "杯当量"),
        ExtraMetric(key: "group:grains_whole_oz", zh: "全谷物", unit: "盎司当量"),
        ExtraMetric(key: "hei", zh: "HEI-2020 分数", unit: "分"),
        ExtraMetric(key: "steps", zh: "步数", unit: "步"),
        ExtraMetric(key: "hazard", zh: "风险物警示数", unit: "项"),
        ExtraMetric(key: "mar", zh: "微量营养素 MAR", unit: "分"),
    ]
    static func mealZh(_ key: String) -> String { mealTypes.first { $0.key == key }?.zh ?? key }
    static func categoryZh(_ key: String?) -> String? { guard let key else { return nil }; return categories.first { $0.key == key }?.zh ?? key }
    static func guessMealType(hour: Int) -> String { hour < 10 ? "breakfast" : hour < 14 ? "lunch" : hour < 17 ? "snack" : hour < 21 ? "dinner" : "snack" }
    static func bodySourceLabel(_ source: String) -> String { switch source { case "manual": ""; case "profile": "建档"; case "ai": "AI 识别"; default: "Apple 健康" } }
    static func activitySourceLabel(_ source: String) -> String { switch source { case "manual": "手动"; case "apple_shortcut": "iPhone 快捷指令"; case "ai_screenshot": "AI 识别"; case "healthkit": "Apple 健康"; default: "“健康”App 导出" } }
    static func iarcLabel(_ group: String) -> String { group == "—" ? "非致癌" : "IARC \(group) 类" }

    /// `guessMealType` from an `HH:MM` string (web `guessMealType(time)`); unparsable input gives `snack`, like the web's NaN hour.
    static func guessMealType(time: String) -> String {
        guard let hour = Int(time.prefix(2)) else { return "snack" }
        return guessMealType(hour: hour)
    }
    /// `NOVA {n} · {zh}` chip text (meals §1.4).
    static func novaLabel(_ group: Int) -> String {
        guard let zh = novaZh[group] else { return "NOVA \(group)" }
        return "NOVA \(group) · \(zh)"
    }
    /// Unit affix used by the item editor for food groups: `g` stays `g`, others use their first character (meals §1.2).
    static func groupUnitAffix(_ unit: String) -> String { unit == "g" ? "g" : String(unit.prefix(1)) }
}
