import SwiftUI
import Charts

// MARK: - Reference charts for the previews. They show the web2 §4 conventions with Swift Charts:
// index-based x (first/last points on the plot edges, `boundaryGap: false`), null gaps via `ChartSeries.segments`,
// symbols only for ≤ 45 points, a dashed reference line, hairline grid, `fmt(v, 1)` y labels, the custom legend and
// the axis-triggered tooltip. Bar charts use categorical x, a shaded selection band and a trailing target annotation.

struct DSPreviewLineChart: View {
    let labels: [String]
    let values: [Double?]
    @State private var selected: Int?

    var body: some View {
        let points = ChartSeries.segments(label: labels, values: values, series: "日评分")
        let symbols = ChartSeries.showsSymbols(count: labels.count)
        VStack(alignment: .leading, spacing: 8) {
            ChartLegend([
                LegendItem(label: "日评分", color: Theme.s1),
                LegendItem(label: "美国平均 58", color: Theme.ink3, dashed: true),
            ])
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("日期", p.index), y: .value("评分", p.value), series: .value("系列", p.seriesKey))
                        .foregroundStyle(Theme.s1)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if symbols || ChartSeries.isolated(points).contains(p) {
                        PointMark(x: .value("日期", p.index), y: .value("评分", p.value))
                            .foregroundStyle(Theme.s1)
                            .symbolSize(40)
                    }
                }
                RuleMark(y: .value("美国平均", 58))
                    .foregroundStyle(Theme.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXScale(domain: 0...max(1, labels.count - 1))
            .chartYScale(domain: 0...100)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    if let i = value.as(Int.self), labels.indices.contains(i) {
                        AxisValueLabel { Text(labels[i]).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hair)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(fmt(v, 1)).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.axis).frame(height: 1) }
            }
            .chartSelectionTooltip($selected) { x in
                guard let i = ChartSelectionIndex.clamp(x, count: labels.count) else { return nil }
                let v = values[i]
                return ChartTooltipData(title: labels[i], rows: [ChartTooltipRow(color: Theme.s1, name: "日评分", value: v == nil ? "无记录" : fmt(v, 1))])
            }
        }
    }
}

struct DSPreviewBarChart: View {
    let labels: [String]
    let values: [Double?]
    var limit: Double = 2300
    @State private var selected: String?

    var body: some View {
        Chart {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                if let v = values[i] {
                    BarMark(x: .value("日期", label), y: .value("钠", v), width: .ratio(0.6))
                        .foregroundStyle(Theme.s1)
                        .cornerRadius(4)
                }
            }
            RuleMark(y: .value("上限", limit))
                .foregroundStyle(Theme.critical)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .trailing) {
                    Text(verbatim: "上限 \(fmt(limit, 1))")
                        .font(Theme.Font.axis)
                        .foregroundStyle(Theme.ink2)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks { value in
                if let s = value.as(String.self), let i = labels.firstIndex(of: s), i % 5 == 0 {
                    AxisValueLabel { Text(s).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hair)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(fmt(v, 1)).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                }
            }
        }
        .chartYAxisLabel(position: .topLeading) { Text(verbatim: "mg").font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
        .chartSelectionTooltip($selected, pointer: .band(count: labels.count)) { label in
            guard let i = labels.firstIndex(of: label) else { return nil }
            let v = values[i]
            return ChartTooltipData(title: label, rows: [ChartTooltipRow(color: Theme.s1, name: "钠", value: v == nil ? "无记录" : "\(fmt(v, 1)) mg")])
        }
    }
}
