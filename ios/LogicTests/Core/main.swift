import Foundation

// WP0-A Core logic tests: fmt / Fmt, LocalDay, Timestamps, ItemMath, Vocab, DiskCache, Debouncer,
// and model decoding/encoding fixtures (absent vs null keys, 0/1 flags, verbatim snake_case keys).

// MARK: - fmt / Fmt (web1 §0.3, web2 §1.5)
section("fmt")
expectEqual(fmt(1568), "1,568", "1568")
expectEqual(fmt(39.2, 1), "39.2", "39.2 d1")
expectEqual(fmt(78, 1), "78", "78 d1 drops trailing zero")
expectEqual(fmt(2.5), "3", "2.5 rounds half away from zero")
expectEqual(fmt(-2.5), "-3", "-2.5 rounds half away from zero")
expectEqual(fmt(-795), "-795", "ASCII minus")
expectEqual(fmt(nil), "—", "nil")
expectEqual(fmt(.nan), "—", "NaN")
expectEqual(fmt(.infinity), "—", "infinity")
expectEqual(fmt(12345.6), "12,346", "grouping + rounding")
expectEqual(fmt(4535), "4,535", "4535")
expectEqual(fmt(10.6, 1), "10.6", "10.6 d1")
expectEqual(fmt(1.5, 1), "1.5", "1.50 d1")
expectEqual(fmt(2.0, 1), "2", "2.0 d1")
expectEqual(fmt(0.125, 2), "0.13", "0.125 d2")
expectEqual(fmt(1200), "1,200", "1200")

section("Fmt")
expectEqual(Fmt.signed(5), "+5", "signed positive")
expectEqual(Fmt.signed(-3), "-3", "signed negative")
expectEqual(Fmt.signed(0), "0", "signed zero has no sign")
expectEqual(Fmt.signed(1.25, 1), "+1.3", "signed d1")
expectEqual(Fmt.signed(nil), "—", "signed nil")
expectEqual(Fmt.compact(12345), "1.2万", "compact ≥ 10000")
expectEqual(Fmt.compact(-25000), "-2.5万", "compact negative")
expectEqual(Fmt.compact(9999), "9,999", "compact < 10000")
expectEqual(Fmt.compact(nil), "—", "compact nil")
expectEqual(Fmt.kcal(1568), "1,568 kcal", "kcal")
expectEqual(Fmt.kcal(nil), "— kcal", "kcal nil")
expectEqual(Fmt.kg(68.25), "68.3 kg", "kg")
expectEqual(Fmt.percent(35.4), "35%", "percent")

