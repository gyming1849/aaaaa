import SwiftUI

// MARK: - (5) `每日评分日历` (web2 §5.1.5 (5); web `CalendarHeat`), shown only when the span is ≥ 45 days.
// The last three distinct years of the range, each a full Jan–Dec strip: columns = weeks, rows = weekdays (Monday
// first), Chinese month labels above (一月 … 十二月), weekday labels (一 … 日) and the year on the left. Cells are
// 14 pt high with a 2 pt `surface` gap; days without a score stay `surface`. Colour by rounded HEI score:
// ≥85 seq[6], 70–85 seq[4], 55–70 seq[2], <55 seq[0]. Total height 40 + years × 150; scrolls horizontally inside a
// minimum width of 720 pt. Tapping a cell shows the tooltip (date · `日评分` · `fmt(score)`).

struct TrendsScoreCalendar: View {
    let days: [TrendDay]

    var body: some View {
        let years = TrendsBucketing.calendarYears(days)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("每日评分日历")
                    .font(Theme.Font.h3)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                TrendsHeatLegend()
            }
            ScrollView(.horizontal, showsIndicators: true) {
                TrendsCalendarCanvas(years: years)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

/// Card-head legend: `<55 较差` `55–70 一般` `70–85 良好` `≥85 优秀`, each with a 12×12 rounded swatch.
private struct TrendsHeatLegend: View {
    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 4) {
            ForEach(TrendsBucketing.heatPieces, id: \.self) { piece in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.seq(piece.step)).frame(width: 12, height: 12)
                    Text(verbatim: piece.label)
                        .font(Theme.Font.foot)
                        .foregroundStyle(Theme.ink3)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct TrendsCalendarCanvas: View {
    let years: [TrendsCalendarYear]
    @State private var selected: TrendsCalendarCell?
    @State private var selectedYear = 0

    // Geometry copied from the ECharts calendar option: left 40, right 10, strip top 24 + i × 150, cell height 14.
    private static let left: CGFloat = 40
    private static let right: CGFloat = 10
    private static let cellHeight: CGFloat = 14
    private static let minWidth: CGFloat = 720
    private static let monthsZh = ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]
    private static let weekdaysZh = ["一", "二", "三", "四", "五", "六", "日"]

    private static func top(_ yearIndex: Int) -> CGFloat { 24 + CGFloat(yearIndex) * 150 }

    private static func cellWidth(_ year: TrendsCalendarYear, width: CGFloat) -> CGFloat {
        (width - left - right) / CGFloat(max(1, year.columns))
    }

    private var height: CGFloat { 40 + CGFloat(years.count) * 150 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in
                draw(in: &ctx, width: size.width)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in select(at: value.location, width: width) })
            .overlay(alignment: .topLeading) { tooltipOverlay(width: width) }
        }
        .frame(height: height)
        .containerRelativeFrame(.horizontal) { length, _ in max(Self.minWidth, length) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("每日评分日历"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, width: CGFloat) {
        for (yi, year) in years.enumerated() {
            let top = Self.top(yi)
            let cw = Self.cellWidth(year, width: width)
            // Cells (2 pt surface gap between neighbours).
            for cell in year.cells {
                let rect = CGRect(x: Self.left + CGFloat(cell.column) * cw, y: top + CGFloat(cell.row) * Self.cellHeight,
                                  width: cw, height: Self.cellHeight).insetBy(dx: 1, dy: 1)
                let color = cell.score.map { Theme.seq(TrendsBucketing.heatPiece($0).step) } ?? Theme.surface
                ctx.fill(Path(rect), with: .color(color))
                if cell == selected {
                    ctx.stroke(Path(rect.insetBy(dx: -0.5, dy: -0.5)), with: .color(Theme.ink), lineWidth: 1)
                }
            }
            // Month labels above the strip, at the first column of each month.
            for (m, column) in year.monthColumns.enumerated() {
                let x = Self.left + CGFloat(column) * cw
                ctx.draw(Text(verbatim: Self.monthsZh[m]).font(.system(size: 11)).foregroundStyle(Theme.ink3),
                         at: CGPoint(x: x, y: top - 4), anchor: .bottomLeading)
            }
            // Weekday labels on the left (Monday first).
            for (r, name) in Self.weekdaysZh.enumerated() {
                ctx.draw(Text(verbatim: name).font(.system(size: 10)).foregroundStyle(Theme.ink3),
                         at: CGPoint(x: Self.left - 4, y: top + (CGFloat(r) + 0.5) * Self.cellHeight), anchor: .trailing)
            }
            // Year label, vertical, left of the weekday labels.
            var yearCtx = ctx
            yearCtx.translateBy(x: Self.left - 28, y: top + 3.5 * Self.cellHeight)
            yearCtx.rotate(by: .degrees(-90))
            yearCtx.draw(Text(verbatim: year.year).font(.system(size: 12)).foregroundStyle(Theme.ink3), at: .zero, anchor: .center)
        }
    }

    // MARK: Selection

    private func select(at point: CGPoint, width: CGFloat) {
        for (yi, year) in years.enumerated() {
            let top = Self.top(yi)
            guard point.y >= top, point.y < top + 7 * Self.cellHeight, point.x >= Self.left else { continue }
            let cw = Self.cellWidth(year, width: width)
            let column = Int((point.x - Self.left) / cw)
            let row = Int((point.y - top) / Self.cellHeight)
            if let cell = year.cells.first(where: { $0.column == column && $0.row == row }), cell.score != nil {
                if cell == selected {
                    selected = nil
                } else {
                    selected = cell
                    selectedYear = yi
                }
                return
            }
        }
        selected = nil
    }

    @ViewBuilder private func tooltipOverlay(width: CGFloat) -> some View {
        if let cell = selected, let score = cell.score, years.indices.contains(selectedYear) {
            let year = years[selectedYear]
            let cw = Self.cellWidth(year, width: width)
            let x = Self.left + CGFloat(cell.column) * cw
            let y = Self.top(selectedYear) + CGFloat(cell.row + 1) * Self.cellHeight + 6
            ChartTooltip(data: ChartTooltipData(title: cell.date, rows: [
                ChartTooltipRow(color: Theme.s1, name: "日评分", value: fmt(Double(score))),
            ]))
            .offset(x: min(max(4, x - 20), max(4, width - 150)), y: y)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Accessibility

    /// Per year: how many days fall in each colour band (status is never colour-only).
    private var accessibilitySummary: String {
        years.map { year in
            let scores = year.cells.compactMap(\.score)
            let counts = TrendsBucketing.heatPieces.reversed().map { piece in
                "\(piece.label) \(scores.filter { TrendsBucketing.heatPiece($0) == piece }.count) 天"
            }
            return "\(year.year)：" + counts.joined(separator: "，")
        }
        .joined(separator: "；")
    }
}
