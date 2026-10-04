import SwiftUI

// MARK: - Server address (DESIGN §A.8)
// `ServerAddressSheet` is opened from the login screen's 服务器 row and RootView's unreachable state (更换服务器);
// `ServerSettingsScreen` (更多 → 服务器) reuses `ServerAddressModel` and adds the `更换服务器需要重新登录` confirmation.

/// Edit, normalise and probe a server address: `ServerConfig.normalize` → `GET <url>/api/v1/health` must answer `{ok:true}`.
@MainActor @Observable final class ServerAddressModel {
    var text: String { didSet { if text != oldValue { error = nil } } }
    private(set) var isChecking = false
    private(set) var error: String?

    init(current: URL) {
        text = ServerAddressModel.editableText(current)
    }

    /// `http://45.63.23.52:8787` is shown as typed by users: scheme kept so https stays explicit.
    static func editableText(_ url: URL) -> String { url.absoluteString }

    /// Address users can type without a scheme (`45.63.23.52:8787`); shown as the prompt.
    static var placeholder: String { ServerConfig.displayName(ServerConfig.defaultURL) }

    var normalized: URL? { ServerConfig.normalize(text) }

    func resetToDefault() { text = Self.editableText(ServerConfig.defaultURL) }

    /// Normalises and probes the address. Returns the URL to save, or nil with `error` set
    /// (`服务器地址无效` / `无法连接服务器`).
    func check() async -> URL? {
        guard !isChecking else { return nil }
        guard let url = normalized else {
            error = Self.invalidMessage
            return nil
        }
        isChecking = true
        defer { isChecking = false }
        guard await ServerConfig.probe(url) else {
            error = ServerConfig.unreachableMessage
            return nil
        }
        error = nil
        text = Self.editableText(url)
        return url
    }

    static let invalidMessage = "服务器地址无效"
    static let helpText = "填写食迹服务器的地址，例如 45.63.23.52:8787 或 https://nutrilog.example.com。保存前会先检测能否连接。"
}

/// Sheet for changing the server while signed out (login) or while the server is unreachable.
struct ServerAddressSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = ServerAddressModel(current: ServerConfig.current)
    @State private var sameServerURL: URL?
    @FocusState private var focused: Bool?

    init() {}

    var body: some View {
        SheetScaffold(title: "服务器",
                      primary: SheetAction(title: "保存", isEnabled: !model.text.trimmingCharacters(in: .whitespaces).isEmpty,
                                           isBusy: model.isChecking) { save() },
                      secondary: SheetAction(title: "取消") { dismiss() }) {
            KeyValueRow("当前服务器", ServerConfig.displayName(app.serverURL))
            ProfileField("服务器地址", help: ServerAddressModel.helpText, error: model.error) {
                ProfileTextInput("服务器地址", text: $model.text, prompt: ServerAddressModel.placeholder, field: true, focus: $focused,
                                 contentType: .URL, keyboard: .URL, submitLabel: .done, invalid: model.error != nil) {
                    save()
                }
            }
            if model.normalized != ServerConfig.defaultURL {
                Button {
                    model.resetToDefault()
                } label: {
                    Label { Text(verbatim: "恢复默认（\(ServerConfig.displayName(ServerConfig.defaultURL))）") } icon: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                .buttonStyle(.nl(.ghost, size: .sm))
            }
        }
        .onAppear { focused = true }
        .presentationDetents([.medium, .large])
        // From the unreachable screen a session is stored: it may only follow the new address when it is the same server.
        .confirmationDialog("这是同一台服务器的新地址吗？", isPresented: sameServerBinding, titleVisibility: .visible,
                            presenting: sameServerURL) { url in
            Button("是，保持登录") { apply(url, keepSession: true) }
            Button("不是，重新登录") { apply(url, keepSession: false) }
            Button("取消", role: .cancel) {}
        } message: { url in
            Text(verbatim: "将切换到 \(ServerConfig.displayName(url))。如果是另一台服务器，当前登录会在本机退出，登录凭据不会发送给新地址。")
        }
    }

    private var sameServerBinding: Binding<Bool> {
        Binding(get: { sameServerURL != nil }, set: { if !$0 { sameServerURL = nil } })
    }

    private func save() {
        focused = nil
        Task {
            guard let url = await model.check() else { return }
            if url != app.serverURL, case .unreachable = app.phase {
                sameServerURL = url
                return
            }
            apply(url, keepSession: false)
        }
    }

    private func apply(_ url: URL, keepSession: Bool) {
        Task {
            let changed = url != app.serverURL
            await app.setServerURL(url, keepSession: keepSession)
            if changed { app.toasts.show("已保存") }
            dismiss()
        }
    }
}
