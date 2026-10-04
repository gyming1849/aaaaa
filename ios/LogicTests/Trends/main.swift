import Foundation

// WP5 Trends logic tests (DESIGN §E.2 WP5, §F.2): range presets, bucketing (week key on Monday, month label `25/3月`),
// averages with the web's quirks (null HEI counted as 0, steps averaged over days with steps), rolling mean,
// target lines, summary tiles, pass-rate ordering and the score-calendar layout.

// MARK: - Fixture helpers

@MainActor func trendDay(_ date: String, hasData: Bool = true, score: Double? = nil, intake: Double = 0, tdee: Double = 2000,
                         target: Double = 2100, weight: Double? = nil, trend: Double? = nil, steps: Double? = nil,
                         hei: Double? = nil, mar: Double? = nil, categories: [String: Double] = [:], hazardCount: Int = 0,
                         totals: Vec = [:], groups: Vec = [:], macroPct: [String: Double] = [:], upfPct: Double = 0) -> TrendDay {
    TrendDay(date: date, hasData: hasData, score: score, total: nil, categories: categories, hazardCount: hazardCount,
             hei: hei, mar: mar, intake: intake, tdee: tdee, target: target, exerciseKcal: 0, energyMethod: "eer",
             weight: weight, trend: trend, steps: steps, activeKcal: nil, completeness: hasData ? "likely" : "none",
             totals: totals, groups: groups, macroPct: macroPct, upfPct: upfPct, statuses: [:])
}

@MainActor func fixture<T: Decodable>(_ name: String, as type: T.Type) -> T? {
    let path = "LogicTests/Trends/Fixtures/\(name)"
    guard let data = FileManager.default.contents(atPath: path) else {
        check(false, "fixture \(name)", "cannot read \(path)")
        return nil
    }
    return expectNoThrow("decode \(name)") { try JSONDecoder().decode(T.self, from: data) }
}

@MainActor func expectSeries(_ actual: [Double?], _ expected: [Double?], _ name: String) {
    expectEqual(actual.count, expected.count, "\(name) count")
    for (i, (a, e)) in zip(actual, expected).enumerated() {
        switch (a, e) {
        case (nil, nil): continue
        case (let a?, let e?): expectApprox(a, e, "\(name)[\(i)]", tolerance: 1e-9)
        default: check(false, "\(name)[\(i)]", "expected \(String(describing: e)), got \(String(describing: a))")
        }
    }
}

// MARK: - Range presets (web2 §5.1.1)
section("range")
let today = "2026-10-03"
let (cs, ce) = TrendsBucketing.defaultCustom(today: today)
expectEqual(cs, "2026-08-05", "custom default start = today − 59")
expectEqual(ce, today, "custom default end = today")
expectEqual(TrendsBucketing.bounds(.d7, today: today, customStart: cs, customEnd: ce).start, "2026-09-27", "7 天")
expectEqual(TrendsBucketing.bounds(.d30, today: today, customStart: cs, customEnd: ce).start, "2026-09-04", "30 天")
expectEqual(TrendsBucketing.bounds(.d90, today: today, customStart: cs, customEnd: ce).start, "2026-07-06", "90 天")
expectEqual(TrendsBucketing.bounds(.year, today: today, customStart: cs, customEnd: ce).start, "2026-01-01", "今年")
expectEqual(TrendsBucketing.bounds(.d365, today: today, customStart: cs, customEnd: ce).start, "2025-10-04", "一年")
expectEqual(TrendsBucketing.bounds(.all, today: today, customStart: cs, customEnd: ce).start, "2023-10-04", "全部 = today − 1095")
let custom = TrendsBucketing.bounds(.custom, today: today, customStart: "2026-01-02", customEnd: "2026-02-03")
expectEqual(custom.start, "2026-01-02", "custom start")
expectEqual(custom.end, "2026-02-03", "custom end")
expectEqual(TrendsBucketing.bounds(.d30, today: today, customStart: cs, customEnd: ce).end, today, "end = today")
expectEqual(TrendsRange.allCases.map(\.label), ["7 天", "30 天", "90 天", "今年", "一年", "全部", "自定义"], "Seg labels in order")
expectEqual(TrendsBucketing.periodStart(start: "2026-09-04", end: today), "2026-09-04", "period start unchanged ≤ 400 days")
expectEqual(TrendsBucketing.periodStart(start: "2025-08-29", end: today), "2025-08-29", "period start at exactly 400 days")
expectEqual(TrendsBucketing.periodStart(start: "2023-10-04", end: today), "2025-08-29", "period start clamped to end − 400")