// MARK: - LocalDay (web2 §1.4, web1 §0.2)
section("LocalDay")
expectEqual(LocalDay.dateLabel("2026-09-30", today: "2026-09-30"), "今天 · 9月30日 周三", "dateLabel today")
expectEqual(LocalDay.dateLabel("2026-09-29", today: "2026-09-30"), "昨天 · 9月29日 周二", "dateLabel yesterday")
expectEqual(LocalDay.dateLabel("2026-09-28", today: "2026-09-30"), "9月28日 周一", "dateLabel older")
expectEqual(LocalDay.dateLabel("2026-10-01", today: "2026-09-30"), "10月1日 周四", "dateLabel future")
expectEqual(LocalDay.dateLabel("2026-10-04", today: "bad"), "10月4日 周日", "dateLabel invalid today")
expectEqual(LocalDay.weekStart("2026-10-03"), "2026-09-28", "weekStart Saturday → Monday")
expectEqual(LocalDay.weekStart("2026-10-04"), "2026-09-28", "weekStart Sunday → previous Monday")
expectEqual(LocalDay.weekStart("2026-09-28"), "2026-09-28", "weekStart Monday → itself")
expectEqual(LocalDay.weekStart("2027-01-01"), "2026-12-28", "weekStart across years")
expectEqual(LocalDay.monthStart("2026-10-03"), "2026-10-01", "monthStart")
expectEqual(LocalDay.monthEnd("2026-02-10"), "2026-02-28", "monthEnd Feb")
expectEqual(LocalDay.monthEnd("2028-02-01"), "2028-02-29", "monthEnd leap Feb")
expectEqual(LocalDay.monthEnd("2000-02-03"), "2000-02-29", "monthEnd 2000 leap")
expectEqual(LocalDay.monthEnd("1900-02-03"), "1900-02-28", "monthEnd 1900 not leap")
expectEqual(LocalDay.monthEnd("2026-04-15"), "2026-04-30", "monthEnd 30-day month")
expectEqual(LocalDay.monthEnd("2026-12-31"), "2026-12-31", "monthEnd Dec")
expectEqual(LocalDay.addMonths("2026-01-31", 1), "2026-02-28", "addMonths clamps day")
expectEqual(LocalDay.addMonths("2026-10-01", -1), "2026-09-01", "addMonths -1")
expectEqual(LocalDay.addMonths("2026-12-15", 1), "2027-01-15", "addMonths over year end")
expectEqual(LocalDay.addMonths("2026-01-15", -1), "2025-12-15", "addMonths back over year start")
expectEqual(LocalDay.addMonths("2024-02-29", 12), "2025-02-28", "addMonths leap day + 12")
expectEqual(LocalDay.addMonths("2026-03-31", -13), "2025-02-28", "addMonths -13")
expectEqual(LocalDay.addDays("2026-12-31", 1), "2027-01-01", "addDays year end")
expectEqual(LocalDay.addDays("2024-03-01", -1), "2024-02-29", "addDays leap")
expectEqual(LocalDay.addDays("2026-10-03", -1095), "2023-10-04", "addDays −1095 (全部)")
expectEqual(LocalDay.addDays("2026-10-03", 0), "2026-10-03", "addDays 0")
expectEqual(LocalDay.addDays("bad", 1), "bad", "addDays invalid input unchanged")
expectEqual(LocalDay.diffDays("2026-09-01", "2026-10-01"), 30, "diffDays forward")
expectEqual(LocalDay.diffDays("2026-10-01", "2026-09-01"), -30, "diffDays backward")
expectEqual(LocalDay.range("2026-09-29", "2026-10-02"), ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"], "range inclusive")
expectEqual(LocalDay.range("2026-10-02", "2026-09-29"), [], "range start > end")
expectEqual(LocalDay.shortDate("2026-09-04"), "9/4", "shortDate")
check(LocalDay.isValid("2024-02-29"), "isValid leap day")
check(!LocalDay.isValid("2026-02-30"), "isValid rejects 02-30")
check(!LocalDay.isValid("2026-2-3"), "isValid rejects unpadded")
check(!LocalDay.isValid("abcd-ef-gh"), "isValid rejects junk")
check(LocalDay.isValidTime("23:59") && !LocalDay.isValidTime("24:00") && !LocalDay.isValidTime("99:99"), "isValidTime")
expectEqual(LocalDay.weekday("2026-10-04"), 0, "weekday Sunday = 0")
if let shanghai = TimeZone(identifier: "Asia/Shanghai"), let la = TimeZone(identifier: "America/Los_Angeles"), let utc = TimeZone(identifier: "UTC") {
    let instant = Date(timeIntervalSince1970: 1_790_958_600) // 2026-10-02T16:30:00Z
    expectEqual(LocalDay.key(for: instant, in: shanghai), "2026-10-03", "key in Asia/Shanghai")
    expectEqual(LocalDay.key(for: instant, in: utc), "2026-10-02", "key in UTC")
    expectEqual(LocalDay.key(for: instant, in: la), "2026-10-02", "key in America/Los_Angeles")
    expectEqual(LocalDay.hhmm(instant, in: shanghai), "00:30", "hhmm in Asia/Shanghai")
    expectEqual(LocalDay.hhmm(instant, in: utc), "16:30", "hhmm in UTC")
    expectEqual(LocalDay.date(fromKey: "2026-10-03", in: shanghai)?.timeIntervalSince1970, 1_790_956_800, "date(fromKey:) start of day")
    expectNil(LocalDay.date(fromKey: "2026-13-01", in: shanghai), "date(fromKey:) invalid")
} else {
    check(false, "time zones available")
}
check(LocalDay.isValid(LocalDay.deviceToday()), "deviceToday is a valid key")
check(LocalDay.isValidTime(LocalDay.nowHHMM()), "nowHHMM is HH:MM")

// MARK: - Timestamps
section("Timestamps")
expectApprox(Timestamps.iso("2027-10-03T21:38:50.123Z")?.timeIntervalSince1970, 1_822_599_530.123, "iso with ms", tolerance: 1e-3)
expectApprox(Timestamps.iso("2027-10-03T21:38:50Z")?.timeIntervalSince1970, 1_822_599_530, "iso without ms", tolerance: 1e-3)
expectApprox(Timestamps.iso("2026-10-02T22:31:05+08:00")?.timeIntervalSince1970, 1_790_951_465, "iso with offset", tolerance: 1e-3)
expectApprox(Timestamps.sqlite("2026-09-30 08:12:44")?.timeIntervalSince1970, 1_790_755_964, "sqlite UTC", tolerance: 1e-3)
expectApprox(Timestamps.sqlite("1970-01-02 00:00:00")?.timeIntervalSince1970, 86_400, "sqlite epoch + 1 day", tolerance: 1e-3)
expectApprox(Timestamps.sqlite("2027-10-03T21:38:50.123Z")?.timeIntervalSince1970, 1_822_599_530.123, "sqlite accepts ISO", tolerance: 1e-3)
expectApprox(Timestamps.iso("2026-09-30 08:12:44")?.timeIntervalSince1970, 1_790_755_964, "iso accepts SQLite form", tolerance: 1e-3)
expectNil(Timestamps.sqlite(nil), "sqlite nil")
expectNil(Timestamps.sqlite(""), "sqlite empty")
expectNil(Timestamps.sqlite("2026-02-30 00:00:00"), "sqlite impossible day")
expectNil(Timestamps.iso("garbage"), "iso garbage")

// MARK: - ItemMath (meals §4)
section("ItemMath")
let baseItem = DraftItem(
    name: "牛肉面", amount_g: 100, amount_desc: "1 碗", food_id: 7, category: "dish", cooking_method: "煮", nova_group: 3,
    confidence: "high", nutrients: ["energy_kcal": 200, "protein_g": 10], groups: ["red_meat_g": 50],
    hazards: [HazardEntry(key: "acrylamide", amount: 100, note: "炸")], notes: nil,
    per100: Per100(nutrients: ["energy_kcal": 200, "protein_g": 10], groups: ["red_meat_g": 50],
                   hazards: [HazardPer100(key: "acrylamide", amount_per_100g: 100, note: nil)]),
    save_suggested: true, saved_food_id: nil
)
let r150 = ItemMath.rescale(baseItem, grams: 150)
expectEqual(r150.amount_g, 150, "rescale amount_g")
expectEqual(r150.amount_desc, "150 g", "rescale amount_desc")
expectApprox(r150.nutrients.v("energy_kcal"), 300, "rescale energy")
expectApprox(r150.nutrients.v("protein_g"), 15, "rescale protein")
expectApprox(r150.groups.v("red_meat_g"), 75, "rescale group")
expectEqual(r150.hazards, [HazardEntry(key: "acrylamide", amount: 150, note: nil)], "rescale hazards drop notes")
expectEqual(r150.food_id, 7, "rescale keeps food_id")
expectEqual(r150.per100, baseItem.per100, "rescale keeps per100")
expectEqual(r150.save_suggested, true, "rescale keeps save_suggested")
expectEqual(ItemMath.rescale(baseItem, grams: 1200).amount_desc, "1,200 g", "rescale amount_desc grouping")
expectEqual(ItemMath.rescale(baseItem, grams: 0), baseItem, "rescale 0 ignored")
expectEqual(ItemMath.rescale(baseItem, grams: -5), baseItem, "rescale negative ignored")
expectEqual(ItemMath.rescale(baseItem, grams: .nan), baseItem, "rescale NaN ignored")
var infItem = baseItem
infItem.per100.nutrients["sodium_mg"] = .infinity
check(ItemMath.rescale(infItem, grams: 50).nutrients.values.allSatisfy(\.isFinite), "rescale never produces non-finite values")

let mealItem = MealItem(
    id: 812, meal_id: 301, name: "炸鸡", amount_g: 250, nutrients: ["energy_kcal": 500, "sodium_mg": 1000], groups: ["poultry_g": 200],
    hazards: [HazardEntry(key: "acrylamide", amount: 50, note: "油炸")], nova_group: 4, category: "fast_food", amount_desc: "1 份",
    food_id: 12, cooking_method: "炸", confidence: "medium", notes: "按餐馆份量估算"
)
let drafted = ItemMath.toDraft(mealItem)
expectApprox(drafted.per100.nutrients.v("energy_kcal"), 200, "toDraft per100 energy")
expectApprox(drafted.per100.nutrients.v("sodium_mg"), 400, "toDraft per100 sodium")
expectApprox(drafted.per100.groups.v("poultry_g"), 80, "toDraft per100 group")
expectEqual(drafted.per100.hazards, [HazardPer100(key: "acrylamide", amount_per_100g: 20, note: nil)], "toDraft per100 hazards")
expectEqual(drafted.hazards, mealItem.hazards, "toDraft keeps portion hazards (with notes)")
expectEqual(drafted.save_suggested, false, "toDraft save_suggested false")
expectEqual(drafted.food_id, 12, "toDraft keeps food_id")
expectEqual(drafted.amount_desc, "1 份", "toDraft keeps amount_desc")
expectEqual(drafted.nova_group, 4, "toDraft keeps nova_group")
expectEqual(ItemMath.toDraft(MealItem(id: 1, meal_id: 1, name: "x", amount_g: 0, nutrients: ["energy_kcal": 5], groups: [:], hazards: [],
                                      nova_group: nil, category: nil, amount_desc: nil, food_id: nil, cooking_method: nil, confidence: nil, notes: nil)).per100.nutrients,
            ["energy_kcal": 5], "toDraft amount 0 uses factor 1")
expectApprox(ItemMath.rescale(drafted, grams: 125).nutrients.v("energy_kcal"), 250, "toDraft → rescale round trip")

let sodiumEdit = ItemMath.setNutrient(r150, key: "sodium_mg", value: 300)
expectApprox(sodiumEdit.nutrients.v("sodium_mg"), 300, "setNutrient value")
expectApprox(sodiumEdit.per100.nutrients.v("sodium_mg"), 200, "setNutrient per100 = v × 100 / g")
expectNil(sodiumEdit.food_id, "setNutrient unlinks food_id")
expectApprox(ItemMath.setNutrient(r150, key: "fat_g", value: -4).nutrients.v("fat_g"), 0, "setNutrient clamps negative")
expectApprox(ItemMath.setNutrient(r150, key: "fat_g", value: .nan).nutrients.v("fat_g"), 0, "setNutrient NaN → 0")
var zeroGram = baseItem
zeroGram.amount_g = 0
expectApprox(ItemMath.setNutrient(zeroGram, key: "fat_g", value: 3).per100.nutrients.v("fat_g"), 300, "setNutrient amount 0 uses g = 1")
let groupEdit = ItemMath.setGroup(r150, key: "red_meat_g", value: 30)
expectApprox(groupEdit.groups.v("red_meat_g"), 30, "setGroup value")
expectApprox(groupEdit.per100.groups.v("red_meat_g"), 20, "setGroup per100")
expectNil(groupEdit.food_id, "setGroup unlinks food_id")
let added = ItemMath.addHazard(r150, key: "smoked_food")
expectEqual(added.hazards.last, HazardEntry(key: "smoked_food", amount: 150, note: nil), "addHazard portion = amount_g")
expectEqual(added.per100.hazards.last, HazardPer100(key: "smoked_food", amount_per_100g: 100, note: nil), "addHazard per100 = 100")
expectNil(added.food_id, "addHazard unlinks food_id")
let removed = ItemMath.removeHazard(added, at: 0)
expectEqual(removed.hazards.map(\.key), ["smoked_food"], "removeHazard portion array")
expectEqual(removed.per100.hazards.map(\.key), ["smoked_food"], "removeHazard per100 array")
expectNil(removed.food_id, "removeHazard unlinks food_id")
expectEqual(ItemMath.removeHazard(r150, at: 9).hazards, r150.hazards, "removeHazard stale index keeps hazards")
let totals = ItemMath.totals([r150, drafted])
expectApprox(totals.v("energy_kcal"), 800, "totals energy")
expectApprox(totals.v("protein_g"), 15, "totals protein")
expectApprox(totals.v("sodium_mg"), 1000, "totals sodium")
expectEqual(ItemMath.totals([]), [:], "totals empty")
expectApprox(ItemMath.netKcal(met: 9.3, weightKg: 70, minutes: 45), 435.75, "netKcal")
expectApprox(ItemMath.netKcal(met: 0.5, weightKg: 70, minutes: 45), 0, "netKcal never negative")

// MARK: - Vocab
section("Vocab")
expectEqual(Vocab.nutrientOrder.count, 43, "43 nutrients")
expectEqual(Set(Vocab.nutrientOrder).count, 43, "nutrients unique")
expectEqual(Vocab.foodGroupOrder.count, 22, "22 food groups")
expectEqual(Set(Vocab.foodGroupOrder).count, 22, "food groups unique")
expectEqual(Vocab.itemEditorMainNutrients.count, 13, "item editor main list")
expectEqual(Vocab.foodEditorMainNutrients.count, 10, "food editor main list")
expectEqual(Vocab.intakeOrder.count, 31, "INTAKE order")
expectEqual(Vocab.upperOrder.count, 17, "UPPER order")
expectEqual(Vocab.marNutrients.count, 11, "MAR nutrients")
expectEqual(Vocab.flagHazardKeys.count, 12, "flag hazards")
expectEqual(Vocab.categories.count, 19, "categories")
expectEqual(Vocab.mealTypes.count, 6, "meal types")
expectEqual(Vocab.timezones.count, 11, "time zones")
expectEqual(Vocab.avatarColors.count, 8, "avatar colours")
expectEqual(Vocab.trendsExtraMetrics.count, 13, "trends extra metrics")
expectEqual(Vocab.nutrientGroupZh.count, 7, "nutrient group headings")
let nutrientSet = Set(Vocab.nutrientOrder)
check(Set(Vocab.intakeOrder).isSubset(of: nutrientSet), "INTAKE keys are nutrients")
check(Set(Vocab.upperOrder).isSubset(of: nutrientSet), "UPPER keys are nutrients")
check(Set(Vocab.marNutrients).isSubset(of: nutrientSet), "MAR keys are nutrients")
check(Set(Vocab.itemEditorMainNutrients + Vocab.foodEditorMainNutrients).isSubset(of: nutrientSet), "editor keys are nutrients")
check(TimeZone(identifier: Vocab.timezones[0]) != nil && Vocab.timezones.allSatisfy { TimeZone(identifier: $0) != nil }, "time zones are valid IANA ids")
expectEqual(Vocab.mealZh("lunch"), "午餐", "mealZh")
expectEqual(Vocab.mealZh("brunch"), "brunch", "mealZh unknown passthrough")
expectEqual(Vocab.categoryZh("fast_food"), "速食/快餐", "categoryZh")
expectNil(Vocab.categoryZh(nil), "categoryZh nil")
expectEqual([9, 10, 13, 14, 16, 17, 20, 21].map { Vocab.guessMealType(hour: $0) },
            ["breakfast", "lunch", "lunch", "snack", "snack", "dinner", "dinner", "snack"], "guessMealType")
expectEqual(Vocab.guessMealType(time: "07:45"), "breakfast", "guessMealType(time:)")
expectEqual(Vocab.iarcLabel("2A"), "IARC 2A 类", "iarcLabel")
expectEqual(Vocab.iarcLabel("—"), "非致癌", "iarcLabel non-carcinogen")
expectEqual(Vocab.novaLabel(4), "NOVA 4 · 超加工", "novaLabel")
expectEqual(Vocab.groupUnitAffix("杯当量"), "杯", "group unit affix")
expectEqual(Vocab.groupUnitAffix("ml"), "m", "group unit affix ml")

// MARK: - Model decoding (absent vs null, 0/1 flags, verbatim keys)
section("DayResponse")
let dayJSON = #"""
{
  "date": "2026-10-03",
  "indices": {
    "windowDays": 7, "loggedDays": 1, "mepa": null,
    "le8": { "score": null, "category": null, "available": 0,
             "components": [ { "key": "sleep", "zh": "睡眠", "points": null, "value": "—", "rule": "7–<9 小时 100", "missing": "填写或同步睡眠时长" } ] },
    "wcrf": { "score": 0, "max": 0, "components": [ { "key": "upf", "zh": "少吃快餐和高脂高糖高淀粉的加工食品", "points": null, "max": 0, "detail": "超加工食品供能 12%（仅展示）", "rule": "不计分" } ] },
    "pa": { "le8MinPerWeek": null, "mvpaMinPerWeek": null, "strengthDays": 0 },
    "sleepHours": null
  },
  "score": {
    "date": "2026-10-03", "hasData": true, "score": 62.5,
    "total": { "score": 70.2, "parts": [
        { "key": "hei", "zh": "膳食质量", "weight": 50, "score": 62.5, "points": 31.25, "note": "HEI-2020 总分" },
        { "key": "activity", "zh": "身体活动", "weight": 20, "score": null, "points": null, "note": "没有运动或步数记录" } ],
      "missing": ["身体活动"] },
    "categories": [ { "key": "hei", "zh": "膳食质量 HEI-2020", "score": 62.5, "source": "hei_2020", "note": "美国人平均 58 分" } ],
    "items": [
      { "key": "hei_sodium", "category": "hei", "zh": "钠", "value": 1.9, "unit": "g/1000kcal", "targetText": "≤ 1.1 得满分，≥ 2 得 0（g/1000kcal）",
        "status": "warn", "score": 0.6, "points": 6, "maxPoints": 10, "message": "钠 1.90 g/1000kcal：得 6.0/10", "sources": ["hei_2020"] },
      { "key": "sodium_mg", "category": "moderation", "zh": "钠", "value": 2300.5, "unit": "mg", "targetText": "≤ 2,300 mg（理想 ≤ 1,500）",
        "ideal": 1500, "limit": 2300, "status": "bad", "score": 0.69, "points": 0, "maxPoints": 0, "message": "钠 2,301 mg", "sources": ["nasem_na_k"] },
      { "key": "future_item", "category": "moderation", "zh": "新指标", "value": 1, "unit": "", "targetText": "",
        "status": "brand_new_status", "score": 1, "points": 0, "maxPoints": 0, "message": "", "sources": [] }
    ],
    "hei": null, "mar": null, "hazards": [],
    "energy": { "intake": 1568, "resting": 1620, "restingSource": "device", "active": 412.3, "activeSource": "device",
                "exerciseKcal": 480, "tef": 225.8, "tdee": 2258.1, "method": "measured", "target": 2258.1, "balance": -690.1 },
    "totals": { "energy_kcal": 1568, "sodium_mg": 2300.5 },
    "groups": { "red_meat_g": 0 },
    "macroPct": { "protein": 18.2, "carb": 50.1, "fat": 31.7, "satFat": 9.9, "addedSugar": 4.1, "alcohol": 0 },
    "upfPct": 12.5, "mealCount": 2, "itemCount": 3, "fastFoodMeals": 0,
    "completeness": { "level": "partial", "note": "记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考" },
    "top": { "issues": [], "wins": [] },
    "weightKg": 70.2, "weighedToday": null
  },
  "targets": {
    "date": "2026-10-03", "age": 30, "sex": "male", "lifeStage": "m19_30", "lifeStageZh": "男 19–30 岁", "physiology": "none", "sensitive": false,
    "weightKg": 70, "heightCm": 175, "bmi": 22.857, "bmiCategory": { "key": "normal", "zh": "正常" }, "referenceWeightKg": 70,
    "bmr": 1648.75, "eer": 2754.87, "eerMethod": "NASEM 2023 EER", "goal": "maintain", "goalDeltaKcal": 0, "energyTarget": 2755, "energyFloor": 1649,
    "protein": { "rdaG": 56, "idealLowG": 84, "idealHighG": 112, "perKgRda": 0.8 },
    "intake": { "fiber_g": { "key": "fiber_g", "value": 39, "kind": "AI", "source": "nasem_dri", "note": "14 g / 1000 kcal × 你的能量目标" },
                "vit_c_mg": { "key": "vit_c_mg", "value": 90, "kind": "RDA", "source": "nasem_dri" } },
    "upper": { "vit_c_mg": { "value": 2000, "appliesToTotal": true } },
    "limits": { "sodium_mg": { "key": "sodium_mg", "zh": "钠", "unit": "mg", "ideal": 1500, "limit": 2300, "idealSource": "aha_sodium", "limitSource": "nasem_na_k", "note": "上限为 CDRR，与 DGA 一致" },
                "sat_fat_pct": { "key": "sat_fat_pct", "zh": "饱和脂肪供能比", "unit": "% 能量", "ideal": 8, "limit": 10, "idealSource": "hei_2020", "limitSource": "dga_2025" } },
    "amdr": { "protein": [10, 35], "carb": [45, 65], "fat": [20, 35] },
    "addedSugarPerMealG": 10, "aspartameAdiMg": 2800
  },
  "meals": [
    { "id": 301, "date": "2026-10-03", "time": "12:30", "meal_type": "lunch", "description": "中午一碗牛肉面加一个卤蛋",
      "photos": ["3f9a0000000000000000c1.jpg"], "ai_summary": "",
      "items": [ { "id": 812, "meal_id": 301, "name": "牛肉面", "amount_g": 450,
                   "nutrients": { "energy_kcal": 650.5, "sodium_mg": 2100 }, "groups": { "red_meat_g": 60 },
                   "hazards": [ { "key": "acrylamide", "amount": 80, "note": "" }, { "key": "smoked_food", "amount": 10 }, { "key": "pickled_vegetables", "fraction": 0.1 } ],
                   "nova_group": 3, "category": "dish", "amount_desc": "1 大碗 (450 g)", "food_id": null, "cooking_method": "煮", "confidence": "medium", "notes": null } ] },
    { "id": 302, "date": "2026-10-03", "time": "09:12", "meal_type": "drink", "description": "饮水", "photos": [], "ai_summary": null,
      "items": [ { "id": 900, "meal_id": 302, "name": "饮用水", "amount_g": 750, "nutrients": { "water_g": 750 }, "groups": {}, "hazards": [],
                   "nova_group": 1, "category": "beverage", "amount_desc": "750 ml", "food_id": null, "cooking_method": null, "confidence": "high", "notes": null } ] }
  ],
  "activity": { "user_id": 3, "date": "2026-10-03", "steps": 8532.5, "active_kcal": null, "resting_kcal": 1620, "distance_km": null,
                "exercise_min": 35, "source": "manual", "updated_at": "2026-10-03 01:02:03", "sleep_hours": 7.25 },
  "exercises": [
    { "id": 1, "user_id": 3, "date": "2026-10-03", "time": "18:05", "description": "户外跑步", "activity_key": "run_10kmh", "met": 9.3,
      "duration_min": 45, "distance_km": 7.4, "kcal": 436, "in_device": 1, "source": "manual", "created_at": "2026-10-03 10:05:00", "avg_hr": 152, "device_kcal": 480 },
    { "id": 2, "user_id": 3, "date": "2026-10-03", "time": "20:00", "description": "游泳", "activity_key": null, "met": 8,
      "duration_min": 30, "distance_km": null, "kcal": 245, "in_device": true, "source": "ai", "avg_hr": null, "device_kcal": null },
    { "id": 3, "user_id": 3, "date": "2026-10-03", "time": "21:00", "description": "力量训练", "activity_key": "strength_moderate", "met": 3.5,
      "duration_min": 20, "distance_km": null, "kcal": 58, "in_device": 0, "source": "healthkit", "created_at": "2026-10-03 13:00:00",
      "avg_hr": null, "device_kcal": null, "external_id": "8A1E-UUID", "source_name": "Apple Watch" }
  ],
  "body": [
    { "id": 10, "user_id": 3, "date": "2026-10-03", "time": "07:30", "weight_kg": null, "body_fat_pct": null, "waist_cm": null, "note": null,
      "source": "manual", "created_at": "2026-10-03 00:00:00", "sbp": 118, "dbp": 76, "bp_treated": 0 },
    { "id": 11, "user_id": 3, "date": "2026-10-03", "time": "22:00", "weight_kg": 70.2, "body_fat_pct": 21.5, "waist_cm": null, "note": "建档体重",
      "source": "profile", "created_at": "2026-10-03 00:00:00", "sbp": null, "dbp": null, "bp_treated": 1 }
  ],
  "weightTrend": null,
  "full": true
}
"""#
if let day = decodeFixture(DayResponse.self, dayJSON, "decode DayResponse fixture") {
    expectEqual(day.full, true, "full")
    expectNil(day.weightTrend, "weightTrend null")
    expectNil(day.indices.mepa, "mepa null")
    expectNil(day.indices.le8.score, "le8.score null")
    expectNil(day.indices.le8.components.first?.points, "le8 component points null")
    expectEqual(day.indices.wcrf.score, 0, "wcrf score")
    expectNil(day.score.version, "absent version → nil")
    expectNil(day.score.hei, "hei null")
    expectEqual(day.score.mealCount, 2, "mealCount Int")
    expectApprox(day.score.totals.v("sodium_mg"), 2300.5, "totals verbatim snake_case key")
    expectApprox(day.score.totals.v("vit_c_mg"), 0, "missing nutrient reads 0")
    expectNil(day.score.item("hei_sodium")?.target, "absent target → nil")
    expectNil(day.score.item("hei_sodium")?.limit, "absent limit → nil")
    expectEqual(day.score.item("sodium_mg")?.limit, 2300, "present limit")
    expectEqual(day.score.item("sodium_mg")?.status, .bad, "status bad")
    expectEqual(day.score.item("future_item")?.status, .info, "unknown status → info")
    expectNil(day.score.total.parts.last?.points, "composite part points null")
    expectNil(day.targets.intake["vit_c_mg"]?.note, "absent intake note → nil")
    expectEqual(day.targets.intake["fiber_g"]?.note, "14 g / 1000 kcal × 你的能量目标", "present intake note")
    expectNil(day.targets.upper["vit_c_mg"]?.note, "absent upper note")
    expectNil(day.targets.limits["sat_fat_pct"]?.note, "absent limit note")
    expectNil(day.targets.amdr.n6, "absent amdr.n6 → nil")
    expectEqual(day.targets.orderedLimits.map(\.key), ["sodium_mg", "sat_fat_pct"], "orderedLimits follows limitOrder")
    expectEqual(day.targets.orderedIntake.map(\.key), ["fiber_g", "vit_c_mg"], "orderedIntake follows INTAKE order")
    expectEqual(day.targets.energyTarget, 2755, "energyTarget")
    expectEqual(day.meals.count, 2, "meals")
    expectEqual(day.visibleMeals.map(\.id), [301], "water pseudo-meal hidden")
    expectEqual(day.waterMl, 750, "waterMl from water meal")
    expectApprox(day.meals[0].kcal, 650.5, "meal kcal")
    expectEqual(day.meals[0].ai_summary, "", "ai_summary empty string")
    expectNil(day.meals[1].ai_summary, "ai_summary null")
    let hz = day.meals[0].items[0].hazards
    expectEqual(hz.count, 3, "hazard entries")
    expectEqual(hz[0].note, "", "hazard note empty string")
    expectNil(hz[1].note, "hazard note absent → nil")
    expectEqual(hz[2].amount, 0, "legacy hazard without amount → 0")
    expectNil(day.meals[0].items[0].food_id, "food_id null")
    expectNil(day.meals[0].items[0].notes, "item notes null")
    expectEqual(day.activity?.steps, 8532.5, "non-integral steps as Double")
    expectNil(day.activity?.stand_hours, "absent stand_hours → nil")
    expectNil(day.activity?.active_kcal, "null active_kcal → nil")
    expectEqual(day.exercises.map(\.in_device), [1, 1, 0], "in_device: 0/1 ints and a boolean")
    expectEqual(day.exercises.map(\.inDevice), [true, true, false], "inDevice helper")
    expectNil(day.exercises[0].external_id, "external_id absent on pre-v3 rows")
    expectNil(day.exercises[1].created_at, "created_at absent")
    expectEqual(day.exercises[2].source_name, "Apple Watch", "source_name present")
    expectEqual(day.body.map(\.bp_treated), [0, 1], "bp_treated 0/1")
    expectEqual(day.body[1].bpTreated, true, "bpTreated helper")
    expectEqual(day.body[1].weight_kg, 70.2, "body weight")
    // Round trip through the app's own encoder (DiskCache path) keeps every value.
    if let data = expectNoThrow("re-encode DayResponse", { try JSONEncoder().encode(day) }),
       let again = expectNoThrow("re-decode DayResponse", { try JSONDecoder().decode(DayResponse.self, from: data) }) {
        expectEqual(again.exercises.map(\.in_device), [1, 1, 0], "round trip in_device")
        expectEqual(again.meals[0].items[0].hazards, hz, "round trip hazards")
    }
}

section("Account")
let meNoProfile = #"""
{ "user": { "id": 3, "username": "demo", "display_name": "小林", "avatar_color": "#2f7d5b", "share_mode": "selected", "share_detail": "full",
            "api_token_hint": null, "share_with": [5, 7] },
  "profile": null, "today": "2026-10-04", "ai": { "provider": "mock", "model": "offline" },
  "conditions": [ { "key": "hypertension", "zh": "高血压", "effect": "钠上限收紧到 1500 mg（AHA）" } ] }
"""#
if let me = decodeFixture(Me.self, meNoProfile, "decode Me without profile") {
    expectNil(me.profile, "profile null")
    expectEqual(me.user.share_with, [5, 7], "share_with")
    expectNil(me.user.api_token_hint, "api_token_hint null")
    expectEqual(me.ai.isMock, true, "ai.isMock")
}
let meOldProfile = #"""
{ "user": { "id": 3, "username": "demo", "display_name": "小林", "avatar_color": "#2f7d5b", "share_mode": "private", "share_detail": "summary", "api_token_hint": "nl_AbCd…wxyz" },
  "profile": { "sex": "female", "birth_date": "1996-11-02", "height_cm": 163, "weight_kg": 56, "activity_level": "active", "goal": "lose",
               "goal_rate_kg_week": 0.25, "target_weight_kg": null, "physiology": "none", "sodium_mode": "aha", "conditions": ["diabetes"],
               "timezone": "Asia/Tokyo" },
  "today": "2026-10-04", "ai": { "provider": "api", "model": "claude-opus-5-5" }, "conditions": [] }
"""#
if let me = decodeFixture(Me.self, meOldProfile, "decode Me with profile lacking nicotine/secondhand_smoke") {
    expectNil(me.user.share_with, "PublicUser without share_with")
    expectEqual(me.profile?.nicotine, "unknown", "absent nicotine → unknown")
    expectEqual(me.profile?.secondhand_smoke, false, "absent secondhand_smoke → false")
    expectEqual(me.profile?.timezone, "Asia/Tokyo", "timezone")
    expectNil(me.profile?.target_weight_kg, "target_weight_kg null")
    expectEqual(me.profile?.height_cm, 163, "height Double")
}
var profile = Profile.newDefault(timezone: "Asia/Shanghai")
profile.secondhand_smoke = true
profile.target_weight_kg = 60
if let data = expectNoThrow("encode Profile", { try JSONEncoder().encode(profile) }) {
    expectEqual(try? JSONDecoder().decode(Profile.self, from: data), profile, "Profile round trip")
}
if let obj = encodedObject(Profile.newDefault(timezone: "UTC"), "encode default Profile") {
    check(obj["secondhand_smoke"] as? Bool == false, "secondhand_smoke encodes as a real boolean")
    check(obj["birth_date"] as? String == "1995-01-01" && obj["goal_rate_kg_week"] != nil, "snake_case keys verbatim")
}
expectEqual(decodeFixture(Profile.self, #"{"sex":"male","birth_date":"1990-01-01","height_cm":170,"weight_kg":70,"secondhand_smoke":1}"#, "secondhand_smoke 1")?.secondhand_smoke, true, "secondhand_smoke tolerates 1")

if let token = decodeFixture(TokenResponse.self, #"{"ok":true,"token":"nla_x","expires_at":"2027-10-03T21:38:50.123Z"}"#, "register TokenResponse") {
    expectNil(token.user, "register response has no user")
}
if let rows = decodeFixture([SessionRow].self, #"""
[ { "id": 9, "kind": "app", "device_name": "iPhone · 食迹 iOS", "created_at": "2026-10-01 08:00:00", "last_used_at": "2026-10-03 09:00:00", "expires_at": "2027-10-01T08:00:00.000Z", "current": true },
  { "id": 4, "kind": "web", "device_name": null, "created_at": null, "last_used_at": null, "expires_at": "2026-10-30T08:00:00.000Z" } ]
"""#, "sessions") {
    expectEqual(rows.map(\.current), [true, nil], "current present / absent")
    expectNil(rows[1].device_name, "web session device_name null")
}
if let cfg = decodeFixture(AuthConfig.self, #"{"allow_registration":false}"#, "partial AuthConfig") {
    expectEqual(cfg.allow_registration, false, "allow_registration")
    expectEqual(cfg.invite_required, true, "invite_required fallback")
    expectEqual(cfg.min_password, 6, "min_password fallback")
    expectEqual(cfg.features, [], "features fallback")
}
if let users = decodeFixture([CommunityUser].self, #"""
[ { "id": 1, "username": "demo", "display_name": "演示用户", "avatar_color": "#2f7d5b", "is_me": false, "shared_with_me": true, "share_detail": "full",
    "last_log_date": "2026-10-03", "streak": 5, "recent": [ { "date": "2026-10-02", "score": 61 }, { "date": "2026-10-03", "score": null }, { "date": "2026-10-01", "score": 70 } ] },
  { "id": 2, "username": "ahao", "display_name": "阿豪", "avatar_color": "#3b6fb6", "is_me": false, "shared_with_me": false, "share_detail": "none",
    "last_log_date": null, "streak": 0, "recent": [] } ]
"""#, "users") {
    expectApprox(users[0].recentAverage, 65.5, "recentAverage over non-null scores")
    expectNil(users[1].recentAverage, "recentAverage none")
}

section("Drafts & foods")
let mealDraftJob = #"""
{ "id": "8c0e7f5e", "kind": "meal", "status": "done", "error": null,
  "result": { "items": [
      { "name": "鸡蛋", "amount_g": 50, "amount_desc": "1 个", "food_id": 7, "category": "egg", "cooking_method": "", "nova_group": 1, "confidence": "high",
        "nutrients": { "energy_kcal": 72 }, "groups": { "protein_total_oz": 1 }, "hazards": [ { "key": "smoked_food", "amount": 5 } ], "notes": "来自食物库",
        "per100": { "nutrients": { "energy_kcal": 144 }, "groups": { "protein_total_oz": 2 }, "hazards": [ { "key": "smoked_food", "amount_per_100g": 10, "note": "" } ] },
        "save_suggested": false },
      { "name": "奶茶", "amount_g": 500, "amount_desc": "1 杯", "food_id": null, "category": "beverage", "cooking_method": "冲泡", "nova_group": 4, "confidence": "low",
        "nutrients": { "energy_kcal": 300 }, "groups": { "ssb_ml": 500 }, "hazards": [], "notes": "" } ],
    "summary": "早餐", "assumptions": [], "questions": ["奶茶几分糖？"], "sources": [ { "url": "https://example.com/x" } ], "provider": "api", "model": "claude-opus-5-5" } }
"""#
if let job = decodeFixture(Job<MealDraft>.self, mealDraftJob, "Job<MealDraft> done") {
    expectEqual(job.status, .done, "job status")
    let items = job.result?.items ?? []
    expectEqual(items.count, 2, "draft items")
    expectNil(items.first?.hazards.first?.note, "library hazard without note")
    expectEqual(items.first?.per100.hazards.first?.note, "", "per100 hazard note kept")
    expectNil(items.first?.saved_food_id, "saved_food_id absent")
    expectEqual(items.last?.save_suggested, false, "absent save_suggested → false")
    expectApprox(items.last?.per100.nutrients.v("energy_kcal"), 60, "absent per100 derived from portion")
    expectNil(job.result?.sources.first?.title, "source title absent")
    expectEqual(job.result?.questions, ["奶茶几分糖？"], "questions")
    if let first = items.first, let obj = encodedObject(first, "encode DraftItem") {
        check(obj["localId"] == nil && obj["id"] == nil, "localId/id are not encoded")
        check(obj["amount_g"] != nil && obj["per100"] != nil && obj["save_suggested"] != nil, "draft keys verbatim")
    }
    if let second = items.last, let obj = encodedObject(second, "encode unlinked DraftItem") {
        check(obj["food_id"] == nil, "nil food_id is omitted (server treats omitted as null)")
    }
}
if let queued = decodeFixture(Job<MealDraft>.self, #"{"id":"a","kind":"meal","status":"queued","error":null,"result":null}"#, "Job queued") {
    expectEqual(queued.status, .queued, "queued")
    check(queued.result == nil, "queued result nil")
}
if let summaryJob = decodeFixture(Job<WeeklySummary>.self, #"{"id":"b","kind":"summary","status":"done","error":null,"result":null}"#, "summary job with null result") {
    check(summaryJob.result == nil, "done summary job may have null result")
}
if let failed = decodeFixture(Job<ActivityDraft>.self, #"{"id":"c","kind":"activity","status":"error","error":"服务器重启，任务中断，请重试","result":null}"#, "failed job") {
    expectEqual(failed.error, "服务器重启，任务中断，请重试", "job error text")
}
let activityJob = #"""
{ "id": "d", "kind": "activity", "status": "done", "error": null,
  "result": { "date": "2026-10-02", "date_from_image": true,
    "activity": { "steps": 8532, "distance_km": 6.1, "active_kcal": 412, "resting_kcal": null, "exercise_min": 35, "stand_hours": 11, "sleep_hours": 7.5 },
    "body": { "weight_kg": 70.2, "body_fat_pct": null, "sbp": null, "dbp": null },
    "workouts": [ { "description": "游泳", "activity_key": "swim_freestyle_medium", "met": 8.0, "duration_min": 110, "distance_km": 5, "kcal": 543,
                    "notes": "…", "avg_hr": null, "device_kcal": null, "in_device": false },
                  { "description": "跑步", "activity_key": "run_10kmh", "met": 9.3, "duration_min": 30, "distance_km": 0, "kcal": 290, "notes": "",
                    "avg_hr": 150, "device_kcal": 320, "in_device": true } ],
    "notes": "离线规则解析（未配置 AI，无法识别截图）", "provider": "mock", "model": "offline" } }
"""#
if let draft = decodeFixture(Job<ActivityDraft>.self, activityJob, "Job<ActivityDraft>")?.result {
    expectEqual(draft.date_from_image, true, "date_from_image")
    expectNil(draft.activity.resting_kcal, "activity null field")
    expectEqual(draft.workouts.map(\.in_device), [false, true], "workout in_device booleans")
    expectEqual(draft.workouts.last?.distance_km, 0, "distance 0 (not null)")
    if let w = draft.workouts.first, let obj = encodedObject(w, "encode WorkoutDraft") {
        check(obj["localId"] == nil && obj["in_device"] as? Bool == false, "WorkoutDraft encodes in_device as a boolean, no localId")
    }
}
let foodJSON = #"""
{ "id": 12, "owner_id": 3, "visibility": "public", "name": "螺蛳粉", "brand": null, "aliases": "螺狮粉, luosifen，柳州粉",
  "category": null, "serving_g": 335, "serving_desc": "", "per100": { "energy_kcal": 140 }, "groups100": { "veg_total_cup": 0.1 },
  "hazards100": [ { "key": "pickled_vegetables", "amount_per_100g": 4.5, "note": "" } ], "nova_group": 4, "ingredients": null,
  "label_fields": ["energy_kcal"], "source": "label", "source_urls": [ { "title": "官方", "url": "https://example.com", "extra": 1 } ],
  "notes": null, "use_count": 5, "created_at": "2026-09-30 08:12:44", "updated_at": "2026-10-01 10:00:02", "owner_name": "小王", "mine": true }
"""#
if let food = decodeFixture(Food.self, foodJSON, "decode Food") {
    expectEqual(food.aliasList, ["螺狮粉", "luosifen", "柳州粉"], "aliases split on , ， 、")
    let input = food.toInput()
    expectEqual(input.aliases, ["螺狮粉", "luosifen", "柳州粉"], "toInput aliases array")
    expectEqual(input.brand, "", "toInput brand nil → \"\"")
    expectEqual(input.category, "other", "toInput category nil → other")
    expectEqual(input.serving_g, 335, "toInput serving_g")
    expectEqual(input.hazards100, food.hazards100, "toInput keeps hazards100")
    expectEqual(input.groups100, food.groups100, "toInput keeps groups100")
    expectEqual(input.label_fields, ["energy_kcal"], "toInput keeps label_fields")
    expectEqual(input.visibility, "public", "toInput keeps visibility")
    expectEqual(input.notes, "", "toInput notes nil → \"\"")
}
expectEqual(decodeFixture(Food.self, #"{"id":1,"owner_id":1,"visibility":"private","name":"x","aliases":["a","b"],"per100":{},"groups100":{},"hazards100":[],"label_fields":[],"source":"manual","source_urls":[],"use_count":0,"mine":1}"#, "Food with array aliases")?.aliases, "a,b", "array aliases joined")
let blank = FoodInput.blank()
check(blank.name == "" && blank.category == "other" && blank.serving_g == 100 && blank.source == "manual" && blank.visibility == "private"
      && blank.aliases.isEmpty && blank.per100.isEmpty && blank.nova_group == nil && blank.label_fields.isEmpty, "FoodInput.blank defaults")
let foodDraftJSON = #"""
{ "name": "螺蛳粉", "brand": "李子柒", "aliases": ["螺狮粉"], "category": "fast_food", "serving_g": 335, "serving_desc": "1 包 335 g",
  "per100": { "energy_kcal": 140 }, "groups100": {}, "hazards100": [ { "key": "pickled_vegetables", "amount_per_100g": 4.5, "note": "酸笋" } ],
  "nova_group": 4, "ingredients": "米粉", "label_fields": ["energy_kcal"], "confidence": "high",
  "sources": [ { "title": "官网", "url": "https://example.com" } ], "notes": "按包装", "source": "label", "provider": "api" }
"""#
if let fd = decodeFixture(FoodDraft.self, foodDraftJSON, "decode FoodDraft") {
    let input = FoodInput(draft: fd)
    expectEqual(input.source_urls, fd.sources, "FoodInput(draft:) source_urls = sources")
    expectEqual(input.aliases, ["螺狮粉"], "FoodInput(draft:) aliases")
    expectEqual(input.visibility, "private", "FoodInput(draft:) private")
    expectEqual(input.serving_g, 335, "FoodInput(draft:) serving_g")
    if let obj = encodedObject(input, "encode FoodInput") {
        check(obj["aliases"] is [Any], "FoodInput.aliases encodes as an array")
    }
}

section("Trends / standards / sync")
if let trends = decodeFixture(TrendsResponse.self, #"""
{ "start": "2026-10-02", "end": "2026-10-03", "days": [
  { "date": "2026-10-02", "hasData": false, "score": null, "total": null, "categories": {}, "hazardCount": 0, "hei": null, "mar": null,
    "intake": 0, "tdee": 2100, "target": 2100, "exerciseKcal": 0, "energyMethod": "eer", "weight": null, "trend": 70.12, "steps": null, "activeKcal": null,
    "completeness": "none", "totals": {}, "groups": {}, "macroPct": { "protein": 0 }, "upfPct": 0, "statuses": {} },
  { "date": "2026-10-03", "hasData": true, "score": 62.5, "total": 70.2, "categories": { "hei": 62.5, "mar": 71 }, "hazardCount": 1, "hei": 62.5, "mar": 71,
    "intake": 1568, "tdee": 2258, "target": 2258, "exerciseKcal": 480, "energyMethod": "measured", "weight": 70.2, "trend": 70.1, "steps": 8532, "activeKcal": 412.3,
    "completeness": "likely", "totals": { "sodium_mg": 2300.5 }, "groups": { "red_meat_g": 60 }, "macroPct": { "satFat": 9.9 }, "upfPct": 12.5,
    "statuses": { "sodium_mg": "bad", "hei_sodium": "warn", "new_key": "whatever" } } ] }
"""#, "decode TrendsResponse") {
    expectEqual(trends.days[0].categories, [:], "empty categories")
    expectEqual(trends.days[1].categories["mar"], 71, "categories mar")
    expectEqual(trends.days[1].statuses["sodium_mg"], .bad, "statuses bad")
    expectEqual(trends.days[1].statuses["new_key"], .info, "unknown status → info")
}
if let dri = decodeFixture(DriTables.self, #"""
{ "lifeStages": [ { "id": "c1_3", "zh": "儿童 1–3 岁" }, { "id": "m19_30", "zh": "男 19–30 岁" } ],
  "intake": { "vit_d_ug": { "kind": "RDA", "values": [15, null] } },
  "upper": { "vit_a_ug": { "appliesToTotal": false, "note": "UL 仅针对预制维生素 A（视黄醇），不含 β-胡萝卜素", "values": [600, 3000] },
             "vit_c_mg": { "appliesToTotal": true, "values": [400, null] } },
  "sodiumCdrr": [1200, 2300], "proteinPerKg": [1.05, 0.8] }
"""#, "decode DriTables") {
    expectEqual(dri.intake["vit_d_ug"]?.values, [15, nil], "null DRI value → nil")
    expectNil(dri.upper["vit_c_mg"]?.note, "absent upper note")
}
if let meta = decodeFixture(Meta.self, #"""
{ "version": 3,
  "nutrients": [ { "key": "energy_kcal", "zh": "能量", "en": "Energy", "unit": "kcal", "group": "energy", "decimals": 0 },
                 { "key": "protein_g", "zh": "蛋白质", "en": "Protein", "unit": "g", "group": "macro", "decimals": 1, "dv": 50 } ],
  "foodGroups": [ { "key": "red_meat_g", "zh": "红肉(熟重)", "unit": "g", "note": "猪、牛、羊等哺乳动物肌肉，不含加工肉" } ],
  "hazards": [ { "key": "aspartame", "zh": "阿斯巴甜(超过 ADI 时警示)", "en": "Aspartame", "iarc": "2B", "category": "carcinogen", "risk": "r", "detect": "d",
                 "examples": "e", "dose": { "from": "flag", "unit": "mg" }, "refAmount": 1, "aiFlag": true, "sources": ["iarc_aspartame"], "advice": "a" },
               { "key": "red_meat", "zh": "红肉", "en": "Red meat", "iarc": "2A", "category": "carcinogen", "risk": "r", "detect": "d",
                 "examples": "e", "dose": { "from": "group", "key": "red_meat_g", "unit": "g" }, "refAmount": 100, "aiFlag": false, "sources": [], "advice": "a" } ],
  "hazardsInfoOnly": [ { "zh": "咖啡", "iarc": "3", "examples": "咖啡", "why": "无充分证据" } ],
  "hei": [ { "key": "sodium", "zh": "钠", "en": "Sodium", "max": 10, "kind": "moderation", "best": 1.1, "worst": 2.0, "unit": "g/1000kcal", "hint": "少盐少酱油" } ],
  "activities": [ { "key": "stairs", "zh": "爬楼梯", "met": 6.8, "intensity": "vigorous" },
                  { "key": "walk_slow", "zh": "散步 (约 4 km/h)", "met": 3.0, "speedKmh": 4, "code": "17151", "intensity": "moderate" } ],
  "activityLevels": [ { "key": "inactive", "zh": "久坐", "pal": 1.4, "desc": "办公室工作，几乎不运动（PAL 1.0–1.53）" } ],
  "sources": [ { "id": "system", "org": "本系统", "title": "本系统设定的阈值（无权威数值时的保守折中，已在规则中注明）", "year": "2025", "url": "" } ],
  "lifeStages": [ { "id": "c1_3", "zh": "儿童 1–3 岁" } ], "marNutrients": ["vit_a_ug"], "heiUsMean": 58,
  "conditions": [ { "key": "gout", "zh": "痛风 / 高尿酸", "effect": "仅提示" } ] }
"""#, "decode Meta") {
    expectNil(meta.nutrients[0].dv, "absent dv → nil")
    expectEqual(meta.nutrients[1].dv, 50, "present dv")
    expectNil(meta.hazards[0].dose.key, "flag dose has no key")
    expectEqual(meta.hazards[1].dose.key, "red_meat_g", "group dose key")
    expectNil(meta.activities[0].speedKmh, "absent speedKmh")
    expectEqual(meta.sources[0].url, "", "empty source url")
}
if let sync = decodeFixture(HealthSyncResponse.self, #"""
{ "ok": true, "timezone": "Asia/Shanghai", "server_today": "2026-10-03", "timezone_mismatch": false,
  "days": { "upserted": 30, "unchanged": 2, "kept_manual": [ { "date": "2026-10-01", "fields": ["sleep_hours"] } ], "rejected": [ { "date": "2026-13-01", "error": "日期格式不正确" } ] },
  "invalidated_from": null }
"""#, "decode HealthSyncResponse") {
    check(sync.samples == nil && sync.workouts == nil && sync.deleted == nil, "absent sections → nil")
    expectEqual(sync.days?.kept_manual.first?.fields, ["sleep_hours"], "kept_manual")
    expectNil(sync.days?.rejected.first?.uuid, "rejected day has no uuid")
    expectNil(sync.invalidated_from, "invalidated_from null")
}
if let state = decodeFixture(HealthSyncState.self, #"""
{ "timezone": "Asia/Shanghai", "server_today": "2026-10-03",
  "devices": [ { "device_id": "4F0C", "device_name": "小林的 iPhone",
                 "kinds": { "days": { "last_synced_at": "2026-10-03 01:02:03", "min_date": "2026-07-06", "max_date": "2026-10-03", "cursor": null } } } ],
  "counts": { "days": 90, "body": 120, "workouts": 80 }, "legacy_sources": { "apple_shortcut_days": 12, "apple_export_days": 300 } }
"""#, "decode HealthSyncState") {
    expectEqual(state.devices.first?.kinds["days"]?.max_date, "2026-10-03", "kinds.days.max_date")
}
var syncReq = HealthSyncRequest(device_id: "4F0C", device_name: "iPhone", timezone: "Asia/Shanghai", overwrite_manual: false)
syncReq.days = [SyncDay(date: "2026-10-02", steps: 8532, clear: ["sleep_hours"])]
syncReq.samples = [SyncSample(uuid: "u1", type: .blood_pressure, date: "2026-10-02", time: "22:31", sbp: 118, dbp: 76, bp_treated: false)]
if let obj = encodedObject(syncReq, "encode HealthSyncRequest") {
    check(obj["workouts"] == nil && obj["deleted"] == nil && obj["cursors"] == nil, "nil sections omitted")
    let day0 = (obj["days"] as? [[String: Any]])?.first
    check(day0?["steps"] != nil && day0?["sleep_hours"] == nil && (day0?["clear"] as? [String]) == ["sleep_hours"], "SyncDay omits nil fields, keeps clear")
    let sample0 = (obj["samples"] as? [[String: Any]])?.first
    check(sample0?["type"] as? String == "blood_pressure" && sample0?["value"] == nil, "SyncSample raw type, nil value omitted")
}
if let obj = encodedObject(ActivityValues(steps: 100, sleep_hours: 7.5), "encode ActivityValues") {
    expectEqual(Set(obj.keys), ["steps", "sleep_hours"], "ActivityValues encodes only non-nil fields")
}
check(ActivityValues().isEmpty && !ActivityValues(steps: 1).isEmpty, "ActivityValues.isEmpty")
if let data = expectNoThrow("encode EmptyBody", { try JSONEncoder().encode(EmptyBody()) }) {
    expectEqual(String(decoding: data, as: UTF8.self), "{}", "EmptyBody is {}")
}
if let labs = decodeFixture([LabResult].self, #"""
[ { "id": 1, "user_id": 3, "date": "2026-06-05", "total_chol": 190, "hdl": 48, "non_hdl": 142, "ldl": null, "lipid_treated": 0,
    "fasting_glucose": 94, "hba1c": 5.4, "diabetes": 1, "note": null, "created_at": "2026-06-05 00:00:00" },
  { "id": 2, "user_id": 3, "date": "2026-07-05", "total_chol": null, "hdl": null, "non_hdl": null, "ldl": null, "lipid_treated": true,
    "fasting_glucose": null, "hba1c": 6.1, "diabetes": false, "note": "复查" } ]
"""#, "decode LabResult") {
    expectEqual(labs.map(\.lipid_treated), [0, 1], "lipid_treated 0/1 and boolean")
    expectEqual(labs.map(\.hasDiabetes), [true, false], "diabetes flag")
}
if let list = decodeFixture(ActivityList.self, #"{"days":[{"user_id":3,"date":"2026-10-03","steps":null,"active_kcal":412.3,"resting_kcal":null,"distance_km":null,"exercise_min":null,"source":"apple_shortcut","updated_at":"2026-10-03 12:00:00","sleep_hours":null,"stand_hours":null}],"exercises":[]}"#, "decode ActivityList") {
    expectEqual(list.days.first?.source, "apple_shortcut", "activity source")
}
if let period = decodeFixture(ReportListItem.self, #"{"id":5,"period":"week","start_date":"2026-09-21","end_date":"2026-09-27","score":null,"ai_summary":null,"created_at":"2026-09-28 01:00:00"}"#, "decode ReportListItem") {
    check(period.ai_summary == nil && period.score == nil, "report nulls")
}

// MARK: - DiskCache (temporary directory)
section("DiskCache")
let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("nutrilog-logic-\(UUID().uuidString)", isDirectory: true)
if let me = decodeFixture(Me.self, meOldProfile, "fixture for DiskCache") {
    DiskCache.save(me, key: "me", in: cacheDir)
    let loaded = DiskCache.load("me", as: Me.self, in: cacheDir)
    expectEqual(loaded?.profile, me.profile, "DiskCache round trip")
    expectEqual(DiskCache.fileURL("me", in: cacheDir).lastPathComponent, "me.json", "file name")
    expectEqual(DiskCache.fileURL("../x y", in: cacheDir).lastPathComponent, "_.._x_y.json", "key sanitised")
    try? Data("not json".utf8).write(to: DiskCache.fileURL("broken", in: cacheDir))
    expectNil(DiskCache.load("broken", as: Me.self, in: cacheDir), "unreadable file → nil")
    check(!FileManager.default.fileExists(atPath: DiskCache.fileURL("broken", in: cacheDir).path), "unreadable file is removed")
    expectNil(DiskCache.load("missing", as: Me.self, in: cacheDir), "missing file → nil")
    DiskCache.removeAll(in: cacheDir)
    check(!FileManager.default.fileExists(atPath: cacheDir.path), "removeAll deletes the directory")
}

// MARK: - Debouncer
section("Debouncer")
final class Counter { var value = 0 }
let counter = Counter()
let debouncer = Debouncer(.milliseconds(40))
for _ in 0..<5 { debouncer.schedule { counter.value += 1 } }
try? await Task.sleep(for: .milliseconds(400))
expectEqual(counter.value, 1, "only the last of rapid calls runs")
debouncer.schedule { counter.value += 1 }
debouncer.cancel()
try? await Task.sleep(for: .milliseconds(200))
expectEqual(counter.value, 1, "cancel drops the pending action")

let boxed = UncheckedSendable(NSMutableString(string: "a"))
expectEqual(boxed.value as String, "a", "UncheckedSendable wraps a value")

summary()
