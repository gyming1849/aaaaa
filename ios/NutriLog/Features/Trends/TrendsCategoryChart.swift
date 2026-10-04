import SwiftUI
import Charts

// MARK: - Chart D `膳食质量与营养素充足` (web2 §5.1.5 (3); web `CategoryChart`)
// HEI-2020 (s1) and 微量营养素 MAR (s2): `categories[key]` averaged over logged days (missing key = 0), y 0…100,
// legend shown, tooltip values `fmt(v)` (0 dp), nil → `—`.

struct TrendsCategoryChart: View {
    let buckets: [TrendsBucket]

    fileprivate struct Category {
        let key: String
        let zh: String
        let color: Color
    }

    fileprivate static let categories = [
        Category(key: "hei", zh: "HEI-2020", color: Theme.s1),
        Category(key: "mar", zh: "微量营养素 MAR", color: Theme.s2),
    ]

    var body: some View {
        let labels = buckets.map(\.label)
        let data = Self.categories.map { TrendsBucketing.categorySeries(buckets, key: $0.key) }
        let rows: [[ChartCell]] = buckets.indices.map { i in [.text(labels[i])] + data.map { ChartCell.number($0[i]) } }
        ChartCard(title: "膳食质量与营养素充足", hint: "HEI-2020 与 MAR（11 种微量营养素平均充足比），均为 0–100",
                  table: ChartTable(columns: ["日期"] + Self.categories.map(\.zh), rows: rows)) {
            TrendsCategoryPlot(labels: labels, data: data)
        }
    }
}

private struct TrendsCategoryPlot: View {
    let labels: [String]
    let data: [[Double?]]
    @State private var selected: Int?

    private var categories: [TrendsCategoryChart.Category] { TrendsCategoryChart.categories }

    var body: some View {
        let series = zip(categories, data).map { c, values in (c, ChartSeries.segments(label: labels, values: values, series: c.zh)) }
        VStack(alignment: .leading, spacing: 8) {
            ChartLegend(categories.map { LegendItem(label: $0.zh, color: $0.color) })
            Chart {
                ForEach(series, id: \.0.key) { c, points in
                    TrendsLineSeries(points: points, color: c.color, style: TrendsChartStyle.line, yName: "分")
                    TrendsSeriesPoints(points: points, bucketCount: labels.count, color: c.color, yName: "分")
                }
            }
            .chartYScale(domain: 0...100)
            .trendsIndexXAxis(labels: labels)
            .trendsValueYAxis(values: [0, 20, 40, 60, 80, 100])
            .trendsPlotChrome()
            .chartSelectionTooltip($selected) { x in tooltip(x) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("膳食质量与营养素充足"))
            .accessibilityValue(Text(accessibilitySummary))
        }
    }

    private func rows(_ i: Int) -> [ChartTooltipRow] {
        zip(categories, data).map { c, values in
            ChartTooltipRow(color: c.color, name: c.zh, value: TrendsChartStyle.value(values[i], 0))
        }
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