// MARK: - Unit thresholds
section("unit")
expectEqual(TrendsBucketing.unit(span: 30), .day, "30 → day")
expectEqual(TrendsBucketing.unit(span: 92), .day, "92 → day")
expectEqual(TrendsBucketing.unit(span: 93), .week, "93 → week")
expectEqual(TrendsBucketing.unit(span: 400), .week, "400 → week")
expectEqual(TrendsBucketing.unit(span: 401), .month, "401 → month")
expectEqual(TrendsUnit.day.zh, "每日", "unitZh day")
expectEqual(TrendsUnit.week.zh, "每周平均", "unitZh week")
expectEqual(TrendsUnit.month.zh, "每月平均", "unitZh month")
expectEqual(TrendsUnit.week.explorerZh, "每周日均", "explorer week")
expectEqual(TrendsUnit.month.explorerZh, "每月日均", "explorer month")

// MARK: - Trimming (全部)
section("trim")
let untrimmed = [trendDay("2026-01-01", hasData: false), trendDay("2026-01-02", hasData: false, weight: 70),
                 trendDay("2026-01-03", hasData: true), trendDay("2026-01-04", hasData: false)]
expectEqual(TrendsBucketing.trimmed(untrimmed, range: .all).map(\.date), ["2026-01-02", "2026-01-03", "2026-01-04"], "drops leading empty days (weigh-in counts)")
expectEqual(TrendsBucketing.trimmed(untrimmed, range: .d30).count, 4, "only 全部 trims")
let allEmpty = [trendDay("2026-01-01", hasData: false), trendDay("2026-01-02", hasData: false)]
expectEqual(TrendsBucketing.trimmed(allEmpty, range: .all).count, 2, "no record at all keeps every day")

// MARK: - Bucket keys and labels
section("buckets")
expectEqual(TrendsBucketing.key("2026-10-03", unit: .week), "2026-09-28", "week key = Monday (Saturday)")
expectEqual(TrendsBucketing.key("2026-10-04", unit: .week), "2026-09-28", "week key = Monday (Sunday)")
expectEqual(TrendsBucketing.key("2026-09-28", unit: .week), "2026-09-28", "week key = Monday (Monday)")
expectEqual(TrendsBucketing.key("2026-10-03", unit: .month), "2026-10-01", "month key")
expectEqual(TrendsBucketing.key("2026-10-03", unit: .day), "2026-10-03", "day key")
expectEqual(TrendsBucketing.label(key: "2025-03-01", unit: .month), "25/3月", "month label 25/3月")
expectEqual(TrendsBucketing.label(key: "2026-12-01", unit: .month), "26/12月", "month label 26/12月")
expectEqual(TrendsBucketing.label(key: "2026-09-21", unit: .week), "9/21", "week label = Monday M/D")
expectEqual(TrendsBucketing.label(key: "2026-09-04", unit: .day), "9/4", "day label without padding")

