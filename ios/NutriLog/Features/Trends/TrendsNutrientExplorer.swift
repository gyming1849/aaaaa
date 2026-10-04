import SwiftUI
import Charts

// MARK: - (4) Nutrient explorer `营养素追踪：{zh}` (web2 §5.1.5 (4); web `NutrientExplorer`)
// Metric picker (aria `选择指标`): group `营养素` = every meta nutrient `{zh}（{unit}）` in meta order, group `其他指标` =
// the 13 extra metrics. Default `sodium_mg`. Bars (s1, max 24 pt wide, rounded top) of the bucket means over logged days
// (steps: days with steps). Own view only: target / limit lines with a trailing label on a surface chip. The y-axis title
// is the unit. Tooltip: a shaded band and one row `{fmt(v, 1)} {unit}` or `无记录`.
// iOS keeps the picker visible in table mode too (the web loses it there).

struct TrendsNutrientExplorer: View {
    let buckets: [TrendsBucket]
    let unit: TrendsUnit
    let targets: Targets?
    let nutrients: [NutrientDef]
    @Binding var metricKey: String

    var body: some View {
        let info = TrendsBucketing.metricInfo(metricKey, nutrients: nutrients)
        let labels = buckets.map(\.label)
        let values = TrendsBucketing.metricSeries(buckets, key: metricKey)
        let lines = TrendsBucketing.targetLines(key: metricKey, targets: targets)
        let rows: [[ChartCell]] = buckets.indices.map { i in [.text(labels[i]), .number(values[i])] }
        ChartCard(title: "营养素追踪：\(info.zh)",
                  hint: "\(unit.explorerZh)（仅计有记录的天）；横线为你的个人目标/上限",
                  table: ChartTable(columns: ["日期", "\(info.zh) (\(info.unit))"], rows: rows)) {
            TrendsNutrientPlot(keys: buckets.map(\.key), labels: labels, values: values, lines: lines, info: info)
        }
        .accessory {
            TrendsMetricPicker(metricKey: $metricKey, nutrients: nutrients, current: info)
        }
    }
}

/// The metric menu. Shows `{zh}（{unit}）` of the current metric with a chevron.
private struct TrendsMetricPicker: View {
    @Binding var metricKey: String
    let nutrients: [NutrientDef]
    let current: TrendsMetricInfo

    private var isListed: Bool {
        nutrients.contains { $0.key == metricKey } || Vocab.trendsExtraMetrics.contains { $0.key == metricKey }
    }

    var body: some View {
        Menu {
            Picker(selection: $metricKey) {
                if !nutrients.isEmpty {
                    Section("营养素") {
                        ForEach(nutrients) { n in
                            Text(verbatim: "\(n.zh)（\(n.unit)）").tag(n.key)
                        }
                    }
                }
                Section("其他指标") {
                    ForEach(Vocab.trendsExtraMetrics, id: \.key) { m in
                        Text(verbatim: "\(m.zh)（\(m.unit)）").tag(m.key)
                    }
                }
                if !isListed {
                    Text(verbatim: current.optionLabel).tag(metricKey)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: current.optionLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .font(Theme.Font.buttonSmall)
            .foregroundStyle(Theme.ink1)
            .padding(.horizontal, 11)
            .frame(width: 240, height: 30)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("选择指标"))
        .accessibilityValue(Text(verbatim: current.optionLabel))
    }
}

private struct TrendsNutrientPlot: View {
    let keys: [String]
    let labels: [String]
    let values: [Double?]
    let lines: [TrendsTargetLine]
    let info: TrendsMetricInfo
    @State private var selected: String?

    var body: some View {
        GeometryReader { geo in
            // ECharts: 80 % of the category band (barCategoryGap 20 %), at most 24 pt. ~44 pt go to the y labels.
            let band = max(1, geo.size.width - 44) / CGFloat(max(1, keys.count))
            let barWidth = max(1, min(24, band * 0.8))
            chart(barWidth: barWidth)
        }
    }

    private func chart(barWidth: CGFloat) -> some View {
        Chart {
            ForEach(keys.indices, id: \.self) { i in
                if let v = values[i] {
                    BarMark(x: .value("日期", keys[i]), y: .value(info.zh, v), width: .fixed(barWidth))
                        .foregroundStyle(Theme.s1)
                        .cornerRadius(4, style: .continuous)
                }
            }
            ForEach(lines, id: \.self) { line in
                RuleMark(y: .value(line.name, line.value))
                    .foregroundStyle(line.tone == .limit ? Theme.critical : Theme.good)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text(verbatim: line.name)
                            .font(Theme.Font.axis)
                            .foregroundStyle(Theme.ink2)
                            .padding(.vertical, 1)
                            .padding(.horizontal, 4)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: keys)
        .trendsCategoryXAxis(keys: keys, labels: labels)
        .trendsValueYAxis()
        .chartYAxisLabel(position: .topLeading, spacing: 6) {
            Text(verbatim: info.unit).font(Theme.Font.axis).foregroundStyle(Theme.ink3)
        }
        .trendsPlotChrome()
        .chartSelectionTooltip($selected, pointer: .band(count: keys.count)) { key in tooltip(key) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("营养素追踪：\(info.zh)"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private func value(_ i: Int) -> String { TrendsChartStyle.value(values[i], 1, unit: info.unit, empty: "无记录") }

    private func tooltip(_ key: String) -> ChartTooltipData? {
        guard let i = keys.firstIndex(of: key) else { return nil }
        return ChartTooltipData(title: labels[i], rows: [ChartTooltipRow(color: Theme.s1, name: info.zh, value: value(i))])
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let i = values.lastIndex(where: { $0 != nil }) { parts.append("\(labels[i]) \(value(i))") }
        parts.append(contentsOf: lines.map(\.name))
        return parts.joined(separator: "，")
    }
}
