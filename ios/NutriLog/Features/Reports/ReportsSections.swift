import SwiftUI

// MARK: - Reports sections (web2 §5.2.3–§5.2.4, rep §17.4). Phone layout: every grid collapses to one column,
// the hero row stacks (LE8 card, then the 2×2 tiles and the AI card).

/// Page head: the subtitle under the large navigation title, then the 周报/月报 Seg and the period pill.
struct ReportsHeader: View {
    let range: ReportsRange
    let today: String
    let onSelectKind: @MainActor (ReportsPeriodKind) -> Void
    let onShift: @MainActor (Int) -> Void

    static let subtitle = "总分由膳食质量、微量营养素、心血管健康 LE8 和防癌建议按权重合成；每周一自动生成上周报告，每月 1 日生成上月报告（含 AI 点评）"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.subtitle)
                .font(Theme.Font.subtitle)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 10, lineSpacing: 10) {
                Seg([SegOption(value: ReportsPeriodKind.week, label: ReportsPeriodKind.week.zh),
                     SegOption(value: ReportsPeriodKind.month, label: ReportsPeriodKind.month.zh)],
                    selection: Binding(get: { range.kind }, set: { onSelectKind($0) }))
                ReportsPeriodPill(range: range, today: today, onShift: onShift)
            }
        }
    }
}

/// The web `.date-nav` pill: `‹ label ›` on surface with a border, radius 10, label semibold 14 pt, ≥128 pt wide.
private struct ReportsPeriodPill: View {
    let range: ReportsRange
    let today: String
    let onShift: @MainActor (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onShift(-1)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
            .accessibilityLabel(Text("上一期"))

            Text(verbatim: range.label)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minWidth: 128, minHeight: 30)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: range.label)

            Button {
                onShift(1)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
            .disabled(!range.canGoNext(today: today))
            .accessibilityLabel(Text("下一期"))
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
        .fixedSize()
    }
}

// MARK: 1. Total tile

/// Full-width stat card: `本周总分` / `本月总分`, `fmt(total.score)` `/ 100`, then the TotalParts line.
struct ReportsTotalTile: View {
    let kind: ReportsPeriodKind
    let total: CompositeScore

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.totalLabel)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink2)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: fmt(total.score))
                            .font(Theme.Font.statValue)
                            .foregroundStyle(Theme.ink)
                        Text(verbatim: "/ 100")
                            .font(Theme.Font.statUnit)
                            .foregroundStyle(Theme.ink3)
                    }
                    .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                TotalPartsLine(total: total)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: 2. Hero row tiles

/// The 2×2 tiles next to the LE8 card: period HEI, daily HEI, daily MAR and WCRF.
struct ReportsIndexTiles: View {
    let data: PeriodScore

    var body: some View {
        StatTileGrid {
            StatTile(label: "HEI-2020（按周期总摄入）", value: fmt(data.hei?.total, 1), unit: "/ 100", delta: "美国人平均 58")
            StatTile(label: "HEI-2020 日均", value: fmt(data.avgHei, 1), unit: "/ 100")
            StatTile(label: "微量营养素 MAR 日均", value: fmt(data.avgMar), unit: "/ 100")
            StatTile(label: "防癌建议 WCRF/AICR", value: fmt(data.indices.wcrf.score, 2), unit: "/ \(DSFormat.js(data.indices.wcrf.max))")
        }
    }
}

// MARK: 4a. Weekly checks

/// `其他按周评估的指标` (hint `只标状态，不加权`): StatusBadge + bold zh + message + `目标：{targetText}`.
struct ReportsChecksCard: View {
    let checks: [PeriodCheck]

