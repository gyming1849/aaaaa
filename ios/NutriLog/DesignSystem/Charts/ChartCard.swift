import SwiftUI

// MARK: - ChartCard (web2 §5.1.5, Trends `ChartCard`): h3 title with an optional small muted hint under it, a right-aligned
// ghost toggle (`表格` with a table icon in chart mode, `图表` with a chart icon in table mode; per card, not persisted).
// Chart mode: the chart at 260 pt. Table mode: a table at most 300 pt tall (scrolls beyond), first column leading,
// the others trailing tabular numbers; numbers use `fmt(v, decimals)`, nil → `—`.

enum ChartCell: Hashable {
    case text(String)
    case number(Double?, decimals: Int)

    /// Web table formatting: numbers `fmt(c, 1)` by default, `null` → `—`, strings as-is.
    var display: String {
        switch self {
        case .text(let s): s
        case .number(let v, let d): fmt(v, d)
        }
    }
}

extension ChartCell {
    /// Number cell with the web's default 1 decimal.
    static func number(_ v: Double?) -> ChartCell { .number(v, decimals: 1) }
}

struct ChartTable {
    let columns: [String]
    let rows: [[ChartCell]]
}

struct ChartCard<ChartBody: View>: View {
    let title: String
    let hint: String?
    let table: ChartTable
    let height: CGFloat
    let chart: ChartBody
    /// Controls that stay visible in both modes (e.g. the nutrient explorer's metric picker), shown under the header.
    private var accessory: AnyView?
    @State private var asTable = false

    init(title: String, hint: String? = nil, table: ChartTable, height: CGFloat = 260, @ViewBuilder chart: () -> ChartBody) {
        self.title = title
        self.hint = hint
        self.table = table
        self.height = height
        self.chart = chart()
    }

    /// Adds controls under the header that remain visible in table mode.
    func accessory<A: View>(@ViewBuilder _ content: () -> A) -> ChartCard {
        var copy = self
        copy.accessory = AnyView(content())
        return copy
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Font.h3)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let hint {
                        Text(hint)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    asTable.toggle()
                } label: {
                    Image(systemName: asTable ? "chart.xyaxis.line" : "tablecells")
                    Text(asTable ? "图表" : "表格")
                }
                .buttonStyle(.nl(.ghost, size: .sm))
                .accessibilityAddTraits(asTable ? [.isSelected] : [])
            }
            if let accessory { accessory }
            if asTable {
                ChartTableView(table: table)
            } else {
                chart
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The table mode of a `ChartCard` (web `.table`): head 12.5 pt ink-3 semibold with a bottom hairline,
/// rows 13.5 pt separated by hairlines. Capped at 300 pt; scrolls when taller.
struct ChartTableView: View {
    let table: ChartTable
    var maxHeight: CGFloat = Theme.Metrics.chartTableMaxHeight

    var body: some View {
        DSHeightCap(maxHeight: maxHeight) {
            ViewThatFits(in: .vertical) {
                grid
                ScrollView(.vertical) { grid }
                    .frame(height: maxHeight)
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { i, title in
                    Text(title)
                        .font(Theme.Font.tableHead)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .gridColumnAlignment(i == 0 ? .leading : .trailing)
                }
            }
            .padding(.vertical, 8)
            Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        Text(cell.display)
                            .font(Theme.Font.meter)
                            .foregroundStyle(Theme.ink1)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: i == 0 ? nil : .infinity, alignment: i == 0 ? .leading : .trailing)
                    }
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                if r < table.rows.count - 1 {
                    Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }
}

/// Proposes at most `maxHeight` to its child even when the parent proposes an unbounded height
/// (inside a page `ScrollView`), so `ViewThatFits` can choose between the plain and the scrolling variant.
struct DSHeightCap: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let h = min(proposal.height ?? maxHeight, maxHeight)
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: h))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

#Preview("ChartCard") {
    DSPreviewSchemes {
        DSPreviewCharts.scoreCard
        DSPreviewCharts.barCard
    }
}