let weekDays = LocalDay.range("2026-09-26", "2026-10-06").map { trendDay($0, hasData: $0 != "2026-09-30") }
let weekBuckets = TrendsBucketing.bucketize(weekDays, unit: .week)
expectEqual(weekBuckets.map(\.key), ["2026-09-21", "2026-09-28", "2026-10-05"], "week buckets keyed by Monday, first-seen order")
expectEqual(weekBuckets.map(\.label), ["9/21", "9/28", "10/5"], "week labels (first Monday precedes start)")
expectEqual(weekBuckets.map { $0.days.count }, [2, 7, 2], "days per week bucket")
expectEqual(weekBuckets.map { $0.logged.count }, [2, 6, 2], "logged days per week bucket")
let monthBuckets = TrendsBucketing.bucketize(LocalDay.range("2025-02-27", "2025-03-02").map { trendDay($0) }, unit: .month)
expectEqual(monthBuckets.map(\.label), ["25/2月", "25/3月"], "month buckets")

// MARK: - Averages and rounding (web `avg`, `r1`)
section("math")
expectNil(TrendsBucketing.avg([]), "avg of nothing is nil")
expectApprox(TrendsBucketing.avg([1, 2, 4]), 7.0 / 3, "avg")
expectApprox(TrendsBucketing.r1(64.25), 64.3, "r1 rounds half up")
expectApprox(TrendsBucketing.r1(64.24), 64.2, "r1 rounds down")
expectApprox(TrendsBucketing.r1(-0.25), -0.2, "r1 negative tie toward +∞ (Math.round)")
expectNil(TrendsBucketing.r1(nil), "r1 nil passthrough")
expectEqual(TrendsBucketing.jsRound(2.5), 3, "jsRound 2.5")
expectEqual(TrendsBucketing.jsRound(-2.5), -2, "jsRound -2.5")
expectEqual(TrendsBucketing.jsRound(84.5), 85, "jsRound 84.5")

// MARK: - Score chart (null HEI counted as 0; rolling mean)
section("score")
let scoreDays = [
    trendDay("2026-09-01", hasData: true, score: 60),
    trendDay("2026-09-02", hasData: true, score: nil),       // < 200 kcal: HEI null → counted as 0
    trendDay("2026-09-03", hasData: false, score: nil),      // no record → gap
    trendDay("2026-09-04", hasData: true, score: 70.04),
]
let dayBuckets = TrendsBucketing.bucketize(scoreDays, unit: .day)
let score = TrendsBucketing.scoreSeries(dayBuckets)
expectSeries(score, [60, 0, nil, 70], "daily score with null HEI as 0")
expectSeries(TrendsBucketing.rolling7(score), [60, 30, 30, 43.3], "7-bucket rolling mean ignores gaps")
expectSeries(TrendsBucketing.rolling7([nil, nil]), [nil, nil], "rolling of nothing is nil")
let longRolling = TrendsBucketing.rolling7((1...9).map { Double($0) })
expectSeries(longRolling, [1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6], "rolling window is 7 buckets")
let weekScore = TrendsBucketing.scoreSeries(TrendsBucketing.bucketize(scoreDays, unit: .week))
expectSeries(weekScore, [43.3], "week mean over logged days, null HEI as 0: (60 + 0 + 70.04) / 3")

// MARK: - Energy, weight, categories
section("energy")
let energyDays = [
    trendDay("2026-09-07", hasData: true, intake: 1800, tdee: 2200, target: 2100),
    trendDay("2026-09-08", hasData: false, intake: 0, tdee: 2000, target: 2100),
    trendDay("2026-09-09", hasData: true, intake: 2101, tdee: 2300, target: 2050),
]
let energyWeek = TrendsBucketing.energySeries(TrendsBucketing.bucketize(energyDays, unit: .week))
expectSeries(energyWeek.intake, [1950.5], "intake over logged days only")
expectSeries(energyWeek.tdee, [2166.7], "tdee over all days")
expectSeries(energyWeek.target, [2083.3], "target over all days")
let energyDaily = TrendsBucketing.energySeries(TrendsBucketing.bucketize(energyDays, unit: .day))
expectSeries(energyDaily.intake, [1800, nil, 2101], "unlogged day intake is a gap")
expectSeries(energyDaily.tdee, [2200, 2000, 2300], "tdee never nil")

