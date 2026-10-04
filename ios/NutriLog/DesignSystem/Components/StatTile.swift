import SwiftUI

// MARK: - StatTile (web2 §3.3 `.stat-card`): a card with padding 14×16; label 13 ink-2; value 26 semibold ink with an
// inline unit (14, weight 500, ink-3, 3 pt leading margin); optional delta line 12.5 ink-3.

struct StatTile: View {
    let label: String
    let value: String
    let unit: String?
    let delta: String?
    /// Value font; the web's `.stat-card .v` is 26 pt, but some tiles print a longer text value smaller
    /// (e.g. 标准库 适用人群 at 20 pt).
    let valueFont: Font

    init(label: String, value: String, unit: String? = nil, delta: String? = nil, valueFont: Font = Theme.Font.statValue) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
        self.valueFont = valueFont
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    valueText
                    if let unit { unitText(unit) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    valueText.minimumScaleFactor(0.6)
                    if let unit { unitText(unit) }
                }
            }
            if let delta, !delta.isEmpty {
                Text(delta)
                    .font(Theme.Font.hint)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.shadow1, radius: 1, x: 0, y: 1)
                .shadow(color: Theme.shadow2, radius: 8, x: 0, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value)
            .font(valueFont)
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func unitText(_ unit: String) -> some View {
        Text(unit)
            .font(Theme.Font.statUnit)
            .foregroundStyle(Theme.ink3)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// Two-column tile grid (web `g4` on phones: 2×2 with a 10 pt gap). Tiles in a row share the row's height,
/// like the web's stretched grid cells.
struct StatTileGrid<Content: View>: View {
    let columns: Int
    let content: Content
    init(columns: Int = 2, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }
    var body: some View {
        EqualHeightGridLayout(columns: columns, spacing: Theme.Metrics.tileGap) { content }
    }
}

/// Fixed-column grid whose cells in one row get the height of the row's tallest cell.
struct EqualHeightGridLayout: Layout {
    var columns: Int = 2
    var spacing: CGFloat = 10

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return max(0, (width - spacing * (n - 1)) / n)
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let w = columnWidth(width)
        let n = max(1, columns)
        return stride(from: 0, to: subviews.count, by: n).map { start in
            subviews[start..<min(start + n, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = rowHeights(width: width, subviews: subviews)
        let height = rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = columnWidth(bounds.width)
        let n = max(1, columns)
        let rows = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (r, h) in rows.enumerated() {
            for c in 0..<n {
                let i = r * n + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (w + spacing), y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: h))
            }
            y += h + spacing
        }
    }
}

#Preview("StatTile") {
    DSPreviewSchemes {
        StatTileGrid {
            StatTile(label: "摄入", value: "1,568", unit: "kcal")
            StatTile(label: "消耗", value: "2,363", unit: "kcal")
            StatTile(label: "差额", value: "-795", unit: "kcal", delta: "≈ -103 g 体重")
            StatTile(label: "体重", value: "68.2", unit: "kg", delta: "趋势 68.5 kg（今日未称重）")
            StatTile(label: "日均摄入 / 消耗", value: "2,045", unit: "/ 2,318 kcal")
            StatTile(label: "区间总分", value: "72", unit: "/ 100", delta: "LE8 68 · HEI 日均 61 · 21/30 天有记录")
        }
    }
}
