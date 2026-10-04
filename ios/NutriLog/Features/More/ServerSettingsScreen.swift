import SwiftUI

// MARK: - 服务器 (更多 → 服务器; DESIGN §A.8, §C.6)
// Shows the current server and its status; a new address is normalised and probed (`GET /api/v1/health`) before it is
// saved. Changing the server while signed in logs out after the `更换服务器需要重新登录` confirmation.

struct ServerSettingsScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = ServerAddressModel(current: ServerConfig.current)
    @State private var status: Status = .checking
    @State private var pendingURL: URL?
    /// The confirmed switch is running (logout, then the new address): no second confirmation meanwhile.
    @State private var switching = false
    @FocusState private var focus: Bool?

    private enum Status: Equatable { case checking, online, offline }

    init() {}

    var body: some View {
        ProfileScrollPage {
            Card {
                CardHeader("当前服务器")
                VStack(spacing: 6) {
                    KeyValueRow("地址", ServerConfig.displayName(app.serverURL))
                    KeyValueRow("状态", statusText)
                    if let config = app.authConfig, !config.server_version.isEmpty {
                        KeyValueRow("服务器版本", config.server_version)
                    }
                    if let config = app.authConfig {
                        KeyValueRow("Apple 健康同步", config.supports("health_sync") ? "支持" : "需要升级服务器")
                    }
                }
            }

            Card {
                CardHeader("更换服务器")
                ProfileField("服务器地址", help: ServerAddressModel.helpText, error: model.error) {
                    ProfileTextInput("服务器地址", text: $model.text, prompt: ServerAddressModel.placeholder, field: true, focus: $focus,
                                     contentType: .URL, keyboard: .URL, submitLabel: .done, invalid: model.error != nil) {
                        save()
                    }
                }
                HStack(spacing: 10) {
                    if model.normalized != ServerConfig.defaultURL {
                        Button {
                            model.resetToDefault()
                        } label: {
                            Label { Text("恢复默认") } icon: { Image(systemName: "arrow.counterclockwise") }
                        }
                        .buttonStyle(.nl(.ghost, size: .sm))
                    }
                    Spacer(minLength: 0)
                    ProfileSubmitButton("保存", isBusy: model.isChecking || switching) { save() }
                        .disabled(switching || model.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ProfileHelpText("更换服务器需要重新登录。不同服务器上的账号和数据互不相通。")
                .padding(.horizontal, 4)
        }
        .navigationTitle("服务器")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.serverURL) { await checkStatus() }
        .refreshable { await checkStatus() }
        .confirmationDialog("更换服务器需要重新登录", isPresented: pendingBinding, titleVisibility: .visible, presenting: pendingURL) { url in
            Button("更换并重新登录", role: .destructive) {
                guard !switching else { return }
                switching = true
                Task {
                    await app.setServerURL(url)
                    switching = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: { url in
            Text(verbatim: "将切换到 \(ServerConfig.displayName(url))，当前账号会退出登录。")
        }
    }

    private var statusText: String {
        switch status {
        case .checking: "检测中…"
        case .online: "已连接"
        case .offline: ServerConfig.unreachableMessage
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } })
    }

    private func checkStatus() async {
        status = .checking
        let ok = await ServerConfig.probe(app.serverURL)
        guard !Task.isCancelled else { return }
        status = ok ? .online : .offline
    }

    private func save() {
        guard !switching else { return }
        focus = nil
        Task {
            guard let url = await model.check() else { return }
            if url == app.serverURL {
                app.toasts.show("已保存")
                return
            }
            pendingURL = url
        }
    }
}
