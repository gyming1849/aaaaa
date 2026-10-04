import SwiftUI

// MARK: - WcrfCard (web1 §3.6, web2 §5.3.3)
// Header: shield-check icon + h2 `防癌建议 WCRF/AICR`; hint = subtitle ?? `2018 标准化评分 · 近 {windowDays} 天`.
// Summary row: `fmt(score, 2)` at 34 pt with small `/ {max}`, the muted explanation, and a chevron that collapses the list
// (aria `展开`, expanded by default). Rows: a 56 pt tabular column `—` (ink-3) or `{fmt(points,2)}/{max}` coloured
// good-text (points ≥ max), warning-text (> 0) or critical-text (0); then zh (semibold), detail (small ink-2), rule (small ink-3).

struct WcrfCard: View {
    let indices: HealthIndices
    let subtitle: String?
    @State private var expanded = true

    init(indices: HealthIndices, subtitle: String? = nil) {
        self.indices = indices
        self.subtitle = subtitle
    }

    /// Colour of a component's points column.
    static func pointsColor(_ c: WcrfComponent) -> Color {
        guard let p = c.points else { return Theme.ink3 }
        return p >= c.max ? Theme.goodText : p > 0 ? Theme.warningText : Theme.criticalText
    }

    /// `—` or `{fmt(points,2)}/{max}`.
    static func pointsText(_ c: WcrfComponent) -> String {
        guard let p = c.points else { return "—" }
        return "\(fmt(p, 2))/\(DSFormat.js(c.max))"
    }

    var body: some View {
        let w = indices.wcrf
        Card {
            CardHeader("防癌建议 WCRF/AICR", icon: "checkmark.shield", hint: subtitle ?? "2018 标准化评分 · 近 \(indices.windowDays) 天")
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: fmt(w.score, 2))
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: "/ \(DSFormat.js(w.max))")
                        .font(Theme.Font.statUnit)
                        .foregroundStyle(Theme.ink3)
                }
                .monospacedDigit()
                .fixedSize()
                .accessibilityElement(children: .combine)
                Text("7 条建议各 1 分、等权（Shams-White 2019）。“超加工食品”一条原文按研究人群三分位评分、没有绝对切点，此处只展示不计分。")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
                .accessibilityLabel(Text("展开"))
                .accessibilityAddTraits(expanded ? [.isSelected] : [])
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(w.components.enumerated()), id: \.offset) { i, c in
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: Self.pointsText(c))
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Self.pointsColor(c))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.zh).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink1)
                                Text(c.detail).font(Theme.Font.small).foregroundStyle(Theme.ink2)
                                Text(c.rule).font(Theme.Font.small).foregroundStyle(Theme.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 11)
                        .accessibilityElement(children: .combine)
                        if i < w.components.count - 1 {
                            Rectangle().fill(Theme.hair).frame(height: 1)
                        }
                    }
                }
                .padding(.top, -6)
                .transition(.opacity)
            }
        }
    }
}

#Preview("WcrfCard") {
    DSPreviewSchemes {
        WcrfCard(indices: DSPreviewData.indices)
        WcrfCard(indices: DSPreviewData.emptyIndices, subtitle: "2026-09-21 至 2026-09-27")
    }
}
