import SwiftUI

// MARK: - ChartLegend (web2 §4 `legendOption`): top-left row of items, each a 14×3 rounded swatch then the label
// (12 pt ink-2), 14 pt apart, wrapping. `box` items use the 10×10 rounded squares of the pass-rate card.

struct LegendItem: Hashable {
    let label: String
    let color: Color
    var dashed: Bool = false
    /// 10×10 rounded square instead of a line swatch (web `.legend i.box`).
    var box: Bool = false
}

struct ChartLegend: View {
    let items: [LegendItem]

    init(_ items: [LegendItem]) {
        self.items = items
    }

    var body: some View {
        FlowLayout(spacing: 14, lineSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    LegendSwatch(item: item)
                    Text(item.label)
                        .font(Theme.Font.legend)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A legend / tooltip swatch: 14×3 (legend), 12×3 (tooltip) or a 10×10 box.
struct LegendSwatch: View {
    let item: LegendItem
    var width: CGFloat = 14

    var body: some View {
        if item.box {
            RoundedRectangle(cornerRadius: 3).fill(item.color).frame(width: 10, height: 10)
        } else if item.dashed {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1.5).fill(item.color)
                RoundedRectangle(cornerRadius: 1.5).fill(item.color)
            }
            .frame(width: width, height: 3)
        } else {
            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: width, height: 3)
        }
    }
}

#Preview("ChartLegend") {
    DSPreviewSchemes {
        ChartLegend([
            LegendItem(label: "日评分", color: Theme.axis),
            LegendItem(label: "7 日均值", color: Theme.s1),
            LegendItem(label: "美国平均 58", color: Theme.ink3, dashed: true),
        ])
        ChartLegend([
            LegendItem(label: "达标", color: Theme.good, box: true),
            LegendItem(label: "偏离", color: Theme.warning, box: true),
            LegendItem(label: "不达标", color: Theme.critical, box: true),
        ])
    }
}
