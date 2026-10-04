import Foundation

// MARK: - 评分规则 text (rep §9.9, web2 §5.10 tab `rules`)
// No endpoint serves these texts; the web hard-codes them in `pages/Standards.tsx`. Copied verbatim.
// The two values that come from `meta` (`heiUsMean`, the MAR nutrient names) are filled in by the functions below.

/// One label/rule row of the LE8 and WCRF/AICR tables.
struct StandardsRuleRow: Sendable, Hashable, Identifiable {
    let label: String
    let rule: String
    var id: String { label }
}

/// One `<dt>/<dd>` pair of a key/value list (web `.kv`).
struct StandardsKeyValue: Sendable, Hashable, Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

enum StandardsRulesText {
    // Accent banner (two lines separated by `<br />` on the web).
    static let bannerLine1 = "评分规则 v2：各分项全部采用已发表、经同行评议的评分体系。“美国心脏协会 LE8”“WCRF/AICR”“MAR”都是等权合成；HEI-2020 的组分分值由 USDA 规定。"
    static let bannerLine2 = "总分（满分 100）是本站按自定权重把分项合成的一个数字，没有权威出处：每天 = HEI × 50% + MAR × 15% + 能量平衡 × 15% + 身体活动 × 20%；每周 = 周期 HEI × 40% + MAR 日均 × 10% + LE8 × 35% + WCRF（折算百分制）× 15%。缺少的分项不计入，其余按权重折算。"

    // Card 1: daily score
    static let dailyTitle = "每日：膳食质量 HEI-2020 + 微量营养素 MAR"

    /// The four `.kv` rows. `heiUsMean` is `meta.heiUsMean` printed raw; `marNutrientNames` is
    /// `meta.marNutrients` mapped to the nutrient `zh` and joined with `、`.
    static func dailyItems(heiUsMean: String, marNutrientNames: String) -> [StandardsKeyValue] {
        [
            StandardsKeyValue(
                key: "今日膳食质量",
                value: "HEI-2020 总分（USDA / NCI）。13 个组分按每 1000 kcal 的密度在“零分标准”与“满分标准”之间线性计分，分值见“HEI-2020”标签页。例如钠 ≤1.1 g/1000 kcal 得 10 分，≥2.0 g 得 0 分，页面会写明“钠组分扣 x 分”。美国人平均 \(heiUsMean) 分（NHANES 2017–2018）。"),
            StandardsKeyValue(
                key: "微量营养素 MAR",
                value: "平均充足比（Madden & Yoder 1972；FAO 最低膳食多样性验证研究采用的 11 种微量营养素：\(marNutrientNames)）。每种 NAR = min(摄入 ÷ RDA, 1)，等权平均 × 100。注：IOM 指出按 RDA 判断个人单日摄入只是粗略参考。"),
            StandardsKeyValue(
                key: "其他检查项",
                value: "其余营养素对照 RDA/AI；钠（CDRR 2300 mg / AHA 1500 mg）、添加糖、饱和脂肪、反式脂肪、酒精、咖啡因、超加工食品、每餐添加糖、AMDR、UL；能量平衡。这些只标“达标 / 偏离 / 不达标”并写明超出多少，不另设权重。"),
            StandardsKeyValue(
                key: "致癌物与风险物",
                value: "按 IARC 分级给出警示与剂量，不另设扣分；加工肉、红肉、酒精、含糖饮料在 WCRF/AICR 评分中计分。"),
        ]
    }

