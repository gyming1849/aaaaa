import SwiftUI
import Charts

// MARK: - Chart A `膳食质量 HEI-2020` (web2 §5.1.5 (2); web `ScoreChart`)
// score[b] = r1(mean HEI of the logged days, a null HEI counting as 0); a bucket without logged days is a gap.
// Day view: `日评分` (axis-coloured 1.5 pt line, ink-3 points) + `7 日均值` (s1, no points). Week/month: `平均评分` (s1).
// Both add the dashed `美国平均 58` reference (ink-3, excluded from the tooltip). y fixed 0…100, legend shown.

struct TrendsScoreChart: View {
    let buckets: [TrendsBucket]
    let unit: TrendsUnit

    var body: some View {
        let labels = buckets.map(\.label)
        let score = TrendsBucketing.scoreSeries(buckets)
        let rolling = unit == .day ? TrendsBucketing.rolling7(score) : nil
        let columns = ["日期", "评分"] + (rolling == nil ? [] : ["7 日均值"])
        let rows: [[ChartCell]] = buckets.indices.map { i in
            [.text(labels[i]), .number(score[i])] + (rolling.map { [ChartCell.number($0[i])] } ?? [])
        }
        ChartCard(title: "膳食质量 HEI-2020", hint: "USDA 健康饮食指数，0–100；虚线为美国人平均 58 分",
                  table: ChartTable(columns: columns, rows: rows)) {
            TrendsScorePlot(labels: labels, score: score, rolling: rolling, unit: unit)
        }
    }
}

private struct TrendsScorePlot: View {
    let labels: [String]
    let score: [Double?]
    let rolling: [Double?]?
    let unit: TrendsUnit
    @State private var selected: Int?

    private var scoreName: String { unit == .day ? "日评分" : "平均评分" }
    /// Day view: the daily line is muted (axis) with ink-3 points; otherwise the mean is the s1 series.
    private var scoreColor: Color { rolling == nil ? Theme.s1 : Theme.axis }
    /// Legend / tooltip swatch of the score series. ECharts takes both from the series `itemStyle` colour, which the web
    /// sets to ink-3 in the day view (the `lineStyle` colour `axis` only paints the line).
    private var scoreSwatch: Color { rolling == nil ? Theme.s1 : Theme.ink3 }

    var body: some View {
        let scorePoints = ChartSeries.segments(label: labels, values: score, series: scoreName)
        let rollingPoints = rolling.map { ChartSeries.segments(label: labels, values: $0, series: "7 日均值") } ?? []
        VStack(alignment: .leading, spacing: 8) {
            ChartLegend(legend)
            Chart {
                RuleMark(y: .value("美国平均", 58))
                    .foregroundStyle(Theme.ink3)
                    .lineStyle(TrendsChartStyle.dashed(1))
                TrendsLineSeries(points: scorePoints, color: scoreColor,
                                 style: StrokeStyle(lineWidth: rolling == nil ? 2 : 1.5, lineCap: .round, lineJoin: .round),
                                 yName: "评分")
                TrendsSeriesPoints(points: scorePoints, bucketCount: labels.count, color: scoreSwatch, yName: "评分")
                if !rollingPoints.isEmpty {
                    TrendsLineSeries(points: rollingPoints, color: Theme.s1, style: TrendsChartStyle.line, yName: "评分")
                    ForEach(ChartSeries.isolated(rollingPoints)) { p in
                        PointMark(x: .value("日期", p.index), y: .value("评分", p.value))
                            .foregroundStyle(Theme.s1)
                            .symbolSize(TrendsChartStyle.symbolArea)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .trendsIndexXAxis(labels: labels)
            .trendsValueYAxis(values: [0, 20, 40, 60, 80, 100])
            .trendsPlotChrome()
            .chartSelectionTooltip($selected) { x in tooltip(x) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("膳食质量 HEI-2020"))
            .accessibilityValue(Text(accessibilitySummary))
        }
    }

    private var legend: [LegendItem] {
        if rolling != nil {
            return [LegendItem(label: "日评分", color: scoreSwatch),
                    LegendItem(label: "7 日均值", color: Theme.s1),
                    LegendItem(label: "美国平均 58", color: Theme.ink3, dashed: true)]
        }
        return [LegendItem(label: scoreName, color: Theme.s1), LegendItem(label: "美国平均 58", color: Theme.ink3, dashed: true)]
    }

    private func tooltip(_ x: Int) -> ChartTooltipData? {
        guard let i = ChartSelectionIndex.clamp(x, count: labels.count) else { return nil }
        var rows = [ChartTooltipRow(color: scoreSwatch, name: scoreName, value: TrendsChartStyle.value(score[i], 1, empty: "无记录"))]
        if let rolling {
            rows.append(ChartTooltipRow(color: Theme.s1, name: "7 日均值", value: TrendsChartStyle.value(rolling[i], 1, empty: "无记录")))
        }
        return ChartTooltipData(title: labels[i], rows: rows)
    }

    /// VoiceOver: the latest bucket's values.
    private var accessibilitySummary: String {
        guard let i = labels.indices.last else { return "" }
        var parts = ["\(labels[i]) \(scoreName) \(TrendsChartStyle.value(score[i], 1, empty: "无记录"))"]
        if let rolling { parts.append("7 日均值 \(TrendsChartStyle.value(rolling[i], 1, empty: "无记录"))") }
        return parts.joined(separator: "，")
    }
}