section("weight")
let weightDays = [
    trendDay("2026-09-07", weight: 70.2, trend: 70.5),
    trendDay("2026-09-08", weight: nil, trend: 70.44),
    trendDay("2026-09-09", weight: 69.85, trend: nil),
    trendDay("2026-09-14", weight: nil, trend: nil),
]
let weightWeek = TrendsBucketing.weightSeries(TrendsBucketing.bucketize(weightDays, unit: .week))
expectSeries(weightWeek.raw, [70, nil], "weekly mean weigh-in (70.2 + 69.85) / 2 = 70.025 → r1 70")
expectSeries(weightWeek.trend, [70.44, nil], "last non-null trend of the bucket")

section("categories")
let catDays = [
    trendDay("2026-09-07", hasData: true, categories: ["hei": 60, "mar": 80]),
    trendDay("2026-09-08", hasData: true, categories: ["hei": 70]),
    trendDay("2026-09-09", hasData: false, categories: [:]),
]
let catBuckets = TrendsBucketing.bucketize(catDays, unit: .week)
expectSeries(TrendsBucketing.categorySeries(catBuckets, key: "hei"), [65], "HEI category mean")
expectSeries(TrendsBucketing.categorySeries(catBuckets, key: "mar"), [40], "missing MAR counts as 0 on logged days")

// MARK: - Nutrient explorer
section("metric")
let stepsDays = [
    trendDay("2026-09-07", hasData: true, steps: 8000, totals: ["sodium_mg": 2500]),
    trendDay("2026-09-08", hasData: false, steps: 6000, totals: ["sodium_mg": 0]),
    trendDay("2026-09-09", hasData: true, steps: nil, totals: ["sodium_mg": 1500]),
    trendDay("2026-09-10", hasData: false, steps: nil),
]
let stepsBuckets = TrendsBucketing.bucketize(stepsDays, unit: .week)
expectSeries(TrendsBucketing.metricSeries(stepsBuckets, key: "steps"), [7000], "steps averaged over days with steps (logged or not)")
expectSeries(TrendsBucketing.metricSeries(stepsBuckets, key: "sodium_mg"), [2000], "nutrients averaged over logged days")
let noSteps = TrendsBucketing.bucketize([trendDay("2026-09-07", steps: nil)], unit: .day)
expectSeries(TrendsBucketing.metricSeries(noSteps, key: "steps"), [nil], "no step data → nil")
let pickDay = trendDay("2026-09-07", hasData: true, hei: nil, mar: 77.5, hazardCount: 2,
                       totals: ["fiber_g": 21.25], groups: ["red_meat_g": 85], macroPct: ["satFat": 12.3], upfPct: 31.4)
expectApprox(TrendsBucketing.metricValue(pickDay, key: "macro:satFat"), 12.3, "macro:satFat")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "macro:protein"), 0, "missing macro → 0")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "group:red_meat_g"), 85, "group:red_meat_g")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "group:veg_total_cup"), 0, "missing group → 0")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "upf"), 31.4, "upf")
expectNil(TrendsBucketing.metricValue(pickDay, key: "hei"), "hei is nullable")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "mar"), 77.5, "mar")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "hazard"), 2, "hazard count")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "fiber_g"), 21.25, "nutrient total")
expectApprox(TrendsBucketing.metricValue(pickDay, key: "sodium_mg"), 0, "missing nutrient → 0")
let heiBuckets = TrendsBucketing.bucketize([trendDay("2026-09-07", hasData: true, hei: nil), trendDay("2026-09-08", hasData: true, hei: 64)], unit: .week)
expectSeries(TrendsBucketing.metricSeries(heiBuckets, key: "hei"), [64], "explorer ignores null HEI (unlike chart A)")

