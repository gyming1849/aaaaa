#if DEBUG
import SwiftUI

// MARK: - #Preview fixtures for the 标准库 tabs (shaped like real `/standards/meta`, `/standards/dri` and
// `/profile/targets` responses, trimmed to a few rows). Light and dark via `DSPreviewSchemes`.

enum StandardsPreviewData {
    static let sources: [SourceDef] = [
        SourceDef(id: "nasem_dri", org: "NASEM / NIH ODS", title: "Dietary Reference Intakes (DRI) Summary Tables — RDA/AI/UL/AMDR",
                  year: "1997–2023", url: "https://www.ncbi.nlm.nih.gov/books/NBK545442/"),
        SourceDef(id: "aha_sodium", org: "American Heart Association", title: "How much sodium should I eat per day?", year: "2024",
                  url: "https://www.heart.org/en/healthy-living/healthy-eating/eat-smart/sodium/how-much-sodium-should-i-eat-per-day"),
        SourceDef(id: "nasem_na_k", org: "NASEM", title: "Dietary Reference Intakes for Sodium and Potassium (AI & CDRR)", year: "2019",
                  url: "https://nap.nationalacademies.org/catalog/25353"),
        SourceDef(id: "dga_2025", org: "USDA & HHS", title: "Dietary Guidelines for Americans, 2025–2030", year: "2026", url: "https://www.dietaryguidelines.gov/"),
        SourceDef(id: "iarc_aspartame", org: "IARC & JECFA / WHO", title: "Aspartame hazard and risk assessment results released", year: "2023",
                  url: "https://www.who.int/news/item/14-07-2023-aspartame-hazard-and-risk-assessment-results-released"),
        SourceDef(id: "iarc_114", org: "IARC / WHO", title: "IARC Monographs Volume 114: Red Meat and Processed Meat", year: "2015/2018",
                  url: "https://publications.iarc.who.int/564"),
        SourceDef(id: "system", org: "本系统", title: "本系统设定的阈值（无权威数值时的保守折中，已在规则中注明）", year: "2026", url: ""),
    ]

    static let meta = Meta(
        version: 3,
        nutrients: [
            NutrientDef(key: "protein_g", zh: "蛋白质", en: "Protein", unit: "g", group: "macro", decimals: 1, dv: 50, note: nil),
            NutrientDef(key: "vit_a_ug", zh: "维生素 A", en: "Vitamin A", unit: "µg RAE", group: "vitamin", decimals: 0, dv: 900, note: nil),
            NutrientDef(key: "thiamin_mg", zh: "维生素 B1 (硫胺素)", en: "Thiamin", unit: "mg", group: "vitamin", decimals: 2, dv: 1.2, note: nil),
            NutrientDef(key: "sodium_mg", zh: "钠", en: "Sodium", unit: "mg", group: "mineral", decimals: 0, dv: 2300, note: nil),
        ],
        foodGroups: [],
        hazards: [DSPreviewData.processedMeatDef],
        hazardsInfoOnly: [
            HazardInfoOnly(zh: "呋喃 (Furan)", iarc: "2B", examples: "咖啡、罐头、罐装婴儿食品", why: "日常饮食暴露量低，且咖啡本身对多种癌症呈中性或保护作用，不计分"),
            HazardInfoOnly(zh: "咖啡", iarc: "3", examples: "咖啡", why: "IARC 2016 年将咖啡降为第 3 类（无法分类），不警示；咖啡因另行限量"),
        ],
        hei: [
            HeiDef(key: "total_fruits", zh: "水果总量", en: "Total Fruits", max: 5, kind: "adequacy", best: 0.8, worst: 0, unit: "杯当量/1000kcal", hint: "每天吃水果（含果汁）"),
            HeiDef(key: "fatty_acids", zh: "脂肪酸比例", en: "Fatty Acids", max: 10, kind: "adequacy", best: 2.5, worst: 1.2, unit: "(PUFA+MUFA)/SFA", hint: "植物油、坚果、鱼替代动物脂肪"),
            HeiDef(key: "sodium", zh: "钠", en: "Sodium", max: 10, kind: "moderation", best: 1.1, worst: 2, unit: "g/1000kcal", hint: "少盐少酱油"),
        ],
        activities: [
            ActivityDef(key: "walk_brisk", zh: "快走 (约 6 km/h)", met: 4.8, speedKmh: 6, code: nil, intensity: "moderate"),
            ActivityDef(key: "run_13kmh", zh: "跑步 (约 13 km/h)", met: 12, speedKmh: 12.9, code: nil, intensity: "vigorous"),
            ActivityDef(key: "yoga", zh: "瑜伽 (哈他)", met: 2.3, speedKmh: nil, code: nil, intensity: "light"),
        ],
        activityLevels: [],
        sources: sources,
        lifeStages: [LifeStage(id: "c1_3", zh: "儿童 1–3 岁"), LifeStage(id: "m19_30", zh: "男 19–30 岁"), LifeStage(id: "l19_30", zh: "哺乳期 19–30 岁")],
        marNutrients: ["vit_a_ug", "thiamin_mg"],
        heiUsMean: 58,
        conditions: [])

