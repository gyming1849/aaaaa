import SwiftUI

// MARK: - B2. KeyLimitsCard `关键指标` (web1 §4.3 B2; rep §3.4.4, §4, §17.2)
// Seven meters with ideal / limit ticks. Status = the ScoreItem with that key (info when absent). 酒精 and 咖啡因 only
// appear when the day has any. A meter whose target row is missing from the response is skipped instead of crashing.

struct TodayKeyLimitsCard: View {
    let score: DailyScore
    let targets: Targets

    private func status(_ key: String) -> ScoreStatus { score.item(key)?.status ?? .info }

    var body: some View {
        Card {
            CardHeader("关键指标", hint: "竖线 = 理想值 / 上限")
            VStack(alignment: .leading, spacing: 14) {
                let tot = score.totals
                let L = targets.limits
                if let na = L["sodium_mg"] {
                    let v = tot.v("sodium_mg")
                    Meter(name: "钠", value: v, unit: "mg", max: na.limit,
                          marks: [MeterMark(na.ideal, "理想", .ideal), MeterMark(na.limit, "上限")],
                          status: status("sodium_mg"),
                          foot: "≈ 食盐 \(fmt(v / 393, 1)) g · 上限 \(fmt(na.limit)) mg，理想 ≤ \(fmt(na.ideal)) mg")
                }
                if let sugar = L["added_sugars_g"] {
                    Meter(name: "添加糖", value: tot.v("added_sugars_g"), unit: "g", max: sugar.limit,
                          marks: [MeterMark(sugar.ideal, "AHA", .ideal), MeterMark(sugar.limit, "上限")],
                          status: status("added_sugars_g"), decimals: 1,
                          foot: "上限 \(fmt(sugar.limit)) g，AHA 建议 ≤ \(fmt(sugar.ideal)) g；DGA 2025：每餐 ≤ 10 g")
                }
                if let sat = L["sat_fat_pct"] {
                    Meter(name: "饱和脂肪供能比", value: score.macroPct.satFat, unit: "%", max: 10,
                          marks: [MeterMark(sat.ideal, "理想", .ideal), MeterMark(10, "上限")],
                          status: status("sat_fat_pct"), decimals: 1,
                          foot: "\(fmt(tot.v("sat_fat_g"), 1)) g · 上限 10% 能量")
                }
                if let fiber = targets.intake["fiber_g"] {
                    Meter(name: "膳食纤维", value: tot.v("fiber_g"), unit: "g", max: fiber.value,
                          marks: [MeterMark(fiber.value, "AI")],
                          status: status("fiber_g"), decimals: 1,
                          foot: "目标 ≥ \(fmt(fiber.value)) g（14 g/1000 kcal）")
                }
                let p = targets.protein
                Meter(name: "蛋白质", value: tot.v("protein_g"), unit: "g", max: p.idealHighG,
                      marks: [MeterMark(p.rdaG, "RDA"), MeterMark(p.idealLowG, "1.2 g/kg", .ideal), MeterMark(p.idealHighG, "1.6 g/kg", .ideal)],
                      status: status("protein_g"), decimals: 1,
                      foot: "RDA \(fmt(p.rdaG)) g；DGA 2025–2030 建议 \(fmt(p.idealLowG))–\(fmt(p.idealHighG)) g")
                if tot.v("alcohol_g") > 0 {
                    let limit = L["alcohol_g"]?.limit ?? 0
                    let alcohol = tot.v("alcohol_g")
                    Meter(name: "酒精", value: alcohol, unit: "g", max: max(limit, 14),
                          marks: limit > 0 ? [MeterMark(limit, "上限")] : [],
                          status: status("alcohol_g"), decimals: 1,
                          foot: "≈ \(fmt(alcohol / 14, 1)) 标准杯；IARC 1 类致癌物，越少越好")
                }
                if tot.v("caffeine_mg") > 0, let caf = L["caffeine_mg"] {
                    Meter(name: "咖啡因", value: tot.v("caffeine_mg"), unit: "mg", max: caf.limit,
                          marks: [MeterMark(caf.limit, "上限")],
                          status: status("caffeine_mg"),
                          foot: "上限 \(fmt(caf.limit)) mg")
                }
            }
        }
    }
}