    // Card 2: LE8
    static let le8Title = "综合：美国心脏协会 Life's Essential 8（LE8）"
    /// The intro paragraph; the middle part is bold on the web (`<b>`).
    static let le8IntroLead = "Lloyd-Jones DM et al., Circulation 2022。8 项各 0–100 分，"
    static let le8IntroBold = "总分 = 已有指标的等权平均"
    static let le8IntroTail = "（缺失指标不计入分母，按官方补充材料）；80–100 高，50–79 中，0–49 低。今日页显示近 7 天，周报 / 月报显示整个周期。"
    static let le8Table: [StandardsRuleRow] = [
        StandardsRuleRow(label: "饮食", rule: "个人用 MEPA 16 题问卷：15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0（本站由饮食记录自动推算每周份数）"),
        StandardsRuleRow(label: "身体活动（分钟/周，高强度 ×2）", rule: "≥150 → 100；120–149 → 90；90–119 → 80；60–89 → 60；30–59 → 40；1–29 → 20；0 → 0"),
        StandardsRuleRow(label: "尼古丁暴露", rule: "从不 100；戒 ≥5 年 75；戒 1–5 年 50；戒 <1 年或电子烟 25；吸烟 0；家中有人室内吸烟 −20"),
        StandardsRuleRow(label: "睡眠（小时/晚）", rule: "7–<9 → 100；9–<10 → 90；6–<7 → 70；5–<6 或 ≥10 → 40；4–<5 → 20；<4 → 0"),
        StandardsRuleRow(label: "BMI", rule: "<25 → 100；25–29.9 → 70；30–34.9 → 30；35–39.9 → 15；≥40 → 0"),
        StandardsRuleRow(label: "非 HDL 胆固醇（mg/dL）", rule: "<130 → 100；130–159 → 60；160–189 → 40；190–219 → 20；≥220 → 0；服药 −20"),
        StandardsRuleRow(label: "血糖", rule: "无糖尿病：空腹 <100 或 HbA1c <5.7 → 100；100–125 或 5.7–6.4 → 60；糖尿病：HbA1c <7 → 40，7–7.9 → 30，8–8.9 → 20，9–9.9 → 10，≥10 → 0"),
        StandardsRuleRow(label: "血压（mmHg）", rule: "<120/<80 → 100；120–129/<80 → 75；130–139 或 80–89 → 50；140–159 或 90–99 → 25；≥160 或 ≥100 → 0；服药 −20"),
    ]

    // Card 3: WCRF/AICR
    static let wcrfTitle = "防癌：2018 WCRF/AICR 标准化评分"
    static let wcrfIntro = "Shams-White MM et al., Nutrients 2019。7 条建议各 1 分、等权，子项平分该条的 1 分（母乳喂养为可选项，不计）。"
    static let wcrfTable: [StandardsRuleRow] = [
        StandardsRuleRow(label: "保持健康体重", rule: "BMI 18.5–24.9 → 0.5，25–29.9 → 0.25；腰围 男 <94 / 女 <80 cm → 0.5，男 94–101.9 / 女 80–87.9 → 0.25（只有一项时分数加倍）"),
        StandardsRuleRow(label: "积极运动", rule: "中高强度 ≥150 分钟/周 → 1；75–149 → 0.5；<75 → 0"),
        StandardsRuleRow(label: "多吃全谷物、蔬菜、水果、豆类", rule: "果蔬 ≥400 g/天 → 0.5（200–399 → 0.25）；膳食纤维 ≥30 g/天 → 0.5（15–29 → 0.25）"),
        StandardsRuleRow(label: "少吃快餐和加工食品", rule: "原文按研究人群内超加工供能比的三分位数评分，没有绝对切点 —— 本站只展示、不计分"),
        StandardsRuleRow(label: "限制红肉和加工肉", rule: "红肉 ≤500 g/周且加工肉 <21 g/周 → 1；加工肉 21–99 g/周 → 0.5；红肉 >500 或加工肉 ≥100 → 0"),
        StandardsRuleRow(label: "限制含糖饮料", rule: "0 → 1；≤250 ml/天 → 0.5；>250 → 0"),
        StandardsRuleRow(label: "限制饮酒", rule: "不饮酒 → 1；男 ≤28 / 女 ≤14 g 纯酒精/天 → 0.5；以上 → 0"),
    ]

    // Card 4: energy and weight
    static let energyTitle = "能量与体重"
    static let energyText = "能量需求：NASEM 2023 EER 方程（19 岁以上）；基础代谢：Mifflin-St Jeor。有设备数据时，消耗 = (静息 + 活动能量 + 未被设备记录的运动) ÷ 0.9；运动净消耗 = (MET − 1) × 体重 × 小时（2024 Compendium）。体重趋势用指数移动平均（α = 0.1）；“反推日消耗” = 日均摄入 − 趋势体重变化 × 7700 ÷ 天数。能量平衡只标状态，体重结果体现在 LE8 的 BMI 与 WCRF 的健康体重中。"
}
