import SwiftUI

// MARK: - Empty (web1 §3.3): centred 36 pt icon at 60 % opacity (default inbox = `tray`) above ink-3 text, 36 pt vertical padding.

struct EmptyState: View {
    let text: String
    let icon: String

    init(_ text: String, icon: String = "tray") {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .frame(width: 36, height: 36)
                .opacity(0.6)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Font.body)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.ink3)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Loading (web1 §3.3): spinner + "加载中…" in ink-3, centred, 48 pt padding, 10 pt gap.

struct LoadingView: View {
    let text: String

    init() { self.text = "加载中…" }

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            Spinner()
            Text(text).font(Theme.Font.body)
        }
        .foregroundStyle(Theme.ink3)
        .padding(48)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("EmptyState / LoadingView") {
    DSPreviewSchemes {
        Card { EmptyState("这一天没有记录", icon: "fork.knife") }
        Card { EmptyState("食物库里没有匹配项。可以在“食物库”里用 AI 联网查询或拍营养成分表来添加。") }
        Card { LoadingView() }
    }
}
