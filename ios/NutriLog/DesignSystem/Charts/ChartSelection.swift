import SwiftUI
import Charts

// MARK: - Chart selection / tooltip (web2 §4 tooltip): axis-triggered, `chartXSelection` + a crosshair + a card.
// Card: surface background, 1 pt hair border, radius 10, padding 8×12, large shadow. Title = the x label (12 pt ink-3);
// one row per series: a 12×3 rounded swatch, the bold value first (ink, tabular), then the series name (ink-2).
// Crosshair: a 1 pt vertical line in `axis`; bar charts use a shaded band (`hair` at 40 %) instead.

struct ChartTooltipRow: Hashable, Identifiable {
    let color: Color
    let name: String
    let value: String
    var id: String { name }
}

struct ChartTooltipData: Hashable {
    let title: String
    let rows: [ChartTooltipRow]
}

enum ChartPointerStyle: Hashable {
    /// 1 pt `axis` vertical line (line charts).
    case line
    /// Shaded `hair` band one category wide (bar charts); `count` = number of x categories.
    case band(count: Int)
}

/// The tooltip card itself (usable on its own, e.g. for the calendar heatmap).
struct ChartTooltip: View {
    let data: ChartTooltipData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(data.title)
                .font(Theme.Font.foot)
                .foregroundStyle(Theme.ink3)
            ForEach(data.rows) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 12, height: 3)
                    Text(row.value)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                    Text(row.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hair, lineWidth: 1) }
        .shadow(color: Theme.shadowLarge.opacity(0.75), radius: 12, x: 0, y: 6)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct ChartSelectionOverlay<X: Plottable & Hashable>: ViewModifier {
    @Binding var selection: X?
    let pointer: ChartPointerStyle
    let content: (X) -> ChartTooltipData?

    func body(content view: Content) -> some View {
        view
            .chartXSelection(value: $selection)
            .chartOverlay(alignment: .topLeading) { proxy in
                GeometryReader { geo in
                    if let x = selection, let data = content(x), let anchor = proxy.plotFrame,
                       let pos = proxy.position(forX: x) {
                        let plot = geo[anchor]
                        let lineX = plot.minX + pos
                        ZStack(alignment: .topLeading) {
                            pointerView(plot: plot, lineX: lineX)
                            tooltip(data, lineX: lineX, plot: plot, width: geo.size.width)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder private func pointerView(plot: CGRect, lineX: CGFloat) -> some View {
        switch pointer {
        case .line:
            Rectangle()
                .fill(Theme.axis)
                .frame(width: 1, height: plot.height)
                .offset(x: lineX - 0.5, y: plot.minY)
        case .band(let count):
            let w = plot.width / CGFloat(max(1, count))
            Rectangle()
                .fill(Theme.hair.opacity(0.4))
                .frame(width: w, height: plot.height)
                .offset(x: lineX - w / 2, y: plot.minY)
        }
    }

    private func tooltip(_ data: ChartTooltipData, lineX: CGFloat, plot: CGRect, width: CGFloat) -> some View {
        // Place the card on the side of the crosshair with more room.
        let onRight = lineX < width / 2
        return HStack(spacing: 0) {
            if onRight {
                Color.clear.frame(width: max(0, lineX + 10))
                ChartTooltip(data: data)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                ChartTooltip(data: data)
                Color.clear.frame(width: max(0, width - lineX + 10))
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(y: plot.minY + 4)
    }
}

extension View {
    /// Axis-triggered selection for a Swift Chart: binds `chartXSelection` and draws the crosshair (or band)
    /// plus a tooltip card built by `content` for the selected x value (return nil to show nothing).
    func chartSelectionTooltip<X: Plottable & Hashable>(_ selection: Binding<X?>, pointer: ChartPointerStyle = .line,
                                                        content: @escaping (X) -> ChartTooltipData?) -> some View {
        modifier(ChartSelectionOverlay(selection: selection, pointer: pointer, content: content))
    }
}

/// Snaps a continuous x selection to the nearest bucket index in `0..<count` (for index-based line charts).
enum ChartSelectionIndex {
    static func clamp(_ x: Int?, count: Int) -> Int? {
        guard let x, count > 0 else { return nil }
        return min(max(x, 0), count - 1)
    }
}

#Preview("ChartTooltip") {
    DSPreviewSchemes {
        ChartTooltip(data: ChartTooltipData(title: "9/21", rows: [
            ChartTooltipRow(color: Theme.axis, name: "日评分", value: "64.2"),
            ChartTooltipRow(color: Theme.s1, name: "7 日均值", value: "61.8"),
        ]))
        DSPreviewCharts.scoreCard
    }
}
