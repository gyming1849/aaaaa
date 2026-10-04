import Foundation

// MARK: - Trends client-side logic (web2 §5.1, rep §10.3; web `pages/Trends.tsx`). Foundation only: also compiled
// into the macOS logic tests (LogicTests/Trends). Every number shown goes through `fmt`; averages and rounding copy
// the web exactly (`avg` = arithmetic mean or nil, `r1` = `Math.round(v * 10) / 10`), including its quirks:
// a logged day with a null HEI counts as 0, steps are averaged over the days that have steps, tdee/target over all days.

/// Range presets of the Seg (web2 §5.1.1). Default `.d30`.
enum TrendsRange: String, CaseIterable, Hashable, Sendable {
    case d7 = "7", d30 = "30", d90 = "90", year, d365 = "365", all, custom

    var label: String {
        switch self {
        case .d7: "7 天"
        case .d30: "30 天"
        case .d90: "90 天"
        case .year: "今年"
        case .d365: "一年"
        case .all: "全部"
        case .custom: "自定义"
        }
    }

    /// Day count of the fixed presets (`start = today − (n − 1)`).
    var dayCount: Int? {
        switch self {
        case .d7: 7
        case .d30: 30
        case .d90: 90
        case .d365: 365
        case .year, .all, .custom: nil
        }
    }
}

/// Bucket unit: span ≤ 92 → day, ≤ 400 → week, else month.
enum TrendsUnit: String, Hashable, Sendable {
    case day, week, month

    /// Header subtitle suffix.
    var zh: String {
        switch self {
        case .day: "每日"
        case .week: "每周平均"
        case .month: "每月平均"
        }
    }

    /// Nutrient-explorer hint prefix.
    var explorerZh: String {
        switch self {
        case .day: "每日"
        case .week: "每周日均"
        case .month: "每月日均"
        }
    }
}

/// One chart bucket: a day, a week (keyed by its Monday) or a month (keyed by its 1st).
struct TrendsBucket: Sendable, Identifiable {
    let key: String
    let label: String
    var days: [TrendDay]
    /// Days with `hasData == true`.
    var logged: [TrendDay]
    var id: String { key }
}

/// A horizontal target / limit line of the nutrient explorer.
struct TrendsTargetLine: Hashable, Sendable {
    enum Tone: Hashable, Sendable {
        /// `critical` colour (上限, 日均建议 ≤70).
        case limit
        /// `good` colour (理想, RDA/AI, 目标).
        case good
    }
    let name: String
    let value: Double
    let tone: Tone
}

/// One summary tile (label, big value, inline unit suffix, optional delta line).
struct TrendsSummaryTile: Hashable, Sendable {
    let label: String
    let value: String
    let unit: String
    let delta: String?
}

/// Metric shown by the nutrient explorer: display name and unit.
struct TrendsMetricInfo: Hashable, Sendable {
    let key: String
    let zh: String
    let unit: String
    /// Picker option text `{zh}（{unit}）`. A key not (yet) in `meta` has no unit: then just the key, not `key（）`.
    var optionLabel: String { unit.isEmpty ? zh : "\(zh)（\(unit)）" }
}

/// One day cell of the score calendar. `column` = week of the year strip (weeks start Monday), `row` 0 = Monday.
struct TrendsCalendarCell: Hashable, Sendable {
    let date: String
    let column: Int
    let row: Int
    /// `round(score)` for days with a HEI score, else nil (an empty `surface` cell).
    let score: Int?
}

/// A full Jan–Dec strip of the score calendar.
struct TrendsCalendarYear: Hashable, Sendable, Identifiable {
    let year: String
    let columns: Int
    let cells: [TrendsCalendarCell]
    /// Column of the 1st of each month (index 0 = January).
    let monthColumns: [Int]
    var id: String { year }
}

/// A heatmap colour piece: the label and the `Theme.seq` step it uses.
struct TrendsHeatPiece: Hashable, Sendable {
    let label: String
    let step: Int
    let min: Int
}

enum TrendsBucketing {
    // MARK: Range

    /// Default custom range: the last 60 days.
    static func defaultCustom(today: String) -> (start: String, end: String) { (LocalDay.addDays(today, -59), today) }

    /// `start`/`end` of a preset (`end = today` except for custom).
    static func bounds(_ range: TrendsRange, today: String, customStart: String, customEnd: String) -> (start: String, end: String) {
        switch range {
        case .custom: return (customStart, customEnd)
        case .year: return ("\(today.prefix(4))-01-01", today)
        case .all: return (LocalDay.addDays(today, -1095), today)
        case .d7, .d30, .d90, .d365: return (LocalDay.addDays(today, -((range.dayCount ?? 30) - 1)), today)
        }
    }

