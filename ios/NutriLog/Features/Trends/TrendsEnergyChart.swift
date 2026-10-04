import SwiftUI
import Charts

// MARK: - Chart B `摄入 vs 消耗` (web2 §5.1.5 (2); web `EnergyChart`)
// intake = mean over logged days (gap without any); tdee and target = means over all days. Series 摄入 (s1),
// 消耗 (s2), 目标 (s3, dashed 1.5 pt, no points). y unbounded but including 0 (ECharts value-axis default);
// no y-axis unit title because the legend is shown. Tooltip values `{fmt(v)} kcal`, nil → `—`.

struct TrendsEnergyChart: View {
    let buckets: [TrendsBucket]

    var body: some View {
        let labels = buckets.map(\.label)
        let s = TrendsBucketing.energySeries(buckets)
        let rows: [[ChartCell]] = buckets.indices.map { i in
            [.text(labels[i]), .number(s.intake[i]), .number(s.tdee[i]), .number(s.target[i])]
        }
        ChartCard(title: "摄入 vs 消耗", hint: "消耗 = 静息代谢 + 活动（设备/步数/运动）+ 食物热效应",
                  table: ChartTable(columns: ["日期", "摄入", "消耗", "目标"], rows: rows)) {
            TrendsEnergyPlot(labels: labels, intake: s.intake, tdee: s.tdee, target: s.target)
        }
    }
}

private struct TrendsEnergyPlot: View {
    let labels: [String]
    let intake: [Double?]
    let tdee: [Double?]
    let target: [Double?]
    @State private var selected: Int?

    var body: some View {
        let intakePoints = ChartSeries.segments(label: labels, values: intake, series: "摄入")
        let tdeePoints = ChartSeries.segments(label: labels, values: tdee, series: "消耗")
        let targetPoints = ChartSeries.segments(label: labels, values: target, series: "目标")
        VStack(alignment: .leading, spacing: 8) {
            ChartLegend([
                LegendItem(label: "摄入", color: Theme.s1),
                LegendItem(label: "消耗", color: Theme.s2),
                LegendItem(label: "目标", color: Theme.s3, dashed: true),
            ])
            Chart {
                TrendsLineSeries(points: intakePoints, color: Theme.s1, style: TrendsChartStyle.line, yName: "kcal")
                TrendsSeriesPoints(points: intakePoints, bucketCount: labels.count, color: Theme.s1, yName: "kcal")
                TrendsLineSeries(points: tdeePoints, color: Theme.s2, style: TrendsChartStyle.line, yName: "kcal")
                TrendsSeriesPoints(points: tdeePoints, bucketCount: labels.count, color: Theme.s2, yName: "kcal")
                TrendsLineSeries(points: targetPoints, color: Theme.s3, style: TrendsChartStyle.dashed(1.5), yName: "kcal")
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .trendsIndexXAxis(labels: labels)
            .trendsValueYAxis()
            .trendsPlotChrome()
            .chartSelectionTooltip($selected) { x in tooltip(x) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("摄入 vs 消耗"))
            .accessibilityValue(Text(accessibilitySummary))
        }
    }

    private func rows(_ i: Int) -> [ChartTooltipRow] {
        [ChartTooltipRow(color: Theme.s1, name: "摄入", value: TrendsChartStyle.value(intake[i], 0, unit: "kcal")),
         ChartTooltipRow(color: Theme.s2, name: "消耗", value: TrendsChartStyle.value(tdee[i], 0, unit: "kcal")),
         ChartTooltipRow(color: Theme.s3, name: "目标", value: TrendsChartStyle.value(target[i], 0, unit: "kcal"))]
    }

    private func tooltip(_ x: Int) -> ChartTooltipData? {
        guard let i = ChartSelectionIndex.clamp(x, count: labels.count) else { return nil }
        return ChartTooltipData(title: labels[i], rows: rows(i))
    }

    private var accessibilitySummary: String {
        guard let i = labels.indices.last else { return "" }
        return labels[i] + " " + rows(i).map { "\($0.name) \($0.value)" }.joined(separator: "，")
    }
}
