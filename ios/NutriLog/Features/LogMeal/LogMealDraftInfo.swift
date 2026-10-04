import SwiftUI

// MARK: - Draft info card (web1 §5.2 Review "Draft info card", §5.4 FollowUp):
// accent summary banner, `AI 想确认：` follow-up, `估算假设（n）` disclosure and `参考来源：` links.
// Shown only when the draft has a summary or questions (the web's condition).

struct LogMealDraftInfo: View {
    let draft: MealDraft
    /// False while a photo is still uploading (an analysis cannot start yet).
    var canSubmit: Bool = true
    let onFollowUp: @MainActor (String) -> Void
    @State private var showAssumptions = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if !draft.summary.isEmpty {
                    Banner(draft.summary, icon: "sparkles", style: .accent)
                }
                if !draft.questions.isEmpty {
                    LogMealFollowUp(questions: draft.questions, canSubmit: canSubmit, onSubmit: onFollowUp)
                }
                if !draft.assumptions.isEmpty {
                    DisclosureGroup(isExpanded: $showAssumptions) {
                        LogMealBulletList(lines: draft.assumptions)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink2)
                            .padding(.top, 6)
                    } label: {
                        Text("估算假设（\(draft.assumptions.count)）")
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink2)
                    }
                    .tint(Theme.ink2)
                }
                if !draft.sources.isEmpty {
                    sources
                }
            }
        }
    }

    private var sources: some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            Image(systemName: "link")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text("参考来源：")
            ForEach(Array(draft.sources.enumerated()), id: \.offset) { _, source in
                let title = (source.title?.isEmpty == false ? source.title : nil) ?? source.url
                if let url = URL(string: source.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    Link(destination: url) {
                        Text(verbatim: title)
                            .foregroundStyle(Theme.accentText)
                            .lineLimit(1)
                    }
                } else {
                    Text(verbatim: title).lineLimit(1)
                }
            }
        }
        .font(Theme.Font.small)
        .foregroundStyle(Theme.ink2)
    }
}

/// `AI 想确认：` + questions + `补充说明后重新分析（可选）` input + `补充并重新分析` (disabled while blank).
private struct LogMealFollowUp: View {
    let questions: [String]
    let canSubmit: Bool
    let onSubmit: @MainActor (String) -> Void
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .accessibilityHidden(true)
                Text("AI 想确认：").fontWeight(.semibold)
            }
            LogMealBulletList(lines: questions)
            HStack(spacing: 8) {
                LogMealTextInput("补充说明", text: $answer, prompt: "补充说明后重新分析（可选）", size: .sm)
                Button {
                    onSubmit(answer.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Image(systemName: "arrow.clockwise")
                    Text("补充并重新分析")
                }
                .buttonStyle(.nl(.plain, size: .sm))
                .fixedSize()
                .disabled(!canSubmit || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .nlBanner(.plain)
    }
}