let nutrients = [NutrientDef(key: "sodium_mg", zh: "钠", en: "Sodium", unit: "mg", group: "mineral", decimals: 0, dv: 2300, note: nil)]
expectEqual(TrendsBucketing.metricInfo("sodium_mg", nutrients: nutrients).optionLabel, "钠（mg）", "nutrient option label")
expectEqual(TrendsBucketing.metricInfo("group:veg_total_cup", nutrients: nutrients).optionLabel, "蔬菜（杯当量）", "extra metric label")
expectEqual(TrendsBucketing.metricInfo("hazard", nutrients: nutrients).zh, "风险物警示数", "hazard zh")
expectEqual(TrendsBucketing.metricInfo("zinc_mg", nutrients: []).zh, "zinc_mg", "unknown key falls back to the key")
expectEqual(TrendsBucketing.metricInfo("zinc_mg", nutrients: []).unit, "", "unknown key has no unit")
expectEqual(TrendsBucketing.metricInfo("zinc_mg", nutrients: []).optionLabel, "zinc_mg", "unknown key label has no empty brackets")
expectEqual(Vocab.trendsExtraMetrics.count, 13, "13 extra metrics")

section("targets")
if let targets = fixture("targets.json", as: Targets.self) {
    let sodium = TrendsBucketing.targetLines(key: "sodium_mg", targets: targets)
    expectEqual(sodium.map(\.name), ["上限 2,300", "理想 1,500"], "sodium limit + ideal")
    expectEqual(sodium.map(\.tone), [.limit, .good], "sodium tones")
    expectEqual(TrendsBucketing.targetLines(key: "macro:satFat", targets: targets).map(\.name), ["上限 10", "理想 8"], "macro:satFat → sat_fat_pct")
    expectEqual(TrendsBucketing.targetLines(key: "upf", targets: targets).map(\.name), ["上限 50", "理想 20"], "upf → upf_pct")
    let protein = TrendsBucketing.targetLines(key: "protein_g", targets: targets)
    expectEqual(protein.map(\.name), ["RDA 56"], "intake target")
    expectEqual(protein.first?.tone, .good, "intake tone good")
    let energy = TrendsBucketing.targetLines(key: "energy_kcal", targets: targets)
    expectEqual(energy.map(\.name), ["目标 \(fmt(targets.energyTarget))"], "energy target")
    let redMeat = TrendsBucketing.targetLines(key: "group:red_meat_g", targets: targets)
    expectEqual(redMeat.map(\.name), ["日均建议 ≤70"], "red meat suggestion")
    expectEqual(redMeat.first?.tone, .limit, "red meat tone")
    expectEqual(redMeat.first?.value, 70, "red meat value")
    expectEqual(TrendsBucketing.targetLines(key: "steps", targets: targets).count, 0, "no line for steps")
}
expectEqual(TrendsBucketing.targetLines(key: "sodium_mg", targets: nil).count, 0, "member view has no target lines")

