import SwiftUI

// MARK: - (7) `各项达标天数` (web2 §5.1.5 (7); web `PassRates`, left card)
// Rows = `period.itemStats` minus HEI components, sorted by the share of warn + bad days, first 18. Each row: the name
// (128 pt, one line), a 10 pt capsule stacked bar (good + ok / warn / bad, 2 pt gaps, zero segments omitted) and
// `{good + ok}/{days}` (52 pt, trailing, muted). Tapping a row shows the web's hover title.

struct TrendsPassRatesCard: View {
    let period: PeriodScore

    var body: some View {
        let rows = TrendsBucketing.passRateRows(period.itemStats)
        Card {
            CardHeader("各项达标天数", hint: "按未达标比例排序（\(period.start) 至 \(period.end)）")
                .headingLevel(.h3)
            VStack(alignment: .leading, spacing: 10) {
                ChartLegend([
                    LegendItem(label: "达标", color: Theme.good, box: true),
                    LegendItem(label: "偏离", color: Theme.warning, box: true),
                    LegendItem(label: "不达标", color: Theme.critical, box: true),
                ])
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { stat in
                        TrendsPassRateRow(stat: stat)
                    }
                }
            }
        }
    }
}

private struct TrendsPassRateRow: View {
    let stat: ItemStat
    @State private var showsTitle = false

    var body: some View {
        let good = stat.good + stat.ok
        Button {
            showsTitle = true
        } label: {
            HStack(spacing: 10) {
                Text(stat.zh)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 128, alignment: .leading)
                TrendsStackedBar(segments: [
                    (good, Theme.good),
                    (stat.warn, Theme.warning),
                    (stat.bad, Theme.critical),
                ], total: stat.days)
                .frame(height: 10)
                .frame(maxWidth: .infinity)
                Text(verbatim: "\(good)/\(stat.days)")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 52, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsTitle) {
            Text(TrendsBucketing.passRateTitle(stat))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(TrendsBucketing.passRateAccessibility(stat)))
    }
}

/// Web `.stacked-bar`: a capsule on a `surface` track; non-zero segments sized by count / total with 2 pt gaps
/// (flex items shrink proportionally when the gaps would overflow the track).
private struct TrendsStackedBar: View {
    let segments: [(Int, Color)]
    let total: Int

    var body: some View {
        GeometryReader { geo in
            let parts = segments.filter { $0.0 > 0 }
            let gap: CGFloat = 2
            let w = geo.size.width
            let raw = parts.map { CGFloat($0.0) / CGFloat(max(1, total)) * w }
            let gaps = gap * CGFloat(max(0, parts.count - 1))
            let sum = raw.reduce(0, +)
            let scale = sum + gaps > w && sum > 0 ? max(0, w - gaps) / sum : 1
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    Rectangle().fill(part.1).frame(width: raw[i] * scale)
                }
            }
            .frame(width: w, alignment: .leading)
            .background(Theme.surface)
            .clipShape(Capsule())
        }
    }
}
