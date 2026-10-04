import SwiftUI
import Charts

// MARK: - Chart C `体重` (web2 §5.1.5 (3); web `WeightChart`)
// raw = mean of the weigh-ins in the bucket (scatter: 8 pt ink-3 dots with a 2 pt surface ring), trend = last non-null
// EMA trend of the bucket (s1 line, continuous, no points). y = floor(min − 1)…ceil(max + 1) over both series.
// No weigh-in at all → `这段时间没有体重记录` instead of the chart (even if trend values exist).

struct TrendsWeightChart: View {
    let buckets: [TrendsBucket]
    let unit: TrendsUnit
    let period: PeriodScore?

    var body: some View {
        let labels = buckets.map(\.label)
        let s = TrendsBucketing.weightSeries(buckets)
        let rows: [[ChartCell]] = buckets.indices.map { i in
            [.text(labels[i]), .number(s.raw[i]), .number(TrendsBucketing.r1(s.trend[i]))]
        }
        ChartCard(title: "体重", hint: TrendsBucketing.weightHint(period: period),
                  table: ChartTable(columns: ["日期", "称重", "趋势"], rows: rows)) {
            if s.raw.contains(where: { $0 != nil }) {
                TrendsWeightPlot(labels: labels, raw: s.raw, trend: s.trend, rawName: unit == .day ? "称重" : "平均称重")
            } else {
                EmptyState("这段时间没有体重记录")
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct TrendsWeightDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.surface).frame(width: 10, height: 10)
            Circle().fill(Theme.ink3).frame(width: 6, height: 6)
        }
    }
}

private struct TrendsWeightPlot: View {
    let labels: [String]
    let raw: [Double?]
    let trend: [Double?]
    let rawName: String
    @State private var selected: Int?

    var body: some View {
        let rawPoints = ChartSeries.continuous(label: labels, values: raw, series: rawName)
        let trendPoints = ChartSeries.continuous(label: labels, values: trend, series: "趋势（平滑）")
        let domain = ChartSeries.paddedDomain(raw + trend) ?? 0...100
        VStack(alignment: .leading, spacing: 8) {
            ChartLegend([
                LegendItem(label: rawName, color: Theme.ink3),
                LegendItem(label: "趋势（平滑）", color: Theme.s1),
            ])
            Chart {
                TrendsLineSeries(points: trendPoints, color: Theme.s1, style: TrendsChartStyle.line, yName: "kg")
                ForEach(rawPoints) { p in
                    PointMark(x: .value("日期", p.index), y: .value("kg", p.value))
                        .symbol { TrendsWeightDot() }
                }
            }
            .chartYScale(domain: domain)
            .trendsIndexXAxis(labels: labels)
            .trendsValueYAxis()
            .trendsPlotChrome()
            .chartSelectionTooltip($selected) { x in tooltip(x) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("体重"))
            .accessibilityValue(Text(accessibilitySummary))
        }
    }

    private func rows(_ i: Int) -> [ChartTooltipRow] {
        [ChartTooltipRow(color: Theme.ink3, name: rawName, value: TrendsChartStyle.value(raw[i], 1, unit: "kg")),
         ChartTooltipRow(color: Theme.s1, name: "趋势（平滑）", value: TrendsChartStyle.value(trend[i], 1, unit: "kg"))]
    }

    private func tooltip(_ x: Int) -> ChartTooltipData? {
        guard let i = ChartSelectionIndex.clamp(x, count: labels.count) else { return nil }
        return ChartTooltipData(title: labels[i], rows: rows(i))
    }

    /// VoiceOver: the most recent bucket with a weigh-in.
    private var accessibilitySummary: String {
        guard let i = raw.lastIndex(where: { $0 != nil }) else { return "" }
        return labels[i] + " " + rows(i).map { "\($0.name) \($0.value)" }.joined(separator: "，")
    }
}