// MARK: - Summary tiles
section("summary")
let summaryDays = [
    trendDay("2026-09-21", hasData: true, score: 60, intake: 2000, tdee: 2200),
    trendDay("2026-09-22", hasData: true, score: nil, intake: 1000, tdee: 2100),
    trendDay("2026-09-23", hasData: false, intake: 0, tdee: 2000),
]
let noPeriod = TrendsBucketing.summaryTiles(days: summaryDays, period: nil)
expectEqual(noPeriod.map(\.label), ["区间总分", "日均摄入 / 消耗", "趋势体重变化", "按实际数据反推的日消耗"], "tile labels")
expectEqual(noPeriod[0].value, "—", "no period → —")
expectEqual(noPeriod[0].unit, "/ 100", "score unit")
expectEqual(noPeriod[0].delta, "LE8 — · HEI 日均 30 · 2/3 天有记录", "score delta (null HEI as 0)")
expectEqual(noPeriod[1].value, "1,500", "avg intake over logged days")
expectEqual(noPeriod[1].unit, "/ 2,100 kcal", "avg tdee over all days")
expectNil(noPeriod[1].delta, "no delta on tile 2")
expectEqual(noPeriod[2].value, "—", "no weight change")
expectEqual(noPeriod[2].delta, "能量差预测 —", "no prediction")
expectEqual(noPeriod[3].value, "—", "no empirical tdee")
expectEqual(noPeriod[3].delta, "需 ≥14 天体重与较完整的记录", "empirical tdee hint")
expectEqual(TrendsBucketing.weightHint(period: nil), "建议每晚睡前固定时间称重", "weight hint without rate")
if let period = fixture("period.json", as: PeriodScore.self) {
    let tiles = TrendsBucketing.summaryTiles(days: summaryDays, period: period)
    expectEqual(tiles[0].value, fmt(period.total.score), "period total")
    expectEqual(tiles[0].delta, "LE8 \(fmt(period.score)) · HEI 日均 30 · 2/3 天有记录", "LE8 in delta")
    expectEqual(tiles[2].value, "-0.1", "signed weight change, 1 dp")
    expectEqual(tiles[2].delta, "能量差预测 +0.1 kg", "signed prediction")
    expectEqual(tiles[3].value, "—", "empirical tdee null")
    expectEqual(TrendsBucketing.weightHint(period: period), "建议每晚睡前固定时间称重", "ratePerWeek null → hint")

    let rows = TrendsBucketing.passRateRows(period.itemStats)
    check(rows.count <= 18, "pass rates capped at 18")
    check(!rows.contains { $0.category == "hei" }, "pass rates exclude HEI items")
    let ratios = rows.map { Double($0.bad + $0.warn) / Double(max(1, $0.days)) }
    check(zip(ratios, ratios.dropFirst()).allSatisfy { $0 >= $1 }, "pass rates sorted by failing share, descending")
}
let stats = [
    ItemStat(key: "a", zh: "甲", category: "adequacy", good: 5, ok: 0, warn: 1, bad: 1, days: 7),
    ItemStat(key: "h", zh: "HEI", category: "hei", good: 0, ok: 0, warn: 0, bad: 7, days: 7),
    ItemStat(key: "b", zh: "乙", category: "moderation", good: 0, ok: 1, warn: 3, bad: 3, days: 7),
    ItemStat(key: "c", zh: "丙", category: "mar", good: 3, ok: 2, warn: 1, bad: 1, days: 7),
]
expectEqual(TrendsBucketing.passRateRows(stats).map(\.key), ["b", "a", "c"], "sorted descending, ties keep server order")
expectEqual(TrendsBucketing.passRateTitle(stats[3]), "丙：达标 5 天，偏离 1 天，不达标 1 天", "row title (good + ok)")
expectEqual(TrendsBucketing.passRateAccessibility(stats[3]), "丙 达标 5 天 偏离 1 天 不达标 1 天", "row aria label")
let many = (0..<30).map { ItemStat(key: "k\($0)", zh: "\($0)", category: "adequacy", good: 1, ok: 0, warn: 0, bad: 0, days: 1) }
expectEqual(TrendsBucketing.passRateRows(many).count, 18, "first 18 rows")

// MARK: - Score calendar
section("calendar")
expectEqual(TrendsBucketing.heatPiece(85).label, "≥85 优秀", "85 → 优秀")
expectEqual(TrendsBucketing.heatPiece(84).label, "70–85 良好", "84 → 良好")
expectEqual(TrendsBucketing.heatPiece(70).step, 4, "70 → seq[4]")
expectEqual(TrendsBucketing.heatPiece(55).label, "55–70 一般", "55 → 一般")
expectEqual(TrendsBucketing.heatPiece(54).step, 0, "54 → seq[0]")
expectEqual(TrendsBucketing.heatPiece(0).label, "<55 较差", "0 → 较差")
expectEqual(TrendsBucketing.heatPieces.map(\.label), ["<55 较差", "55–70 一般", "70–85 良好", "≥85 优秀"], "legend order")

