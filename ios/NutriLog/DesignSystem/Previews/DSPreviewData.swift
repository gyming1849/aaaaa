import SwiftUI

// MARK: - Fixture data for the design-system #Previews (hand-written, shaped like real `/day` and `/preview` responses).

enum DSPreviewData {
    static let sources: [SourceDef] = [
        SourceDef(id: "iarc_114", org: "IARC / WHO", title: "Monograph 114: Red Meat and Processed Meat", year: "2015/2018",
                  url: "https://www.iarc.who.int/wp-content/uploads/2018/07/pr240_E.pdf"),
        SourceDef(id: "iarc_qa_meat", org: "WHO", title: "Cancer: Carcinogenicity of the consumption of red meat and processed meat", year: "2015",
                  url: "https://www.who.int/news-room/questions-and-answers/item/cancer-carcinogenicity-of-the-consumption-of-red-meat-and-processed-meat"),
        SourceDef(id: "wcrf", org: "WCRF / AICR", title: "Cancer Prevention Recommendations", year: "2018", url: "https://www.wcrf.org/research-policy/library/cancer-prevention-recommendations/"),
        SourceDef(id: "iarc_mono", org: "IARC", title: "Agents classified by the IARC Monographs", year: "2024", url: "https://monographs.iarc.who.int/agents-classified-by-the-iarc/"),
        SourceDef(id: "wcrf2018", org: "WCRF / AICR", title: "Diet, Nutrition, Physical Activity and Cancer", year: "2018", url: "https://www.wcrf.org/diet-activity-and-cancer/"),
        SourceDef(id: "system", org: "本系统", title: "本系统规则", year: "2026", url: ""),
    ]

    static let processedMeatDef = HazardDef(
        key: "processed_meat", zh: "加工肉", en: "Processed meat", iarc: "1", category: "carcinogen",
        risk: "结直肠癌（每天 50 g 风险约增加 18%），胃癌", detect: "经腌制、烟熏、发酵、添加亚硝酸盐等方式加工的肉",
        examples: "培根、火腿、香肠、腊肉、腊肠、午餐肉、热狗、肉松、牛肉干、咸肉",
        dose: HazardDose(from: "group", unit: "g", key: "processed_meat_g"), refAmount: 50, aiFlag: false,
        sources: ["iarc_114", "iarc_qa_meat", "wcrf"], advice: "尽量少吃，WCRF 建议“很少或不吃”。可用新鲜禽肉、鱼、豆制品代替。")

    static let processedMeat = HazardResult(
        key: "processed_meat", zh: "加工肉", iarc: "1", dose: 35, unit: "g", foods: ["火腿三明治", "腊肠炒饭"],
        message: "加工肉 35 g（IARC 1 类致癌物），每天 50 g 结直肠癌风险约增加 18%。", sources: ["iarc_114", "iarc_qa_meat", "wcrf"])

    static let highTempMeat = HazardResult(
        key: "high_temp_meat", zh: "高温烧烤/焦糊肉类", iarc: "2A", dose: 120, unit: "g", foods: [],
        message: "烧烤类食物 120 g，含杂环胺与多环芳烃。", sources: ["system"])

    static let mepa = MepaResult(score: 9, days: 7, items: [
        MepaItem(key: "olive_oil", zh: "橄榄油", criterion: "> 2 份/天（1 份 = 1 汤匙）", value: 0.4, unit: "份/天", met: false),
        MepaItem(key: "leafy", zh: "绿叶蔬菜", criterion: "> 7 份/周（1 份 = 1 杯生 / ½ 杯熟）", value: 8.5, unit: "份/周", met: true),
        MepaItem(key: "other_veg", zh: "其他蔬菜", criterion: "> 2 份/天（1 份 = ½ 杯）", value: 2.6, unit: "份/天", met: true),
        MepaItem(key: "berries", zh: "浆果", criterion: "> 2 份/周（1 份 = ½ 杯）", value: 0, unit: "份/周", met: false),
        MepaItem(key: "meat", zh: "红肉、汉堡、培根、香肠", criterion: "< 3 份/周（1 份 = 3 盎司）", value: 4.2, unit: "份/周", met: false),
        MepaItem(key: "fish", zh: "鱼和贝类", criterion: "> 1 份/周（1 份 = 3 盎司）", value: 2, unit: "份/周", met: true),
        MepaItem(key: "fast_food", zh: "快餐", criterion: "< 1 次/周", value: 0, unit: "次/周", met: true),
    ])

