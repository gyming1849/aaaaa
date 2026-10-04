import SwiftUI

// MARK: - Analyzing card (web1 §5.2): spinner, `排队中…` / `Claude 正在分析` + `{elapsed}s`, pulsing staged hint
// (<8 / <30 / <70 s). iOS adds 取消, which only stops polling (the server job keeps running; toast `已取消`).

struct LogMealAnalyzingCard: View {
    let phase: JobPhase?
    let startedAt: Date
    let onCancel: @MainActor () -> Void

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                JobProgressView(title: "Claude 正在分析", phase: phase, startedAt: startedAt, hint: JobProgressView.mealHint)
                Button("取消", action: onCancel)
                    .buttonStyle(.nl(.ghost, size: .sm))
            }
        }
        .accessibilityElement(children: .contain)
    }
}
