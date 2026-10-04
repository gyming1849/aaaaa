import SwiftUI
import Charts

// MARK: - 近 90 天体重 (web1 §7.2 1b): `GET /trends?start={today−89}&end={today}`.
// Scatter "称重" (8 pt ink-3 dots with a 2 pt surface ring) + line "趋势（平滑）" (series-1, 2 pt, no symbols, nulls
// connected), legend top-left, y domain floor(min − 1)…ceil(max + 1) with fmt(v, 1) labels, axis tooltip.

struct BodyWeightChartCard: View {
    let days: [TrendDay]
    let isLoaded: Bool
    /// True while a screen load is in flight; a failed first load falls through to the empty state (the screen banner
    /// carries the error and 重试) instead of spinning forever.
    var isLoading = false

    var body: some View {
        Card {
            CardHeader("近 90 天体重")
            if days.contains(where: { $0.weight != nil }) {
                BodyWeightChart(days: days)
            } else if !isLoaded && isLoading {
                LoadingView()
            } else {
                EmptyState("还没有体重记录", icon: "scalemass")
            }
        }
    }
}

private struct BodyWeightChart: View {
    let labels: [String]
    let weights: [Double?]
    let trends: [Double?]
    @State private var selected: Int?

    init(days: [TrendDay]) {
        labels = days.map { BodyDates.monthDay($0.date) }
        weights = days.map(\.weight)
        trends = days.map(\.trend)
    }

    var body: some View {
        let weighPoints = ChartSeries.continuous(label: labels, values: weights, series: "称重")
        let trendPoints = ChartSeries.continuous(label: labels, values: trends, series: "趋势（平滑）")
        let domain = ChartSeries.paddedDomain(weights + trends) ?? 0...1
        VStack(alignment: .leading, spacing: 8) {
            ChartLegend([
                LegendItem(label: "称重", color: Theme.ink3),
                LegendItem(label: "趋势（平滑）", color: Theme.s1),
            ])
            Chart {
                ForEach(trendPoints) { p in
                    LineMark(x: .value("日期", p.index), y: .value("体重", p.value), series: .value("系列", p.seriesKey))
                        .foregroundStyle(Theme.s1)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(weighPoints) { p in
                    PointMark(x: .value("日期", p.index), y: .value("体重", p.value))
                        .symbol {
                            Circle()
                                .fill(Theme.ink3)
                                .frame(width: 8, height: 8)
                                .overlay { Circle().stroke(Theme.surface, lineWidth: 2) }
                        }
                }
            }
            .chartXScale(domain: 0...max(1, labels.count - 1))
            .chartYScale(domain: domain)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    if let i = value.as(Int.self), labels.indices.contains(i) {
                        AxisValueLabel { Text(verbatim: labels[i]).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hair)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(verbatim: fmt(v, 1)).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.axis).frame(height: 1) }
            }
            .chartSelectionTooltip($selected) { x in
                guard let i = ChartSelectionIndex.clamp(x, count: labels.count) else { return nil }
                return ChartTooltipData(title: labels[i], rows: [
                    ChartTooltipRow(color: Theme.ink3, name: "称重", value: weights[i].map { "\(fmt($0, 1)) kg" } ?? "—"),
                    ChartTooltipRow(color: Theme.s1, name: "趋势（平滑）", value: trends[i].map { "\(fmt($0, 1)) kg" } ?? "—"),
                ])
            }
            // VoiceOver: one summary element instead of ~180 marks read as array indices.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("体重趋势图"))
            .accessibilityValue(Text(verbatim: accessibilitySummary))
            .frame(height: 294)   // + legend ≈ the web's 320 pt chart (legend included)
        }
    }

    /// The latest weigh-in with its real date label (+ smoothed trend), then the 90-day range.
    private var accessibilitySummary: String {
        guard let i = weights.lastIndex(where: { $0 != nil }), let w = weights[i] else { return "近 90 天没有称重记录" }
        var parts = ["称重 \(fmt(w, 1)) kg"]
        if let t = trends[i] { parts.append("趋势（平滑） \(fmt(t, 1)) kg") }
        var text = labels[i] + " " + parts.joined(separator: "，")
        let values = weights.compactMap { $0 }
        if let lo = values.min(), let hi = values.max(), values.count > 1 {
            text += "；近 90 天 \(fmt(lo, 1))–\(fmt(hi, 1)) kg"
        }
        return text
    }
}
