import SwiftUI

// MARK: - 修改密码 (web `pages/Settings.tsx` card `修改密码`; web2 §5.5, auth §3.9)
// `修改` is enabled only when the old password is filled in and the new one has at least 6 characters.
// The old password is trimmed by `APIClient.changePassword` (the server does not trim it). Other sessions stay signed in.

struct PasswordScreen: View {
    @Environment(AppState.self) private var app
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var busy = false
    @State private var oldError: String?
    @State private var newError: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case old, new }

    init() {}

    private var minLength: Int { max(1, app.authConfig?.min_password ?? 6) }

    private var canSubmit: Bool {
        !oldPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && newPassword.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= minLength
    }

    var body: some View {
        ProfileScrollPage {
            Card {
                ProfileField("原密码", error: oldError) {
                    ProfileSecureInput("原密码", text: $oldPassword, field: .old, focus: $focus, contentType: .password,
                                       submitLabel: .next, invalid: oldError != nil) {
                        focus = .new
                    }
                }
                ProfileField("新密码", help: "至少 \(minLength) 位", error: newError) {
                    ProfileSecureInput("新密码", text: $newPassword, field: .new, focus: $focus, contentType: .newPassword,
                                       submitLabel: .done, invalid: newError != nil) {
                        if canSubmit { submit() }
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    ProfileSubmitButton("修改", isBusy: busy) { submit() }
                        .disabled(!canSubmit)
                }
            }
            .onChange(of: oldPassword) { _, _ in oldError = nil }
            .onChange(of: newPassword) { _, _ in newError = nil }

            VStack(alignment: .leading, spacing: 8) {
                ProfileHelpText("修改密码不会让其他已登录的设备退出。如需让它们重新登录，请在“登录设备”中移除。")
                NavigationLink(value: Route.settings(.devices)) {
                    Label { Text("管理登录设备") } icon: { Image(systemName: "iphone") }
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.accentText)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = .old }
    }

    /// `POST /auth/password` → clear both fields → toast `密码已修改`; errors (`原密码不正确`, `密码至少 6 位`) are toasted.
    private func submit() {
        guard canSubmit, !busy else { return }
        focus = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await app.api.changePassword(old: oldPassword, new: newPassword)
                oldPassword = ""
                newPassword = ""
                oldError = nil
                newError = nil
                app.toasts.show("密码已修改")
            } catch {
                switch APIError.from(error).message {
                case "原密码不正确": oldError = "原密码不正确"
                case let m where m == "新密码不能为空" || m.hasPrefix("密码至少"): newError = m
                default: break
                }
                app.toasts.error(error)
            }
        }
    }
}
