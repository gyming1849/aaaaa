import SwiftUI

// MARK: - Community member card (web2 §5.4, rep §11)
// Top row: 48 pt avatar, display name (16 pt semibold) with the accent chip `我`, and `@username`.
// Shared with the viewer: `近 14 天膳食质量（HEI-2020）` + `均分 {avg}`, the 14-bar sparkline, `连续记录 {streak} 天` with a
// flame and `最近记录 {date|—}`, and an eye chip (`这是你` / `共享了完整记录` / `只共享评分摘要`). The card is tappable:
// yourself → 今日, another member → their read-only day. Not shared: a lock row `未向你共享每日数据`, not tappable.
//
// The web shows each bar's `{date}：{score|无记录}` as a hover title. iOS uses the system long-press interaction instead:
// long-pressing a shared card previews all 14 days with those exact labels, plus 查看 / 看趋势 actions. (A custom
// long-press gesture inside a tappable card in a scroll view would compete with the tap and with scrolling.)

struct CommunityUserCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    let user: CommunityUser
    @State private var confirmBlock = false

    init(user: CommunityUser) {
        self.user = user
    }

    /// Eye-chip text for the viewer's effective access.
    static func accessText(_ user: CommunityUser) -> String {
        user.is_me ? "这是你" : user.share_detail == "full" ? "共享了完整记录" : "只共享评分摘要"
    }

    var body: some View {
        content
            .confirmationDialog("屏蔽 \(user.display_name)？", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("屏蔽", role: .destructive) {
                    app.blocked.block(user.id, label: BlockedMembersText.label(displayName: user.display_name, username: user.username))
                    app.toasts.show("已屏蔽")
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对方的卡片和公开食物将不再显示给你（仅在这台设备上）。可在“更多 → 已屏蔽的成员”中取消。")
            }
    }

    @ViewBuilder private var content: some View {
        if user.shared_with_me {
            Button(action: openDay) { card(tappable: true) }
                .buttonStyle(CommunityCardButtonStyle())
                .contextMenu {
                    Button(action: openDay) {
                        Label(user.is_me ? "查看今日" : "查看记录", systemImage: "doc.text")
                    }
                    Button(action: openTrends) {
                        Label("看趋势", systemImage: "chart.xyaxis.line")
                    }
                    moderationItems
                } preview: {
                    CommunityRecentPreview(user: user)
                }
                .accessibilityAction(named: Text("看趋势")) { openTrends() }
                .modifier(CommunityModerationActions(user: user, report: reportURL, onBlock: { confirmBlock = true }))
        } else {
            card(tappable: false)
                .contextMenu { moderationItems }
                .modifier(CommunityModerationActions(user: user, report: reportURL, onBlock: { confirmBlock = true }))
        }
    }

    /// 举报 (mail, only with a support address) and 屏蔽此用户, for other members.
    @ViewBuilder private var moderationItems: some View {
        if !user.is_me {
            if let url = reportURL {
                Button { openURL(url) } label: { Label("举报", systemImage: "exclamationmark.bubble") }
            }
            Button(role: .destructive) { confirmBlock = true } label: { Label("屏蔽此用户", systemImage: "hand.raised") }
        }
    }

    private var reportURL: URL? {
        BlockedMembersText.reportMember(username: user.username, displayName: user.display_name, server: app.serverURL)
    }

    /// Yourself → 今日 tab; another member → their read-only day (`/u/:username`).
    private func openDay() {
        if user.is_me {
            app.router.showToday(date: nil)
        } else {
            app.router.push(.memberDay(username: user.username))
        }
    }

    /// Yourself → 趋势 tab; another member → their trends (`/u/:username/trends`).
    private func openTrends() {
        if user.is_me {
            app.router.selectedTab = .trends
        } else {
            app.router.push(.memberTrends(username: user.username))
        }
    }

    private func card(tappable: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header(tappable: tappable)
                if user.shared_with_me {
                    sharedContent
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 13)).accessibilityHidden(true)
                        Text("未向你共享每日数据")
                    }
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func header(tappable: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Avatar(name: user.display_name, color: user.avatar_color, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.display_name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if user.is_me { Chip("我", style: .accent) }
                }
                Text(verbatim: "@\(user.username)")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var sharedContent: some View {
        let average = user.recentAverage
        VStack(alignment: .leading, spacing: 4) {
            CommunityRecentHeader(average: average)
            CommunitySparkline(recent: user.recent, average: average)
        }
        FlowLayout(spacing: 12, lineSpacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "flame")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.s2)
                    .accessibilityHidden(true)
                Text(verbatim: "连续记录 \(user.streak) 天")
            }
            .foregroundStyle(Theme.ink2)
            Text(verbatim: "最近记录 \(user.last_log_date ?? "—")")
                .foregroundStyle(Theme.ink3)
        }
        .font(Theme.Font.small)
        .monospacedDigit()
        Chip(Self.accessText(user), icon: "eye")
    }
}