    static let le8Components: [Le8Component] = [
        Le8Component(key: "diet", zh: "饮食（MEPA）", points: 50, value: "MEPA 9/16（近 7 天记录推算）",
                     rule: "MEPA 15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0", missing: "需要至少 3 天饮食记录"),
        Le8Component(key: "activity", zh: "身体活动", points: 90, value: "128 分钟/周",
                     rule: "≥150 → 100；120–149 → 90", missing: "记录运动或同步“锻炼分钟”"),
        Le8Component(key: "nicotine", zh: "尼古丁暴露", points: 100, value: "从不吸烟",
                     rule: "从不 100", missing: "在设置 → 个人档案中填写吸烟情况"),
        Le8Component(key: "sleep", zh: "睡眠", points: 70, value: "平均 6.6 小时/晚",
                     rule: "7–<9 小时 100；6–<7 → 70", missing: "填写或同步睡眠时长"),
        Le8Component(key: "bmi", zh: "体重指数 BMI", points: 100, value: "BMI 23.6",
                     rule: "<25 → 100", missing: "记录体重"),
        Le8Component(key: "lipids", zh: "血脂（非 HDL 胆固醇）", points: nil, value: "—",
                     rule: "<130 → 100", missing: "在身体页填写体检的总胆固醇与 HDL"),
        Le8Component(key: "glucose", zh: "血糖", points: nil, value: "—",
                     rule: "空腹 <100 → 100", missing: "在身体页填写体检的空腹血糖或糖化血红蛋白"),
        Le8Component(key: "bp", zh: "血压", points: 25, value: "142/88 mmHg",
                     rule: "140–159 或 90–99 → 25", missing: "记录血压"),
    ]

    static let wcrf = WcrfResult(score: 3.25, max: 5, components: [
        WcrfComponent(key: "weight", zh: "保持健康体重", points: 1, max: 1, detail: "BMI 23.6，腰围 82 cm",
                      rule: "BMI 18.5–24.9 得 0.5，25–29.9 得 0.25；腰围 男 <94 cm 得 0.5，94–101.9 得 0.25"),
        WcrfComponent(key: "activity", zh: "积极运动", points: 0.5, max: 1, detail: "128 分钟/周", rule: "中高强度活动 ≥150 分钟/周得 1，75–149 得 0.5"),
        WcrfComponent(key: "plants", zh: "多吃全谷物、蔬菜、水果、豆类", points: 0.75, max: 1, detail: "果蔬 412 g/天，膳食纤维 21.4 g/天",
                      rule: "果蔬 ≥400 g/天得 0.5（200–399 得 0.25）；膳食纤维 ≥30 g/天得 0.5（15–29 得 0.25）"),
        WcrfComponent(key: "upf", zh: "少吃快餐和高脂高糖高淀粉的加工食品", points: nil, max: 0, detail: "超加工食品供能 18%（仅展示）",
                      rule: "原文按研究人群内的三分位数评分，没有公开的绝对切点，本系统不计分"),
        WcrfComponent(key: "meat", zh: "限制红肉和加工肉", points: 0, max: 1, detail: "红肉 540 g/周，加工肉 120 g/周",
                      rule: "红肉 ≤500 g/周且加工肉 <21 g/周得 1；加工肉 21–99 得 0.5；红肉 >500 或加工肉 ≥100 得 0"),
        WcrfComponent(key: "ssb", zh: "限制含糖饮料", points: 1, max: 1, detail: "0 ml/天", rule: "0 得 1；≤250 ml/天得 0.5；>250 得 0"),
        WcrfComponent(key: "alcohol", zh: "限制饮酒", points: nil, max: 1, detail: "无数据", rule: "不饮酒得 1；≤28 g/天得 0.5；>28 g 得 0"),
    ])

    static let indices = HealthIndices(
        windowDays: 7, loggedDays: 6, mepa: mepa,
        le8: Le8Result(score: 72.5, category: KeyZh(key: "moderate", zh: "中"), available: 6, components: le8Components),
        wcrf: wcrf, pa: PhysicalActivitySummary(le8MinPerWeek: 128, mvpaMinPerWeek: 128, strengthDays: 1), sleepHours: 6.6)

    static let indicesAfter = HealthIndices(
        windowDays: 7, loggedDays: 7, mepa: MepaResult(score: 10, days: 7, items: mepa.items),
        le8: Le8Result(score: 75, category: KeyZh(key: "moderate", zh: "中"), available: 6,
                       components: le8Components.map { c in
                           c.key == "activity" ? Le8Component(key: c.key, zh: c.zh, points: 100, value: "158 分钟/周", rule: c.rule, missing: c.missing) : c
                       }),
        wcrf: WcrfResult(score: 3.75, max: 5, components: wcrf.components),
        pa: PhysicalActivitySummary(le8MinPerWeek: 158, mvpaMinPerWeek: 158, strengthDays: 1), sleepHours: 6.6)

    static let emptyIndices = HealthIndices(
        windowDays: 7, loggedDays: 1, mepa: nil,
        le8: Le8Result(score: nil, category: nil, available: 0,
                       components: le8Components.map { Le8Component(key: $0.key, zh: $0.zh, points: nil, value: "—", rule: $0.rule, missing: $0.missing) }),
        wcrf: WcrfResult(score: 0, max: 0, components: wcrf.components.map {
            WcrfComponent(key: $0.key, zh: $0.zh, points: nil, max: $0.max, detail: "无数据", rule: $0.rule)
        }),
        pa: PhysicalActivitySummary(le8MinPerWeek: nil, mvpaMinPerWeek: nil, strengthDays: 0), sleepHours: nil)

