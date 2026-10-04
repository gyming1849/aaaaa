import SwiftUI

// MARK: - FlowLayout: wrapping row layout (web `flex-wrap`), used by Seg, chip rows and legends.
// Reports the width actually used (so a wrapping Seg hugs its options like the web's inline-flex),
// items in a line are vertically centred, lines are aligned leading / centre / trailing.

struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment

    init(spacing: CGFloat = 8, lineSpacing: CGFloat? = nil, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
        self.alignment = alignment
    }

    private struct Line {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var result: [Line] = []
        var line = Line()
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty && needed > maxWidth {
                result.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(i)
            line.sizes.append(size)
        }
        if !line.indices.isEmpty { result.append(line) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let ls = lines(maxWidth: maxWidth, subviews: subviews)
        guard !ls.isEmpty else { return .zero }
        let width = ls.map(\.width).max() ?? 0
        let height = ls.map(\.height).reduce(0, +) + lineSpacing * CGFloat(ls.count - 1)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ls = lines(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in ls {
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - line.width) / 2
            case .trailing: x = bounds.maxX - line.width
            default: x = bounds.minX
            }
            for (k, index) in line.indices.enumerated() {
                let size = line.sizes[k]
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

#Preview("FlowLayout") {
    DSPreviewSchemes {
        FlowLayout(spacing: 8) {
            ForEach(["主食", "蔬菜", "水果", "肉类", "禽肉", "水产", "蛋类", "奶制品", "豆制品/豆类", "坚果种子", "零食", "甜点"], id: \.self) {
                Chip($0)
            }
        }
        FlowLayout(spacing: 8, alignment: .center) {
            ForEach(["0.5 份", "1 份", "1.5 份", "2 份"], id: \.self) { Chip($0, style: $0 == "1 份" ? .selected : .plain) }
        }
    }
}