    /// `/period` start: `/period` caps ranges at 400 days, so a longer span starts at `end − 400`.
    static func periodStart(start: String, end: String) -> String {
        LocalDay.diffDays(start, end) > 400 ? LocalDay.addDays(end, -400) : start
    }

    /// 全部: drops the empty history before the first day with a record or a weigh-in.
    static func trimmed(_ days: [TrendDay], range: TrendsRange) -> [TrendDay] {
        guard range == .all, let first = days.firstIndex(where: { $0.hasData || $0.weight != nil }), first > 0 else { return days }
        return Array(days[first...])
    }

    static func unit(span: Int) -> TrendsUnit { span <= 92 ? .day : span <= 400 ? .week : .month }

    // MARK: Bucketing

    /// Bucket key of a date: the date, its week's Monday or its month's 1st.
    static func key(_ date: String, unit: TrendsUnit) -> String {
        switch unit {
        case .day: date
        case .week: LocalDay.weekStart(date)
        case .month: LocalDay.monthStart(date)
        }
    }

    /// Axis label: `M/D` for days and weeks (a week is labelled by its Monday), `YY/M月` for months (`25/3月`).
    static func label(key: String, unit: TrendsUnit) -> String {
        guard unit == .month else { return LocalDay.shortDate(key) }
        let chars = Array(key)
        guard chars.count >= 7, let month = Int(String(chars[5...6])) else { return key }
        return "\(String(chars[2...3]))/\(month)月"
    }

    /// Groups days (ascending) into buckets in first-seen order.
    static func bucketize(_ days: [TrendDay], unit: TrendsUnit) -> [TrendsBucket] {
        var buckets: [TrendsBucket] = []
        var index: [String: Int] = [:]
        for d in days {
            let k = key(d.date, unit: unit)
            let i: Int
            if let found = index[k] {
                i = found
            } else {
                i = buckets.count
                index[k] = i
                buckets.append(TrendsBucket(key: k, label: label(key: k, unit: unit), days: [], logged: []))
            }
            buckets[i].days.append(d)
            if d.hasData { buckets[i].logged.append(d) }
        }
        return buckets
    }

    // MARK: Math (web `avg`, `r1`)

