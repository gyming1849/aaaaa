import SwiftUI

// MARK: - F. DetailTabs `明细` (web1 §4.3 F; rep §3.4–§3.6, §17.2)
// Seg 全部营养素 (default) | HEI-2020 | 评分明细. The nutrient table is rendered as two-line rows (iPhone):
// line 1 = name … intake + status badge; line 2 = target (+ UL) … completion bar + percentage.

enum TodayDetailTab: String, CaseIterable, Hashable, Sendable {
    case nutrients, hei, items
    var title: String { switch self { case .nutrients: "全部营养素"; case .hei: "HEI-2020"; case .items: "评分明细" } }
}

struct TodayDetailTabs: View {
    let score: DailyScore
    let targets: Targets
    let meta: Meta?
    @State private var tab: TodayDetailTab = .nutrients

    var body: some View {
        Card {
            TodayCardHeader("明细") {
                Seg(TodayDetailTab.allCases.map { SegOption(value: $0, label: $0.title) }, selection: $tab)
            }
            switch tab {
            case .nutrients:
                if let meta {
                    TodayNutrientTable(rows: TodayNutrientRow.rows(score: score, targets: targets, nutrients: meta.nutrients))
                } else {
                    LoadingView()
                }
            case .hei:
                TodayHeiView(hei: score.hei)
            case .items:
                TodayItemsView(score: score, sources: meta?.sources ?? [])
            }
        }
    }
}

// MARK: - Nutrient table model (web `NutrientTable` row logic)

struct TodayNutrientRow: Identifiable, Sendable {
    let key: String
    let zh: String
    let en: String
    let unit: String
    let group: String
    let decimals: Int
    let value: Double
    /// Target text (may be empty), without the UL suffix.
    let target: String
    /// `UL {fmt(upper.value, decimals)}` when the UL applies to total intake.
    let ulText: String?
    /// Completion ratio (`nil` = no bar).
    let pct: Double?
    let status: ScoreStatus
    var id: String { key }

    /// One row per `meta.nutrients` entry, in that order (web1 §4.3 F per-row logic).
    static func rows(score s: DailyScore, targets t: Targets, nutrients: [NutrientDef]) -> [TodayNutrientRow] {
        nutrients.map { n in
            let v = s.totals[n.key] ?? 0
            let it = s.item(n.key)
            let intake = t.intake[n.key]
            let upper = t.upper[n.key]
            var target = ""
            var pct: Double?
            var status: ScoreStatus = .info
            if n.key == "energy_kcal" {
                target = "目标 \(fmt(s.energy.target))"
                pct = v / s.energy.target
                status = s.item("energy_balance")?.status ?? .info
            } else if let it {
                target = it.targetText
                status = it.status
                if let intake { pct = v / intake.value } else if let limit = it.limit, limit != 0 { pct = v / limit }
            } else if let intake {
                target = "≥ \(fmt(intake.value, n.decimals))（\(intake.kind)）"
                let p = v / intake.value
                pct = p
                status = p >= 1 ? .good : p >= 0.7 ? .warn : .bad
            } else if n.key == "sat_fat_g" {
                target = "≤ 10% 能量"
                status = s.item("sat_fat_pct")?.status ?? .info
            } else if let dv = n.dv, dv != 0 {
                target = "标签 DV \(fmt(dv, n.decimals))"
            }
            var ul: String?
            if let upper, upper.appliesToTotal {
                ul = "UL \(fmt(upper.value, n.decimals))"
                if v > upper.value { status = .bad }
            }
            return TodayNutrientRow(key: n.key, zh: n.zh, en: n.en, unit: n.unit, group: n.group, decimals: n.decimals,
                                    value: v, target: target, ulText: ul, pct: pct, status: status)
        }
    }
}

// MARK: - Tab 全部营养素

private struct TodayNutrientTable: View {
    let rows: [TodayNutrientRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("营养素 / 目标")
                Spacer(minLength: 8)
                Text("摄入 / 完成度 / 状态")
            }
            .font(Theme.Font.tableHead)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            TodayListDivider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i == 0 || rows[i - 1].group != row.group {
                    Text(Vocab.nutrientGroupZh[row.group] ?? row.group)
                        .font(Theme.Font.tableHead)
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface2)
                        .accessibilityAddTraits(.isHeader)
                    TodayListDivider()
                }
                TodayNutrientRowView(row: row)
                if i < rows.count - 1 { TodayListDivider() }
            }
        }
        .padding(.horizontal, -8)
    }
}

