import SwiftUI

// MARK: - 更多 (web `pages/Settings.tsx` + mobile quick links; web2 §2.3, §5.5, DESIGN §B.2)
// Grouped list: profile header, 快捷入口, 健康数据, 设置, 关于 (隐私政策 / 联系我们, when configured), 退出登录 / 删除账号.

struct MoreScreen: View {
    @Environment(AppState.self) private var app
    @State private var confirmLogout = false
    @State private var loggingOut = false

    init() {}

    var body: some View {
        List {
            if let user = app.user {
                Section {
                    NavigationLink(value: Route.shareSettings) { profileHeader(user) }
                }
                .listRowBackground(Theme.surface)
            }

            Section("快捷入口") {
                NavigationLink(value: Route.reports) { MoreRowLabel("周期报告", icon: "doc.text", tint: Theme.s1) }
                NavigationLink(value: Route.foods) { MoreRowLabel("食物库", icon: "books.vertical", tint: Theme.s3) }
                NavigationLink(value: Route.community) { MoreRowLabel("社区", icon: "person.2", tint: Theme.s2) }
                NavigationLink(value: Route.standards(.mine)) { MoreRowLabel("标准库", icon: "book", tint: Theme.s4) }
            }
            .listRowBackground(Theme.surface)

            Section("健康数据") {
                NavigationLink(value: Route.healthSync) {
                    MoreRowLabel("Apple 健康同步", icon: "heart.text.square", tint: Theme.s5, detail: healthDetail)
                }
            }
            .listRowBackground(Theme.surface)

            Section("设置") {
                NavigationLink(value: Route.settings(.profile)) { MoreRowLabel(SettingsPage.profile.title, icon: "person.text.rectangle") }
                NavigationLink(value: Route.shareSettings) { MoreRowLabel("资料与分享", icon: "eye") }
                NavigationLink(value: Route.settings(.appearance)) {
                    MoreRowLabel(SettingsPage.appearance.title, icon: app.themePreference.symbol, detail: app.themePreference.title)
                }
                NavigationLink(value: Route.settings(.password)) { MoreRowLabel(SettingsPage.password.title, icon: "key") }
                NavigationLink(value: Route.settings(.devices)) { MoreRowLabel(SettingsPage.devices.title, icon: "iphone") }
                NavigationLink(value: Route.settings(.server)) {
                    MoreRowLabel(SettingsPage.server.title, icon: "server.rack", detail: ServerConfig.displayName(app.serverURL))
                }
                NavigationLink(value: Route.settings(.blocked)) {
                    MoreRowLabel(SettingsPage.blocked.title, icon: "hand.raised",
                                 detail: app.blocked.members.isEmpty ? nil : "\(app.blocked.members.count) 人")
                }
            }
            .listRowBackground(Theme.surface)

            if AppLinks.privacyPolicy != nil || AppLinks.supportEmail != nil {
                Section("关于") {
                    if let url = AppLinks.privacyPolicy {
                        Link(destination: url) {
                            MoreRowLabel("隐私政策", icon: "lock.shield", tint: Theme.s4, detail: nil)
                        }
                    }
                    if let email = AppLinks.supportEmail,
                       let url = AppLinks.supportMail(subject: "食迹反馈", body: "服务器：\(ServerConfig.displayName(app.serverURL))\n") {
                        Link(destination: url) {
                            MoreRowLabel("联系我们", icon: "envelope", tint: Theme.s1, detail: email)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Button(role: .destructive) {
                    confirmLogout = true
                } label: {
                    HStack {
                        Label { Text("退出登录") } icon: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                        Spacer()
                        if loggingOut { Spinner() }
                    }
                    .foregroundStyle(Theme.criticalText)
                }
                .disabled(loggingOut)
                NavigationLink(value: Route.settings(.deleteAccount)) {
                    Label { Text(SettingsPage.deleteAccount.title) } icon: { Image(systemName: "person.crop.circle.badge.xmark") }
                        .foregroundStyle(Theme.criticalText)
                }
            } footer: {
                Text(verbatim: versionText)
                    .font(Theme.Font.foot)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .tint(Theme.accent)
        .navigationTitle("更多")
        .refreshable { await app.refreshMe() }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                loggingOut = true
                Task {
                    await app.logout()
                    loggingOut = false
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func profileHeader(_ user: User) -> some View {
        HStack(spacing: 14) {
            Avatar(name: user.display_name, color: user.avatar_color, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: user.display_name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(verbatim: "@\(user.username)")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// `同步中…` / `已开启` / `未开启` from the WP9 sync status.
    private var healthDetail: String {
        let s = app.healthSync.status
        if s.isSyncing { return "同步中…" }
        if s.isEnabled { return "已开启" }
        return "未开启"
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "食迹 NutriLog \(version) (\(build))"
    }
}

/// A 更多 row: tinted SF Symbol in a rounded square, title, optional trailing detail (ink-3).
struct MoreRowLabel: View {
    let title: String
    let icon: String
    let tint: Color
    let detail: String?

    init(_ title: String, icon: String, tint: Color = Theme.accent, detail: String? = nil) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink1)
            Spacer(minLength: 8)
            if let detail {
                Text(verbatim: detail)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
