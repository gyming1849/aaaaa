import SwiftUI
import Charts

// MARK: - Shared Swift Charts styling for the Trends cards (web2 §4 `baseOption` / `lineSeries`)
// x: categorical labels in data order. Line charts plot the bucket index (first/last points on the plot edges,
// `boundaryGap: false`); the bar chart uses the bucket key as a category (`boundaryGap: true`). Axis line in `axis`
// colour, no ticks, 11 pt ink-3 labels thinned to at most seven. y: hairline grid, 11 pt ink-3 labels `fmt(v, 1)`.

enum TrendsChartStyle {
    /// Web line width 2 with round caps and joins.
    static let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    /// Dashed `[4, 4]` reference / target line of the given width.
    static func dashed(_ width: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: width, lineCap: .butt, dash: [4, 4]) }
    /// Point symbol area for the web's 7 pt circles.
    static let symbolArea: CGFloat = 38

    /// At most seven evenly spaced label positions out of `count` buckets (ECharts hides overlapping labels). Seven, so
    /// the 7 天 range labels every day, as the web does; longer ranges get about six.
    static func tickIndices(count: Int, maxLabels: Int = 7) -> [Int] {
        guard count > 0 else { return [] }
        let step = max(1, Int((Double(count) / Double(maxLabels)).rounded(.up)))
        return Array(stride(from: 0, to: count, by: step))
    }

    /// x domain of an index-based line chart; a single bucket sits in the middle.
    static func indexDomain(count: Int) -> ClosedRange<Int> { count <= 1 ? -1...1 : 0...(count - 1) }

    /// Tooltip value for a nullable number.
    static func value(_ v: Double?, _ d: Int, unit: String? = nil, empty: String = "—") -> String {
        guard let v, v.isFinite else { return empty }
        guard let unit, !unit.isEmpty else { return fmt(v, d) }
        return "\(fmt(v, d)) \(unit)"
    }
}

private struct TrendsAxisLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.axis)
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .fixedSize()
    }
}

extension View {
    /// Index-based categorical x axis: labels `labels[i]` at about six positions, no grid, no ticks.
    func trendsIndexXAxis(labels: [String]) -> some View {
        let ticks = TrendsChartStyle.tickIndices(count: labels.count)
        return chartXScale(domain: TrendsChartStyle.indexDomain(count: labels.count))
            .chartXAxis {
                AxisMarks(values: ticks) { value in
                    if let i = value.as(Int.self), labels.indices.contains(i) {
                        AxisValueLabel(anchor: .top, collisionResolution: .greedy) { TrendsAxisLabel(text: labels[i]) }
                    }
                }
            }
    }

    /// Category x axis keyed by bucket key, labelled with the bucket label (bar charts).
    func trendsCategoryXAxis(keys: [String], labels: [String]) -> some View {
        let ticks = Set(TrendsChartStyle.tickIndices(count: keys.count).map { keys[$0] })
        let labelFor = Dictionary(zip(keys, labels), uniquingKeysWith: { a, _ in a })
        return chartXAxis {
            AxisMarks(values: keys) { value in
                if let k = value.as(String.self), ticks.contains(k) {
                    AxisValueLabel(anchor: .top, collisionResolution: .greedy) { TrendsAxisLabel(text: labelFor[k] ?? k) }
                }
            }
        }
    }

    /// Value y axis on the leading side: hairline grid and `fmt(v, 1)` labels (no axis line, no ticks).
    func trendsValueYAxis(values: [Double]? = nil) -> some View {
        chartYAxis {
            if let values {
                AxisMarks(position: .leading, values: values) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hair)
                    AxisValueLabel { if let v = value.as(Double.self) { TrendsAxisLabel(text: fmt(v, 1)) } }
                }
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hair)
                    AxisValueLabel { if let v = value.as(Double.self) { TrendsAxisLabel(text: fmt(v, 1)) } }
                }
            }
        }
    }

    /// The x axis line (1 pt `axis`) along the bottom of the plot, plus the shared legend / tooltip defaults.
    func trendsPlotChrome() -> some View {
        chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.axis).frame(height: 1) }
            }
    }
}

/// Point marks for one null-split series: every point when the series has ≤ 45 buckets, otherwise only the points
/// that form a one-point segment (a line alone would draw nothing for them).
struct TrendsSeriesPoints: ChartContent {
    let points: [ChartPoint]
    let bucketCount: Int
    let color: Color
    let yName: String

    var body: some ChartContent {
        let shown = ChartSeries.showsSymbols(count: bucketCount) ? points : ChartSeries.isolated(points)
        ForEach(shown) { p in
            PointMark(x: .value("日期", p.index), y: .value(yName, p.value))
                .foregroundStyle(color)
                .symbolSize(TrendsChartStyle.symbolArea)
        }
    }
}

/// A line series split at nils (each run its own `series` identity, same colour).
struct TrendsLineSeries: ChartContent {
    let points: [ChartPoint]
    let color: Color
    let style: StrokeStyle
    let yName: String

    var body: some ChartContent {
        ForEach(points) { p in
            LineMark(x: .value("日期", p.index), y: .value(yName, p.value), series: .value("系列", p.seriesKey))
                .foregroundStyle(color)
                .lineStyle(style)
        }
    }
}