private struct TodayNutrientRowView: View {
    let row: TodayNutrientRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.zh)
                    .font(Theme.Font.meter)
                    .foregroundStyle(Theme.ink1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                (Text(verbatim: fmt(row.value, row.decimals)).foregroundStyle(Theme.ink1)
                    + Text(verbatim: " \(row.unit)").font(Theme.Font.small).foregroundStyle(Theme.ink3))
                    .font(Theme.Font.meter)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                if row.status != .info {
                    StatusBadge(row.status)
                }
            }
            if !row.target.isEmpty || row.ulText != nil || row.pct != nil {
                HStack(alignment: .center, spacing: 8) {
                    targetText
                        .font(Theme.Font.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pct = row.pct {
                        completion(pct)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var targetText: Text {
        let base = Text(verbatim: row.target).foregroundStyle(Theme.ink2)
        guard let ul = row.ulText else { return base }
        return base + Text(verbatim: " · \(ul)").foregroundStyle(Theme.ink3)
    }

    /// 6 pt bar in the status colour, width `min(100, pct×100)%`, plus muted `{fmt(pct×100)}%`.
    private func completion(_ pct: Double) -> some View {
        let fraction = pct.isFinite ? min(1, max(0, pct)) : (pct > 0 ? 1 : 0)
        return HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface3)
                    Capsule().fill(row.status.fill).frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 72, height: 6)
            Text(verbatim: "\(fmt(pct * 100))%")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 42, alignment: .trailing)
        }
        .fixedSize()
    }
}

// MARK: - Tab HEI-2020

private struct TodayHeiView: View {
    let hei: HeiResult?

    var body: some View {
        if let hei {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        stat(hei).fixedSize()
                        note
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        stat(hei)
                        note
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 22, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(hei.components) { c in
                        let r = c.max > 0 ? c.score / c.max : 0
                        Meter(name: c.zh, value: c.score, unit: "/ \(DSFormat.js(c.max))", max: c.max,
                              status: .ratio(c.score, max: c.max), decimals: 1,
                              foot: "\(fmt(c.value, 2)) \(c.unit)\(r < 0.999 ? " · \(c.hint)" : "")")
                    }
                }
            }
        } else {
            Text("摄入能量不足 200 kcal，暂不计算 HEI。")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink3)
        }
    }

    private func stat(_ hei: HeiResult) -> some View {
        TodayStat(label: "HEI-2020 总分", value: fmt(hei.total, 1), unit: "/ 100")
    }

    private var note: some View {
        Text("美国农业部与国家癌症研究所的膳食质量指数，按每 1000 kcal 的密度评分；美国人平均约 58 分。")
            .font(Theme.Font.small)
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tab 评分明细

private struct TodayItemsView: View {
    let score: DailyScore
    let sources: [SourceDef]

    private static let sections: [(key: String, title: String, withPoints: Bool)] = [
        ("hei", "HEI-2020 膳食质量（USDA 官方分值）", true),
        ("mar", "MAR 计分的 11 种微量营养素（等权）", false),
        ("adequacy", "其他营养素（对照 RDA/AI，只标状态）", false),
        ("moderation", "限量与其他标准（只标状态）", false),
        ("energy", "能量平衡（只标状态）", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Self.sections, id: \.key) { section in
                let items = score.items.filter { $0.category == section.key }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(Theme.Font.h3)
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 4)
                            if let summary = summary(section.key) {
                                Text(verbatim: summary)
                                    .font(Theme.Font.small)
                                    .foregroundStyle(Theme.ink2)
                                    .monospacedDigit()
                                    .fixedSize()
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, withPoints: section.withPoints)
                                if i < items.count - 1 { TodayListDivider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ key: String) -> String? {
        switch key {
        case "hei": score.hei.map { "\(fmt($0.total, 1)) / 100" }
        case "mar": score.mar.map { "MAR \(fmt($0.value)) / 100" }
        default: nil
        }
    }

    /// StatusBadge | message + `标准：{targetText} 依据：…` | (HEI) `{points} / {maxPoints}`.
    private func row(_ item: ScoreItem, withPoints: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusBadge(item.status)
                .frame(minWidth: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                // A summary-only share blanks every `message` (rep §1); name the item by its `zh` so the row stays readable.
                Text(item.message.isEmpty ? item.zh : item.message)
                    .font(Theme.Font.meter)
                    .foregroundStyle(Theme.ink1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(standard(item))
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .tint(Theme.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if withPoints {
                Text(verbatim: "\(fmt(item.points, 1)) / \(DSFormat.js(item.maxPoints))")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink1)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// `标准：{targetText} ` followed by the source links (`依据：…`), inline like the web.
    private func standard(_ item: ScoreItem) -> AttributedString {
        var s = AttributedString("标准：\(item.targetText) ")
        let list = SourceLinks.resolve(item.sources, in: sources)
        if !list.isEmpty { s += SourceLinks.attributed(list) }
        return s
    }
}
