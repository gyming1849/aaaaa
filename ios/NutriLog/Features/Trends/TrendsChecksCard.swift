import SwiftUI

// MARK: - (7) `周期性指标` (web2 §5.1.5 (7); web `PassRates`, right card)
// `period.checks` in server order: StatusBadge, then `zh` (semibold), `message` (small, secondary) and
// `目标：{targetText}` (small, muted); rows separated by hairlines.

struct TrendsChecksCard: View {
    let checks: [PeriodCheck]

    var body: some View {
        Card {
            CardHeader("周期性指标", hint: "只在按周/月看才有意义的标准")
                .headingLevel(.h3)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.element.id) { i, check in
                    if i > 0 { Rectangle().fill(Theme.hair).frame(height: 1) }
                    TrendsCheckRow(check: check)
                        .padding(.vertical, 10)
                }
            }
        }
    }
}

private struct TrendsCheckRow: View {
    let check: PeriodCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusBadgeColumn(check.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.zh)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink1)
                Text(check.message)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink2)
                Text(verbatim: "目标：\(check.targetText)")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