    static let total = CompositeScore(score: 59.1, parts: [
        CompositePart(key: "hei", zh: "膳食质量", weight: 50, score: 39.2, points: 19.6, note: ""),
        CompositePart(key: "mar", zh: "微量营养素", weight: 15, score: 30, points: 4.5, note: ""),
        CompositePart(key: "energy", zh: "能量平衡", weight: 15, score: 100, points: 15, note: ""),
        CompositePart(key: "activity", zh: "身体活动", weight: 20, score: 100, points: 20, note: ""),
    ], missing: [])

    static let totalMissing = CompositeScore(score: 64.4, parts: [
        CompositePart(key: "hei", zh: "膳食质量", weight: 50, score: 62, points: 31, note: ""),
        CompositePart(key: "mar", zh: "微量营养素", weight: 15, score: 70, points: 10.5, note: ""),
        CompositePart(key: "energy", zh: "能量平衡", weight: 15, score: 80, points: 12, note: ""),
        CompositePart(key: "activity", zh: "身体活动", weight: 20, score: nil, points: nil, note: "无活动数据"),
    ], missing: ["身体活动"])

    private static func item(_ key: String, _ zh: String, _ category: String, _ status: ScoreStatus) -> ScoreItem {
        ScoreItem(key: key, category: category, zh: zh, value: 0, unit: "", targetText: "", target: nil, ideal: nil, limit: nil,
                  status: status, score: 0, points: 0, maxPoints: 0, message: "", sources: [])
    }

    private static func score(hei: Double?, intake: Double, tdee: Double, sodium: Double, addedSugar: Double, satFat: Double,
                              protein: Double, fiber: Double, mar: Double?, items: [ScoreItem], hazards: [HazardResult]) -> DailyScore {
        DailyScore(
            date: "2026-09-30", hasData: true, score: hei, total: total, categories: [], items: items,
            hei: nil, mar: mar.map { MarResult(value: $0, nutrients: []) }, hazards: hazards,
            energy: EnergyResult(intake: intake, resting: 1520, restingSource: "device", active: 480, activeSource: "device",
                                 exerciseKcal: 120, tef: intake * 0.1, tdee: tdee, method: "measured", target: 2100, balance: intake - tdee),
            totals: ["sodium_mg": sodium, "added_sugars_g": addedSugar, "sat_fat_g": satFat, "protein_g": protein, "fiber_g": fiber],
            groups: [:], macroPct: MacroPct(protein: 18, carb: 52, fat: 30, satFat: 9.5, addedSugar: 4, alcohol: 0), upfPct: 18,
            mealCount: 2, itemCount: 5, fastFoodMeals: 0, completeness: Completeness(level: "partial", note: "记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考"),
            top: TopLists(issues: [], wins: []), weightKg: 68.2, weighedToday: nil, version: 3)
    }

    static let before = score(hei: 58.3, intake: 1240, tdee: 2363, sodium: 1650, addedSugar: 12.5, satFat: 14.2, protein: 52.4, fiber: 14.1, mar: 61,
                              items: [item("sodium_mg", "钠", "moderation", .good), item("fiber_g", "膳食纤维", "adequacy", .bad),
                                      item("hei_sodium", "钠", "hei", .good), item("protein_g", "蛋白质", "adequacy", .warn)],
                              hazards: [highTempMeat])

    static let after = score(hei: 61.7, intake: 1868, tdee: 2369, sodium: 2875, addedSugar: 12.5, satFat: 21.8, protein: 88.1, fiber: 19.6, mar: 68,
                             items: [item("sodium_mg", "钠", "moderation", .bad), item("fiber_g", "膳食纤维", "adequacy", .warn),
                                     item("hei_sodium", "钠", "hei", .warn), item("protein_g", "蛋白质", "adequacy", .ok)],
                             hazards: [highTempMeat, processedMeat])

    static let preview = DayPreview(date: "2026-09-30", before: before, after: after,
                                    indices: PreviewIndices(before: indices, after: indicesAfter))
}

// MARK: - Sample charts used by the chart previews

@MainActor enum DSPreviewCharts {
    static let labels = (0..<30).map { LocalDay.shortDate(LocalDay.addDays("2026-09-01", $0)) }
    static let scores: [Double?] = (0..<30).map { i in [4, 5, 12, 13, 20].contains(i) ? nil : 48 + Double((i * 37) % 31) }

    static var scoreCard: some View {
        ChartCard(title: "膳食质量 HEI-2020", hint: "USDA 健康饮食指数，0–100；虚线为美国人平均 58 分",
                  table: ChartTable(columns: ["日期", "评分"], rows: zip(labels, scores).map { [.text($0), .number($1)] })) {
            DSPreviewLineChart(labels: labels, values: scores)
        }
    }

    static var barCard: some View {
        ChartCard(title: "营养素追踪：钠", hint: "每日（仅计有记录的天）；横线为你的个人目标/上限",
                  table: ChartTable(columns: ["日期", "钠 (mg)"], rows: zip(labels, scores).map { [.text($0), .number($1.map { $0 * 40 }, decimals: 1)] })) {
            DSPreviewBarChart(labels: labels, values: scores.map { $0.map { $0 * 40 } })
        }
    }
}
