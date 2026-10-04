import SwiftUI

// MARK: - 删除账号 (App Store 5.1.1(v); DESIGN §C.5, §E.2 WP1, §D row 49)
// Password confirmation → `app.deleteAccount(password:)` (`POST /account/delete`), which wipes the local session on success.
// Servers without the endpoint answer `.unsupportedByServer`.

struct DeleteAccountScreen: View {
    @Environment(AppState.self) private var app
    @State private var password = ""
    @State private var busy = false
    @State private var passwordError: String?
    @State private var unsupported = false
    @State private var confirm = false
    @FocusState private var focus: Bool?

    init() {}

    static let warning = "删除账号会永久删除你的所有饮食、身体、运动、化验与同步数据，且无法恢复。"
    static let unsupportedMessage = "服务器暂不支持在 App 内删除账号，请联系管理员"

    /// Known up front when `/auth/config` was answered without `account_delete` (or was missing on an old server).
    private var serverLacksFeature: Bool {
        guard let config = app.authConfig else { return false }
        return !config.supports("account_delete")
    }

    private var showUnsupported: Bool { unsupported || serverLacksFeature }

    var body: some View {
        ProfileScrollPage {
            Banner(Self.warning, icon: "exclamationmark.triangle", style: .warn)

            if showUnsupported {
                Banner(Self.unsupportedMessage, icon: "info.circle")
            }

            Card {
                if let user = app.user {
                    HStack(spacing: 12) {
                        Avatar(name: user.display_name, color: user.avatar_color, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: user.display_name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(verbatim: "@\(user.username)")
                                .font(Theme.Font.small)
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ProfileField("密码", help: "请输入当前账号的密码以确认删除", error: passwordError) {
                    ProfileSecureInput("密码", text: $password, field: true, focus: $focus, contentType: .password,
                                       submitLabel: .done, invalid: passwordError != nil) {
                        requestDelete()
                    }
                }
                ProfileSubmitButton("永久删除账号", kind: .danger, isBusy: busy, block: true, icon: "trash") {
                    requestDelete()
                }
                .disabled(showUnsupported)
            }
            .onChange(of: password) { _, _ in passwordError = nil }
        }
        .navigationTitle("删除账号")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定删除账号？", isPresented: $confirm, titleVisibility: .visible) {
            Button("删除账号", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.warning)
        }
    }

    private func requestDelete() {
        guard !busy, !showUnsupported else { return }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "密码不能为空"
            app.toasts.error("密码不能为空")
            return
        }
        focus = nil
        confirm = true
    }

    private func performDelete() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await app.deleteAccount(password: password)
                app.toasts.show("账号已删除")
            } catch {
                let e = APIError.from(error)
                if e == .unsupportedByServer {
                    unsupported = true
                    app.toasts.error(Self.unsupportedMessage)
                } else {
                    if e.status == 400 { passwordError = e.message }
                    app.toasts.error(e.message)
                }
            }
        }
    }
}
