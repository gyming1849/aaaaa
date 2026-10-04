import SwiftUI

// MARK: - TotalParts (web1 §3.4, web2 §5.3.4, `TotalScore.tsx`): one small secondary line explaining the composite score.
// Nothing when `total.score == nil`. avail = parts with a score; scale = 100 / max(1, Σ avail.weight);
// "{zh} {fmt(points,1)}/{fmt(weight×scale, missing.isEmpty ? 0 : 1)}" joined by " · ",
// then muted "（缺{missing.joined("、")}，其余按权重折算）" when parts are missing.

struct TotalPartsLine: View {
    let total: CompositeScore

    init(total: CompositeScore) {
        self.total = total
    }

    /// The parts text (without the missing note), exactly as the web renders it.
    static func partsText(_ total: CompositeScore) -> String {
        let avail = total.parts.filter { $0.score != nil }
        let scale = 100 / max(1, avail.reduce(0) { $0 + $1.weight })
        let d = total.missing.isEmpty ? 0 : 1
        return avail.map { "\($0.zh) \(fmt($0.points, 1))/\(fmt($0.weight * scale, d))" }.joined(separator: " · ")
    }

    /// `（缺…，其余按权重折算）`, or nil when nothing is missing.
    static func missingText(_ total: CompositeScore) -> String? {
        total.missing.isEmpty ? nil : "（缺\(total.missing.joined(separator: "、"))，其余按权重折算）"
    }

    var body: some View {
        if total.score != nil {
            Text(Self.attributed(total))
                .font(Theme.Font.small)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func attributed(_ total: CompositeScore) -> AttributedString {
        var s = AttributedString(partsText(total))
        s.foregroundColor = Theme.ink2
        if let note = missingText(total) {
            var m = AttributedString(note)
            m.foregroundColor = Theme.ink3
            s += m
        }
        return s
    }
}

#Preview("TotalPartsLine") {
    DSPreviewSchemes {
        Card {
            TotalPartsLine(total: DSPreviewData.total)
            TotalPartsLine(total: DSPreviewData.totalMissing)
            TotalPartsLine(total: CompositeScore(score: nil, parts: [], missing: []))
        }
    }
}
