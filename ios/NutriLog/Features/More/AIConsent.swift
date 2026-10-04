import SwiftUI
import Observation

// MARK: - Third-party AI consent (App Store 5.1.2(i); DESIGN §F.6 RB-5)
// Every AI request (AI 分析, AI 查询营养信息, AI 识别, 生成点评) sends the user's text, photos and profile / health values
// through the user's server to the AI provider Anthropic. Before the first one the user is asked once per server and
// account; the answer is stored on this device and mirrored to the server (`PUT ai/consent`, feature `ai_consent`), which
// then skips automatic AI summaries for HealthKit-syncing users without consent. A mock provider (no AI configured) sends
// nothing to a third party, so no consent is needed there. 不使用 AI keeps every manual path working.

/// UserDefaults `nl.aiConsent.<server>.<userId>` (Bool) and `….synced` (the server has this answer).
@MainActor @Observable final class AIConsentStore {
    /// Bumped on every write, so views reading `granted(…)` update.
    private(set) var revision = 0

    static let prefix = "nl.aiConsent."

    func granted(server: URL, userId: Int) -> Bool? {
        _ = revision
        return UserDefaults.standard.object(forKey: key(server, userId)) as? Bool
    }

    func isSynced(server: URL, userId: Int) -> Bool {
        UserDefaults.standard.bool(forKey: key(server, userId) + ".synced")
    }

    func set(_ granted: Bool, server: URL, userId: Int) {
        UserDefaults.standard.set(granted, forKey: key(server, userId))
        UserDefaults.standard.set(false, forKey: key(server, userId) + ".synced")
        revision += 1
    }

    /// Records that the server has `granted`, unless the answer changed meanwhile.
    func markSynced(_ granted: Bool, server: URL, userId: Int) {
        guard self.granted(server: server, userId: userId) == granted else { return }
        UserDefaults.standard.set(true, forKey: key(server, userId) + ".synced")
    }

    /// Logout (§A.9): every account's answer on every server (the server keeps its own copy).
    func wipeAll() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(Self.prefix) {
            UserDefaults.standard.removeObject(forKey: k)
        }
        revision += 1
    }

    private func key(_ server: URL, _ userId: Int) -> String {
        Self.prefix + ServerConfig.displayName(server) + "." + String(userId)
    }
}

/// An AI action waiting for the consent answer (`AppState.withAIConsent`).
struct AIConsentRequest: Identifiable {
    let id = UUID()
    let action: @MainActor () -> Void
}

enum AIConsentText {
    static let title = "使用 AI 功能前需要你的同意"
    static let body = "AI 功能会把你输入的文字、上传的照片，以及性别、年龄、体重、评分结果和健康数值（如睡眠、血压、能量消耗），经你登录的食迹服务器发送给第三方 AI 服务商 Anthropic（Claude）处理，用于估算营养、识别标签和健康截图、生成点评。不会发送你的用户名和昵称。\n\n不同意也可以手动记录（从食物库添加、手动填写）。可随时在“更多 → 外观 → AI”中更改。"
    static let allow = "同意并使用 AI"
    static let deny = "不使用 AI"
    static let toggle = "允许发送给 AI 服务商处理"
    static let toggleFooter = "开启后，AI 分析、AI 查询营养信息、AI 识别和 AI 点评会把相关文字、照片、档案与健康数值经服务器发送给第三方 Anthropic（Claude）处理；关闭后这些功能会先询问你。"
}

extension AppState {
    /// The answer for the signed-in account on this server; nil = never asked on this device.
    var aiConsentGranted: Bool? {
        guard let id = user?.id else { return nil }
        return aiConsent.granted(server: serverURL, userId: id)
    }

    /// An AI request must ask first (a real provider and no consent yet).
    var needsAIConsent: Bool { !isMockAI && aiConsentGranted != true }

    /// Runs `action` right away when no consent is needed; otherwise stores it in `request` for `.aiConsentPrompt`.
    func withAIConsent(_ request: Binding<AIConsentRequest?>, perform action: @escaping @MainActor () -> Void) {
        if needsAIConsent {
            request.wrappedValue = AIConsentRequest(action: action)
        } else {
            action()
        }
    }

    /// Stores the answer and mirrors it to the server in the background.
    func setAIConsent(_ granted: Bool) {
        guard let id = user?.id else { return }
        let server = serverURL
        aiConsent.set(granted, server: server, userId: id)
        Task { await self.pushAIConsent(server: server, userId: id) }
    }

    /// After a session is ready: sends an answer the server does not have yet (offline earlier, or the server was upgraded).
    func pushAIConsentIfNeeded() async {
        guard let id = user?.id else { return }
        await pushAIConsent(server: serverURL, userId: id)
    }

    private func pushAIConsent(server: URL, userId: Int) async {
        guard authConfig?.supports("ai_consent") == true,
              let granted = aiConsent.granted(server: server, userId: userId),
              !aiConsent.isSynced(server: server, userId: userId),
              await api.baseURL == server, user?.id == userId else { return }
        do {
            try await api.setAIConsent(granted)
            aiConsent.markSynced(granted, server: server, userId: userId)
        } catch {
            AppLog.app.notice("ai/consent not saved on the server: \(APIError.from(error).message, privacy: .public)")
        }
    }
}

extension View {
    /// Shows the third-party AI consent alert for a request made with `AppState.withAIConsent`.
    func aiConsentPrompt(_ request: Binding<AIConsentRequest?>) -> some View { modifier(AIConsentPrompt(request: request)) }
}

private struct AIConsentPrompt: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @Binding var request: AIConsentRequest?

    func body(content: Content) -> some View {
        content.alert(AIConsentText.title, isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                      presenting: request) { pending in
            Button(AIConsentText.allow) {
                app.setAIConsent(true)
                pending.action()
            }
            if let url = AppLinks.privacyPolicy {
                Button("查看隐私政策") { openURL(url) }
            }
            Button(AIConsentText.deny, role: .cancel) { app.setAIConsent(false) }
        } message: { _ in
            Text(AIConsentText.body)
        }
    }
}