    /// Arithmetic mean, or nil for an empty list.
    static func avg(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// JavaScript `Math.round`: nearest integer, ties toward +∞ (`2.5 → 3`, `-2.5 → -2`).
    static func jsRound(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let f = x.rounded(.down)
        return x - f >= 0.5 ? f + 1 : f
    }

    /// `Math.round(v * 10) / 10` with nil passthrough.
    static func r1(_ v: Double?) -> Double? {
        guard let v else { return nil }
        return jsRound(v * 10) / 10
    }

    // MARK: Chart series

    /// Chart A `膳食质量 HEI-2020`: mean HEI of the logged days (a null HEI counts as 0); nil without logged days.
    static func scoreSeries(_ buckets: [TrendsBucket]) -> [Double?] {
        buckets.map { b in r1(avg(b.logged.map { $0.score ?? 0 })) }
    }

    /// Day view only: 7-bucket trailing mean ignoring nils (nil when the whole window is nil).
    static func rolling7(_ values: [Double?]) -> [Double?] {
        values.indices.map { i in r1(avg(values[max(0, i - 6)...i].compactMap { $0 })) }
    }

    /// Chart B `摄入 vs 消耗`: intake over logged days; tdee and target over all days.
    static func energySeries(_ buckets: [TrendsBucket]) -> (intake: [Double?], tdee: [Double?], target: [Double?]) {
        (buckets.map { r1(avg($0.logged.map(\.intake))) },
         buckets.map { r1(avg($0.days.map(\.tdee))) },
         buckets.map { r1(avg($0.days.map(\.target))) })
    }

    /// Chart C `体重`: mean of the weigh-ins in the bucket, and the last non-null EMA trend of the bucket (unrounded).
    static func weightSeries(_ buckets: [TrendsBucket]) -> (raw: [Double?], trend: [Double?]) {
        (buckets.map { r1(avg($0.days.compactMap(\.weight))) },
         buckets.map { $0.days.last(where: { $0.trend != nil })?.trend })
    }

    /// Chart D: `categories[key]` (`hei` / `mar`) averaged over logged days, a missing key counting as 0.
    static func categorySeries(_ buckets: [TrendsBucket], key: String) -> [Double?] {
        buckets.map { b in r1(avg(b.logged.map { $0.categories[key] ?? 0 })) }
    }

    // MARK: Nutrient explorer

    static let defaultMetricKey = "sodium_mg"

    /// Display name and unit: a meta nutrient, else one of the extra metrics, else the raw key with no unit.
    static func metricInfo(_ key: String, nutrients: [NutrientDef]) -> TrendsMetricInfo {
        if let n = nutrients.first(where: { $0.key == key }) { return TrendsMetricInfo(key: key, zh: n.zh, unit: n.unit) }
        if let m = Vocab.trendsExtraMetrics.first(where: { $0.key == key }) { return TrendsMetricInfo(key: key, zh: m.zh, unit: m.unit) }
        return TrendsMetricInfo(key: key, zh: key, unit: "")
    }

    /// The per-day value of a metric (web `pick`).
    static func metricValue(_ d: TrendDay, key: String) -> Double? {
        if key.hasPrefix("macro:") { return d.macroPct[String(key.dropFirst(6))] ?? 0 }
        if key.hasPrefix("group:") { return d.groups[String(key.dropFirst(6))] ?? 0 }
        switch key {
        case "upf": return d.upfPct
        case "hei": return d.hei
        case "mar": return d.mar
        case "steps": return d.steps
        case "hazard": return Double(d.hazardCount)
        default: return d.totals[key] ?? 0
        }
    }

    /// Bucket means over the logged days (steps: over the days that have steps), ignoring nil values.
    static func metricSeries(_ buckets: [TrendsBucket], key: String) -> [Double?] {
        buckets.map { b in
            let src = key == "steps" ? b.days.filter { $0.steps != nil } : b.logged
            return r1(avg(src.compactMap { metricValue($0, key: key) }))
        }
    }

    /// Target / limit lines (own view only; `targets == nil` gives none).
    static func targetLines(key: String, targets: Targets?) -> [TrendsTargetLine] {
        guard let targets else { return [] }
        var lines: [TrendsTargetLine] = []
        let lim = targets.limits[key] ?? (key == "macro:satFat" ? targets.limits["sat_fat_pct"] : key == "upf" ? targets.limits["upf_pct"] : nil)
        if let lim {
            lines.append(TrendsTargetLine(name: "上限 \(fmt(lim.limit, 1))", value: lim.limit, tone: .limit))
            if lim.ideal > 0 && lim.ideal != lim.limit {
                lines.append(TrendsTargetLine(name: "理想 \(fmt(lim.ideal, 1))", value: lim.ideal, tone: .good))
            }
        } else if let intake = targets.intake[key] {
            lines.append(TrendsTargetLine(name: "\(intake.kind) \(fmt(intake.value, 1))", value: intake.value, tone: .good))
        }
        if key == "energy_kcal" {
            lines.append(TrendsTargetLine(name: "目标 \(fmt(targets.energyTarget))", value: targets.energyTarget, tone: .good))
        }
        if key == "group:red_meat_g" {
            lines.append(TrendsTargetLine(name: "日均建议 ≤70", value: 70, tone: .limit))
        }
        return lines
    }

    // MARK: Summary tiles

    /// The four tiles of section (1). `period == nil` (not loaded or failed) shows `—`.
    static func summaryTiles(days: [TrendDay], period: PeriodScore?) -> [TrendsSummaryTile] {
        let logged = days.filter(\.hasData)
        let avgScore = avg(logged.map { $0.score ?? 0 })
        let e = period?.energy
        let change: String = {
            guard let v = e?.actualChangeKg else { return "—" }
            return Fmt.signed(v, 1)
        }()
        let predicted: String = {
            guard let e else { return "—" }
            return "\(Fmt.signed(e.predictedChangeKg, 1)) kg"
        }()
        return [
            TrendsSummaryTile(label: "区间总分", value: fmt(period?.total.score), unit: "/ 100",
                              delta: "LE8 \(fmt(period?.score)) · HEI 日均 \(fmt(avgScore)) · \(logged.count)/\(days.count) 天有记录"),
            TrendsSummaryTile(label: "日均摄入 / 消耗", value: fmt(avg(logged.map(\.intake))),
                              unit: "/ \(fmt(avg(days.map(\.tdee)))) kcal", delta: nil),
            TrendsSummaryTile(label: "趋势体重变化", value: change, unit: "kg", delta: "能量差预测 \(predicted)"),
            TrendsSummaryTile(label: "按实际数据反推的日消耗",
                              value: e?.empiricalTdee.map { fmt($0) } ?? "—", unit: "kcal",
                              delta: e?.empiricalTdee != nil ? "公式估算 \(fmt(e?.avgTdee))" : "需 ≥14 天体重与较完整的记录"),
        ]
    }

    /// Weight chart hint.
    static func weightHint(period: PeriodScore?) -> String {
        guard let rate = period?.energy.ratePerWeek else { return "建议每晚睡前固定时间称重" }
        return "趋势每周 \(Fmt.signed(rate, 2)) kg（EMA 平滑，过滤每日水分波动）"
    }

    // MARK: Pass rates

    /// `itemStats` minus HEI components, sorted by the share of warn + bad days (descending, stable), first 18.
    static func passRateRows(_ stats: [ItemStat]) -> [ItemStat] {
        func ratio(_ s: ItemStat) -> Double { s.days > 0 ? Double(s.bad + s.warn) / Double(s.days) : 0 }
        return stats.enumerated()
            .filter { $0.element.category != "hei" }
            .sorted { a, b in
                let ra = ratio(a.element), rb = ratio(b.element)
                return ra != rb ? ra > rb : a.offset < b.offset
            }
            .prefix(18)
            .map(\.element)
    }

    /// Row tooltip (web `title`): `钠：达标 3 天，偏离 2 天，不达标 1 天`.
    static func passRateTitle(_ s: ItemStat) -> String {
        "\(s.zh)：达标 \(s.good + s.ok) 天，偏离 \(s.warn) 天，不达标 \(s.bad) 天"
    }

    /// Row accessibility label (web `aria-label`).
    static func passRateAccessibility(_ s: ItemStat) -> String {
        "\(s.zh) 达标 \(s.good + s.ok) 天 偏离 \(s.warn) 天 不达标 \(s.bad) 天"
    }

    // MARK: Score calendar

    /// The calendar is shown only when the (trimmed) span is at least 45 days.
    static let calendarMinSpan = 45

    /// Colour pieces, from the lowest band to the highest (the card-head legend order).
    static let heatPieces: [TrendsHeatPiece] = [
        TrendsHeatPiece(label: "<55 较差", step: 0, min: 0),
        TrendsHeatPiece(label: "55–70 一般", step: 2, min: 55),
        TrendsHeatPiece(label: "70–85 良好", step: 4, min: 70),
        TrendsHeatPiece(label: "≥85 优秀", step: 6, min: 85),
    ]

    /// The piece of a rounded score (≥85, 70–85, 55–70, <55).
    static func heatPiece(_ score: Int) -> TrendsHeatPiece {
        heatPieces.last(where: { score >= $0.min }) ?? heatPieces[0]
    }

    /// Full Jan–Dec strips for the last three distinct years in `days`; cells carry `round(score)` where a HEI exists.
    static func calendarYears(_ days: [TrendDay]) -> [TrendsCalendarYear] {
        var years: [String] = []
        for d in days {
            let y = String(d.date.prefix(4))
            if !years.contains(y) { years.append(y) }
        }
        var scores: [String: Int] = [:]
        for d in days {
            if let s = d.score, s.isFinite { scores[d.date] = Int(jsRound(s)) }
        }
        return years.suffix(3).map { calendarYear($0, scores: scores) }
    }

    /// Layout of one year strip (columns = weeks starting Monday; row 0 = Monday).
    static func calendarYear(_ year: String, scores: [String: Int]) -> TrendsCalendarYear {
        let jan1 = "\(year)-01-01"
        let origin = LocalDay.weekStart(jan1)
        let dates = LocalDay.range(jan1, "\(year)-12-31")
        var cells: [TrendsCalendarCell] = []
        cells.reserveCapacity(dates.count)
        var monthColumns = Array(repeating: 0, count: 12)
        for date in dates {
            let column = LocalDay.diffDays(origin, date) / 7
            let row = ((LocalDay.weekday(date) ?? 1) + 6) % 7
            cells.append(TrendsCalendarCell(date: date, column: column, row: row, score: scores[date]))
            if date.hasSuffix("-01"), let m = LocalDay.parts(date)?.month { monthColumns[m - 1] = column }
        }
        let columns = (cells.map(\.column).max() ?? 0) + 1
        return TrendsCalendarYear(year: year, columns: columns, cells: cells, monthColumns: monthColumns)
    }
}
