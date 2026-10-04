import SwiftUI

// MARK: - B1. HighlightsCard `今日要点` (web1 §4.3 B1; rep §3.10)
// Server-rendered sentences: issues with a critical circle-x, then wins with a good circle-check in ink-2; `暂无` when both are empty.

struct TodayHighlightsCard: View {
    let top: TopLists

    var body: some View {
        Card {
            CardHeader("今日要点", hint: "风险警示、超标项、HEI 扣分最多的组分")
            if top.issues.isEmpty && top.wins.isEmpty {
                Text("暂无")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ink3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(top.issues.enumerated()), id: \.offset) { _, text in
                        row(text, symbol: "xmark.circle", color: Theme.critical, textColor: Theme.ink1, label: "问题")
                    }
                    ForEach(Array(top.wins.enumerated()), id: \.offset) { _, text in
                        row(text, symbol: "checkmark.circle", color: Theme.good, textColor: Theme.ink2, label: "做得好")
                    }
                }
                .padding(.top, -6)
            }
        }
    }

    /// Web `.issue`: 16 pt icon (3 pt top offset), 8 pt gap, 14 pt text, 6 pt vertical padding.
    private func row(_ text: String, symbol: String, color: Color, textColor: Color, label: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
                .accessibilityLabel(Text(label))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