    var body: some View {
        Card {
            CardHeader("其他按周评估的指标", hint: "只标状态，不加权").headingLevel(.h3)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.element.id) { i, c in
                    HStack(alignment: .top, spacing: 12) {
                        StatusBadgeColumn(c.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.zh)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink1)
                            Text(c.message)
                                .font(Theme.Font.small)
                                .foregroundStyle(Theme.ink2)
                            Text(verbatim: "目标：\(c.targetText)")
                                .font(Theme.Font.small)
                                .foregroundStyle(Theme.ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                    if i < checks.count - 1 {
                        Rectangle().fill(Theme.hair).frame(height: 1)
                    }
                }
            }
            .padding(.top, -8)
        }
    }
}

// MARK: 4b. Energy and weight

/// `能量与体重` key/value list, a divider, then `日均关键营养` from `avgTotals`.
struct ReportsEnergyCard: View {
    let energy: PeriodEnergy
    let avgTotals: Vec

    var body: some View {
        Card {
            CardHeader("能量与体重").headingLevel(.h3)
            VStack(spacing: 6) {
                KeyValueRow("日均摄入", "\(fmt(energy.avgIntake)) kcal")
                KeyValueRow("日均消耗", "\(fmt(energy.avgTdee)) kcal")
                KeyValueRow("累计能量差", "\(Fmt.signed(energy.totalBalance)) kcal（≈ \(fmt(energy.predictedChangeKg, 2)) kg）")
                KeyValueRow("趋势体重变化", energy.actualChangeKg.map { "\(Fmt.signed($0, 2)) kg" } ?? "称重数据不足")
                KeyValueRow("反推日消耗", energy.empiricalTdee.map { "\(fmt($0)) kcal" } ?? "需 ≥14 天完整数据")
            }
            Rectangle().fill(Theme.hair).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("日均关键营养")
                    .font(Theme.Font.h3)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 6) {
                    KeyValueRow("钠", "\(fmt(avgTotals["sodium_mg"])) mg")
                    KeyValueRow("添加糖", "\(fmt(avgTotals["added_sugars_g"], 1)) g")
                    KeyValueRow("饱和脂肪", "\(fmt(avgTotals["sat_fat_g"], 1)) g")
                    KeyValueRow("膳食纤维", "\(fmt(avgTotals["fiber_g"], 1)) g")
                    KeyValueRow("蛋白质", "\(fmt(avgTotals["protein_g"], 1)) g")
                    KeyValueRow("钙 / 钾 / 维生素 D",
                                "\(fmt(avgTotals["calcium_mg"])) mg / \(fmt(avgTotals["potassium_mg"])) mg / \(fmt(avgTotals["vit_d_ug"], 1)) µg")
                }
            }
        }
    }
}

// MARK: 5. Hazards

/// `致癌物与风险物警示`: one wrapping chip per hazard — bold zh, IarcChip, ` {days} 天 · {dose} {unit}`.
struct ReportsHazardsCard: View {
    let hazards: [PeriodHazard]

    var body: some View {
        Card {
            CardHeader("致癌物与风险物警示", hint: "只作警示；加工肉、红肉、酒精、含糖饮料已计入 WCRF 评分").headingLevel(.h3)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(hazards) { h in
                    HStack(spacing: 5) {
                        Text(h.zh)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.ink1)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        IarcChip(h.iarc)
                        Text(verbatim: "\(h.days) 天 · \(fmt(h.dose)) \(h.unit)")
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(Theme.Font.chip)
                    .foregroundStyle(Theme.ink2)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: 6. HEI components

/// `HEI-2020 各组分（按周期总量计算）`: one Meter per component, status by `score / max`, hint shown until full marks.
struct ReportsHeiComponentsCard: View {
    let hei: HeiResult

    var body: some View {
        Card {
            CardHeader("HEI-2020 各组分（按周期总量计算）").headingLevel(.h3)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(hei.components) { c in
                    let ratio = c.max > 0 ? c.score / c.max : 0
                    Meter(name: c.zh, value: c.score, unit: "/ \(DSFormat.js(c.max))", max: c.max,
                          status: .ratio(c.score, max: c.max), decimals: 1,
                          foot: ratio < 0.999 ? c.hint : nil)
                }
            }
        }
    }
}
