import SwiftUI

// MARK: - StatusBadge (web1 §0.5, web2 §3.4): capsule, 12.5 pt semibold, 14 pt icon, padding 2/8/2/6,
// `…-text` on `…-soft` (info: ink-2 on surface-2). Never colour-only.

struct StatusBadge: View {
    let status: ScoreStatus
    /// Overrides the status word (web `StatusBadge text=`).
    var text: String?
    /// The MEPA table uses icon-less status pills (`✓ 1 分` / `0 分`).
    var showsIcon: Bool = true

    init(_ status: ScoreStatus) {
        self.status = status
    }

    init(_ status: ScoreStatus, text: String, showsIcon: Bool = true) {
        self.status = status
        self.text = text
        self.showsIcon = showsIcon
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: status.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Text(text ?? status.label)
                .font(Theme.Font.badge)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(status.text)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .padding(.leading, showsIcon ? 6 : 8)
        .padding(.trailing, 8)
        .background(status.soft, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A `StatusBadge` in a leading column as wide as the widest status word (`不达标`), for lists of badge + text rows
/// (周期性指标, 其他按周评估的指标): the text beside every badge then starts at the same x.
struct StatusBadgeColumn: View {
    let status: ScoreStatus

    init(_ status: ScoreStatus) {
        self.status = status
    }

    var body: some View {
        ZStack(alignment: .leading) {
            StatusBadge(.bad).hidden().accessibilityHidden(true)
            StatusBadge(status)
        }
    }
}

#Preview("StatusBadge") {
    DSPreviewSchemes {
        FlowLayout(spacing: 8) {
            ForEach(ScoreStatus.allCases, id: \.self) { StatusBadge($0) }
            StatusBadge(.good, text: "✓ 1 分", showsIcon: false)
            StatusBadge(.info, text: "0 分", showsIcon: false)
        }
    }
}