    static let dri = DriTables(
        lifeStages: meta.lifeStages,
        intake: [
            "protein_g": DriIntakeRow(kind: "RDA", values: [13, 56, 71]),
            "vit_a_ug": DriIntakeRow(kind: "RDA", values: [300, 900, 1300]),
            "thiamin_mg": DriIntakeRow(kind: "RDA", values: [0.5, 1.2, 1.4]),
            "sodium_mg": DriIntakeRow(kind: "AI", values: [800, 1500, 1500]),
        ],
        upper: [
            "vit_a_ug": DriUpperRow(appliesToTotal: false, note: "UL 仅针对预制维生素 A（视黄醇），不含 β-胡萝卜素", values: [600, 3000, 3000]),
            "thiamin_mg": DriUpperRow(appliesToTotal: true, note: nil, values: [nil, nil, nil]),
        ],
        sodiumCdrr: [1200, 2300, 2300],
        proteinPerKg: [1.05, 0.8, 1.3])

    static let targets = Targets(
        date: "2026-10-03", age: 34, sex: "male", lifeStage: "m31_50", lifeStageZh: "男 31–50 岁", physiology: "none", sensitive: false,
        weightKg: 98, heightCm: 176, bmi: 31.6, bmiCategory: KeyZh(key: "obese", zh: "肥胖"), referenceWeightKg: 81,
        bmr: 1715, eer: 2839, eerMethod: "NASEM 2023 EER", goal: "lose", goalDeltaKcal: -550, energyTarget: 2289, energyFloor: 1500,
        protein: ProteinTargets(rdaG: 64.8, idealLowG: 97.2, idealHighG: 129.6, perKgRda: 0.8),
        intake: [
            "protein_g": IntakeTarget(key: "protein_g", value: 64.8, kind: "RDA", source: "nasem_dri", note: "RDA 0.8 g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg"),
            "vit_a_ug": IntakeTarget(key: "vit_a_ug", value: 900, kind: "RDA", source: "nasem_dri", note: nil),
            "sodium_mg": IntakeTarget(key: "sodium_mg", value: 1500, kind: "AI", source: "nasem_na_k", note: nil),
        ],
        upper: ["vit_a_ug": UpperTarget(value: 3000, appliesToTotal: false, note: "UL 仅针对预制维生素 A（视黄醇），不含 β-胡萝卜素")],
        limits: [
            "sodium_mg": LimitTarget(key: "sodium_mg", zh: "钠", unit: "mg", ideal: 1500, limit: 2300, idealSource: "aha_sodium",
                                     limitSource: "nasem_na_k", note: "上限为 CDRR，与 DGA 一致"),
            "upf_pct": LimitTarget(key: "upf_pct", zh: "超加工食品供能比", unit: "% 能量", ideal: 20, limit: 50, idealSource: "dga_2025",
                                   limitSource: "system", note: "DGA 2025–2030 要求限制高度加工食品但未给数值；按 NOVA 4 类估算，阈值为本系统设定"),
        ],
        amdr: Amdr(protein: [10, 35], carb: [45, 65], fat: [20, 35], n6: nil, n3: nil),
        addedSugarPerMealG: 10, aspartameAdiMg: 3920)
}

#Preview("Standards · 我的个性化目标") {
    DSPreviewSchemes { StandardsMineTab(targets: StandardsPreviewData.targets, meta: StandardsPreviewData.meta) }
}

#Preview("Standards · DRI 总表") {
    DSPreviewSchemes { StandardsDriTab(dri: StandardsPreviewData.dri, meta: StandardsPreviewData.meta) }
}

#Preview("Standards · 致癌物 / HEI / MET") {
    DSPreviewSchemes {
        StandardsHazardsTab(meta: StandardsPreviewData.meta)
        StandardsHeiTab(meta: StandardsPreviewData.meta)
        StandardsMetTab(meta: StandardsPreviewData.meta)
    }
}

#Preview("Standards · 评分规则 / 资料来源") {
    DSPreviewSchemes {
        StandardsRulesTab(meta: StandardsPreviewData.meta)
        StandardsSourcesTab(meta: StandardsPreviewData.meta)
    }
}

#Preview("Standards · tab bar / error") {
    @Previewable @State var tab: StandardsTab = .rules
    DSPreviewSchemes {
        StandardsTabBar(selection: $tab)
        StandardsLoadErrorBanner(message: "网络连接失败，请检查网络或服务器地址") {}
        LoadingView()
    }
}
#endif
