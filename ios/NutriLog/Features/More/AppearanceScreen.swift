import SwiftUI

// MARK: - 外观 + AI (web `pages/Settings.tsx` card `外观`; web2 §5.5, auth §5 `ai.provider`)
// Theme is local only (UserDefaults `nl.theme`, persisted by AppState); the AI banner reflects `me.ai`.

struct AppearanceScreen: View {
    @Environment(AppState.self) private var app

    init() {}

    var body: some View {
        @Bindable var state = app
        ProfileScrollPage {
            Card {
                CardHeader("外观")
                Seg(ThemePreference.allCases.map { SegOption(value: $0, label: $0.title, icon: $0.symbol) },
                    selection: $state.themePreference)
            }
            Card {
                CardHeader("AI")
                Banner(Self.aiText(app.me?.ai), icon: "sparkles")
                Toggle(isOn: Binding(get: { app.aiConsentGranted == true }, set: { app.setAIConsent($0) })) {
                    Text(AIConsentText.toggle).font(Theme.Font.body).foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                Text(AIConsentText.toggleFooter)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Web wording: mock → setup hint; otherwise `当前使用 {model}（claude -p 命令行 | Anthropic API）`.
    static func aiText(_ ai: AIInfo?) -> String {
        guard let ai else { return "未配置 AI：使用离线关键词估算。在服务器上安装并登录 Claude Code（claude -p），或设置 ANTHROPIC_API_KEY 后重启即可启用。" }
        if ai.isMock {
            return "未配置 AI：使用离线关键词估算。在服务器上安装并登录 Claude Code（claude -p），或设置 ANTHROPIC_API_KEY 后重启即可启用。"
        }
        return "当前使用 \(ai.model)（\(ai.provider == "cli" ? "claude -p 命令行" : "Anthropic API")）"
    }
}