let calDays = LocalDay.range("2023-12-30", "2026-01-02").map { d in trendDay(d, score: d == "2026-01-02" ? 84.5 : nil) }
let years = TrendsBucketing.calendarYears(calDays)
expectEqual(years.map(\.year), ["2024", "2025", "2026"], "last 3 distinct years")
if let y2026 = years.last {
    expectEqual(y2026.cells.count, 365, "full Jan–Dec strip")
    expectEqual(y2026.cells.first?.date, "2026-01-01", "starts Jan 1")
    expectEqual(y2026.cells.first?.row, 3, "2026-01-01 is a Thursday → row 3 (Monday first)")
    expectEqual(y2026.cells.first?.column, 0, "first column")
    expectEqual(y2026.cells.first(where: { $0.date == "2026-01-05" })?.column, 1, "next Monday starts column 1")
    expectEqual(y2026.cells.first(where: { $0.date == "2026-01-04" })?.row, 6, "Sunday → row 6")
    expectEqual(y2026.cells.first(where: { $0.date == "2026-01-02" })?.score, 85, "score rounded half up (84.5 → 85)")
    expectNil(y2026.cells.first(where: { $0.date == "2026-01-03" })?.score, "no score → empty cell")
    expectEqual(y2026.columns, 53, "2026 spans 53 week columns")
    expectEqual(y2026.monthColumns[0], 0, "January column")
    expectEqual(y2026.monthColumns[1], y2026.cells.first(where: { $0.date == "2026-02-01" })?.column ?? -1, "February column")
}
if let y2024 = years.first {
    expectEqual(y2024.cells.count, 366, "leap year strip")
    expectEqual(y2024.cells.first?.row, 0, "2024-01-01 is a Monday")
}

// MARK: - TrendDay decoding (rep §10.2: keys verbatim, empty categories/statuses)
section("decode")
let json = """
{"start":"2026-10-02","end":"2026-10-03","days":[
 {"date":"2026-10-02","hasData":true,"score":70.7,"total":79.9,"categories":{"hei":70.7,"mar":80.5},"hazardCount":1,"hei":70.7,"mar":80.5,
  "intake":1915,"tdee":2296,"target":2296,"exerciseKcal":0,"energyMethod":"measured","weight":61.9,"trend":62.58,"steps":11745,"activeKcal":509,
  "completeness":"likely","totals":{"sodium_mg":2300.5},"groups":{"red_meat_g":40},"macroPct":{"protein":20.4,"satFat":12.3},"upfPct":23.7,
  "statuses":{"sodium_mg":"warn","hei_total":"good"}},
 {"date":"2026-10-03","hasData":false,"score":null,"total":null,"categories":{},"hazardCount":0,"hei":null,"mar":null,
  "intake":0,"tdee":2100,"target":2296,"exerciseKcal":0,"energyMethod":"eer","weight":null,"trend":62.5,"steps":null,"activeKcal":null,
  "completeness":"none","totals":{},"groups":{},"macroPct":{},"upfPct":0,"statuses":{}}
]}
"""
if let res = decodeFixture(TrendsResponse.self, json, "TrendsResponse") {
    expectEqual(res.days.count, 2, "two days")
    expectEqual(res.days[0].statuses["sodium_mg"], .warn, "status decoded")
    expectApprox(TrendsBucketing.metricValue(res.days[0], key: "sodium_mg"), 2300.5, "totals decoded")
    expectNil(res.days[1].score, "null score")
    let b = TrendsBucketing.bucketize(res.days, unit: .day)
    expectSeries(TrendsBucketing.scoreSeries(b), [70.7, nil], "unlogged day → gap")
}

summary()
