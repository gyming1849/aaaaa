import SwiftUI

// MARK: - AI 点评 card (web2 §5.2.5 `AiSummary`, rep §7, §17.4)
// Header: sparkles + h2 `AI 点评`; the 生成点评 / 重新生成 button only when `daysLogged > 0` and the AI provider is not
// `mock`. Body: generating → pulsing muted progress text (+ queue state / seconds); no summary → one of three muted
// texts; otherwise headline,
// summary, wins (green check), issues (red x) and an accent `下期行动` banner.

struct ReportsAISummaryCard: View {
    let summary: WeeklySummary?
    let daysLogged: Int
    let isMockAI: Bool
    let isGenerating: Bool
    let phase: JobPhase?
    let startedAt: Date?
    let onGenerate: @MainActor () -> Void

    static let generatingText = "Claude 正在阅读本期评分数据并撰写点评…"
    static let mockText = "未配置 AI，无法生成点评。离线评分结果仍然完整可用。"
    static let promptText = "点击“生成点评”，让 Claude 根据离线评分结果给出下期最值得改进的 3–5 件事。"
    static let emptyText = "这一期没有记录。"

    /// Button gate (rep §7.1): there is data and a real AI provider.
    var canGenerate: Bool { daysLogged > 0 && !isMockAI }

    var body: some View {
        Card {
            CardHeader("AI 点评", icon: "sparkles") {
                if canGenerate { generateButton }
            }
            content
        }
    }

    private var generateButton: some View {
        Button(action: onGenerate) {
            HStack(spacing: 6) {
                if isGenerating {
                    Spinner(size: 14)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                }
                Text(summary != nil ? "重新生成" : "生成点评")
            }
        }
        .buttonStyle(.nl(.plain, size: .sm))
        .disabled(isGenerating)
    }

    @ViewBuilder private var content: some View {
        if isGenerating {
            progress
        } else if let s = summary {
            summaryView(s)
        } else {
            Text(isMockAI ? Self.mockText : daysLogged > 0 ? Self.promptText : Self.emptyText)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Web: the pulsing muted text `Claude 正在阅读本期评分数据并撰写点评…` (kept verbatim). Because generation takes
    /// 1–3 minutes and shares the AI queue, iOS adds a small line under it: `排队中…` while the job is queued, and the
    /// elapsed seconds once the job id is known.
    private var progress: some View {
        TimelineView(.periodic(from: startedAt ?? Date(), by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.generatingText)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .nlPulse()
                if phase == .queued || startedAt != nil {
                    HStack(spacing: 6) {
                        if phase == .queued { Text("排队中…") }
                        if let startedAt {
                            Text(verbatim: "\(JobProgressView.elapsed(since: startedAt, now: ctx.date))s")
                                .monospacedDigit()
                        }
                    }
                    .font(Theme.Font.small)
                }
            }
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func summaryView(_ s: WeeklySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.headline)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(s.summary)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !s.wins.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(s.wins.enumerated()), id: \.offset) { _, w in
                        issueRow(w, symbol: "checkmark.circle", color: Theme.good, label: "做得好")
                    }
                }
            }
            if !s.issues.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(s.issues.enumerated()), id: \.offset) { _, w in
                        issueRow(w, symbol: "xmark.circle", color: Theme.critical, label: "问题")
                    }
                }
            }
            if !s.actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("下期行动").fontWeight(.bold)
                    ForEach(Array(s.actions.enumerated()), id: \.offset) { _, a in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 15, height: 15)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                            Text(a)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .nlBanner(.accent)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Web `.issue` row: 16 pt icon (3 pt top margin) + 14 pt text, 6 pt vertical padding.
    private func issueRow(_ text: String, symbol: String, color: Color, label: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
                .accessibilityLabel(Text(label))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private enum ReportsAISummaryPreviewData {
    static let summary = WeeklySummary(
        headline: "蔬菜和全谷物明显不足，钠偏高",
        summary: "本周记录了 6 天，总分 64。膳食质量在中等水平，主要扣分来自蔬菜、全谷物和钠。",
        wins: ["蛋白质充足，且大多来自鱼和豆制品", "没有吃加工肉"],
        issues: ["日均钠约 3,100 mg，超过 2,300 mg 上限", "全谷物几乎为零"],
        actions: ["午餐把白米饭换成一半糙米", "每天至少一份深绿色蔬菜", "少喝汤汁，减少酱料"])
}

#Preview("ReportsAISummaryCard") {
    DSPreviewSchemes {
        ReportsAISummaryCard(summary: ReportsAISummaryPreviewData.summary, daysLogged: 6, isMockAI: false,
                             isGenerating: false, phase: nil, startedAt: nil) {}
        ReportsAISummaryCard(summary: nil, daysLogged: 6, isMockAI: false,
                             isGenerating: true, phase: .running, startedAt: Date().addingTimeInterval(-42)) {}
        ReportsAISummaryCard(summary: nil, daysLogged: 6, isMockAI: false, isGenerating: false, phase: nil, startedAt: nil) {}
        ReportsAISummaryCard(summary: nil, daysLogged: 0, isMockAI: true, isGenerating: false, phase: nil, startedAt: nil) {}
    }
}