/// VoiceOver actions matching the context menu's 举报 / 屏蔽此用户 (other members only).
private struct CommunityModerationActions: ViewModifier {
    @Environment(\.openURL) private var openURL
    let user: CommunityUser
    let report: URL?
    let onBlock: @MainActor () -> Void

    func body(content: Content) -> some View {
        if user.is_me {
            content
        } else if let report {
            content
                .accessibilityAction(named: Text("举报")) { openURL(report) }
                .accessibilityAction(named: Text("屏蔽此用户")) { onBlock() }
        } else {
            content.accessibilityAction(named: Text("屏蔽此用户")) { onBlock() }
        }
    }
}

/// Card press feedback (the web card is a plain link).
private struct CommunityCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// `近 14 天膳食质量（HEI-2020）` … `均分 {avg}`.
private struct CommunityRecentHeader: View {
    let average: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("近 14 天膳食质量（HEI-2020）")
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "均分 \(fmt(average))")
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .fixedSize()
        }
        .font(Theme.Font.small)
    }
}

// MARK: - Sparkline

/// 14 bars, 28 pt high, 2 pt gaps, equal widths, 2 pt top corners, `series-1`. Height = `max(6, score)` % of the
/// height; a null score is a 2 pt `surface-3` bar. VoiceOver reads `近 14 天平均 {avg} 分`.
struct CommunitySparkline: View {
    let recent: [RecentScore]
    let average: Double?
    var height: CGFloat = 28

    static let gap: CGFloat = 2

    /// Bar height in points for a chart `height` tall.
    static func barHeight(_ score: Double?, height: CGFloat = 28) -> CGFloat {
        guard let score, score.isFinite else { return 2 }
        return CGFloat(min(100, max(6, score))) / 100 * height
    }

    /// Per-day label, web title `${date}：${score ?? "无记录"}`.
    static func dayText(_ r: RecentScore) -> String {
        "\(r.date)：\(r.score.map { DSFormat.js($0) } ?? "无记录")"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            ForEach(Array(recent.enumerated()), id: \.offset) { _, r in
                UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 2, style: .continuous)
                    .fill(r.score == nil ? Theme.surface3 : Theme.s1)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.barHeight(r.score, height: height))
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "近 14 天平均 \(fmt(average)) 分"))
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Long-press preview

/// Context-menu preview of a member's last 14 days: the header line, a taller sparkline, and one
/// `{date}：{score|无记录}` row per day (two columns, oldest first).
private struct CommunityRecentPreview: View {
    let user: CommunityUser

    var body: some View {
        let average = user.recentAverage
        let half = (user.recent.count + 1) / 2
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(name: user.display_name, color: user.avatar_color, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(user.display_name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(verbatim: "@\(user.username)").font(Theme.Font.foot).foregroundStyle(Theme.ink3)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                CommunityRecentHeader(average: average)
                CommunitySparkline(recent: user.recent, average: average, height: 56)
            }
            if !user.recent.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    dayColumn(Array(user.recent.prefix(half)))
                    dayColumn(Array(user.recent.dropFirst(half)))
                }
            }
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
        .background(Theme.surface)
    }

    private func dayColumn(_ days: [RecentScore]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, r in
                Text(verbatim: CommunitySparkline.dayText(r))
                    .font(Theme.Font.foot)
                    .monospacedDigit()
                    .foregroundStyle(r.score == nil ? Theme.ink3 : Theme.ink1)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

private enum CommunityPreviewData {
    static let recent: [RecentScore] = (0..<14).map { i in
        RecentScore(date: LocalDay.addDays("2026-09-20", i), score: [3, 9].contains(i) ? nil : Double(48 + (i * 7) % 30))
    }
    static let me = CommunityUser(id: 1, username: "demo", display_name: "小明", avatar_color: "#2f7d5b", is_me: true,
                                  shared_with_me: true, share_detail: "full", last_log_date: "2026-10-03", streak: 5, recent: recent)
}

#Preview("Community sparkline") {
    DSPreviewSchemes {
        Card {
            CommunityRecentHeader(average: CommunityPreviewData.me.recentAverage)
            CommunitySparkline(recent: CommunityPreviewData.recent, average: CommunityPreviewData.me.recentAverage)
            Chip(CommunityUserCard.accessText(CommunityPreviewData.me), icon: "eye")
        }
        CommunityRecentPreview(user: CommunityPreviewData.me)
    }
}
