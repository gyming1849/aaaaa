import SwiftUI

// MARK: - Login / Register 登录注册 (web `pages/Login.tsx`; web2 §5.8, auth §6, DESIGN §D rows 1–2, §A.8)
// Phone layout: the accent art panel stacked on top, then the form card, then the 服务器 row.

struct LoginScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = LoginModel()
    @State private var showServerSheet = false
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: LoginModel.Field?

    init() {}

    var body: some View {
        page.tint(Theme.accent)
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 0) {
                LoginArtPanel()
                VStack(spacing: 18) {
                    formCard
                    serverRow
                }
                .padding(.horizontal, Theme.Metrics.pagePadding)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .background(Theme.page)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(alignment: .top) {
            // The accent panel extends under the status bar; the rest of the page is paper.
            VStack(spacing: 0) {
                Theme.accent.frame(height: 400)
                Theme.page
            }
            .ignoresSafeArea()
        }
        .task { if app.authConfig == nil { await app.loadAuthConfig() } }
        .sheet(isPresented: $showServerSheet) {
            ServerAddressSheet().toastOverlay(app.toasts)
        }
    }

    // MARK: Form

    private var formCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(model.subtitle)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            }

            if model.isRegister, model.registrationClosed(app.authConfig) {
                Banner("当前站点已关闭注册", icon: "lock", style: .warn)
            }

            ProfileField("用户名", error: model.error(.username)) {
                ProfileTextInput("用户名", text: $model.username, field: .username, focus: $focus,
                                 contentType: .username, invalid: model.error(.username) != nil) {
                    focus = model.isRegister ? .displayName : .password
                }
            }

            if model.isRegister {
                ProfileField("昵称（其他成员看到的名字）") {
                    ProfileTextInput("昵称（其他成员看到的名字）", text: $model.displayName, field: .displayName, focus: $focus,
                                     contentType: .nickname, maxLength: 32) {
                        focus = .password
                    }
                }
            }

            ProfileField("密码", error: model.error(.password)) {
                ProfileSecureInput("密码", text: $model.password, field: .password, focus: $focus,
                                   contentType: model.isRegister ? .newPassword : .password,
                                   submitLabel: model.isRegister && model.showsInviteField(app.authConfig) ? .next : .go,
                                   invalid: model.error(.password) != nil) {
                    if model.isRegister && model.showsInviteField(app.authConfig) {
                        focus = .inviteCode
                    } else {
                        submit()
                    }
                }
            }

            if model.isRegister, model.showsInviteField(app.authConfig) {
                ProfileField("邀请码（站点设置了才需要）", error: model.error(.inviteCode)) {
                    ProfileTextInput("邀请码（站点设置了才需要）", text: $model.inviteCode, field: .inviteCode, focus: $focus,
                                     contentType: .oneTimeCode, submitLabel: .go, invalid: model.error(.inviteCode) != nil) {
                        submit()
                    }
                }
            }

            VStack(spacing: 8) {
                ProfileSubmitButton(model.submitTitle, isBusy: model.isBusy, block: true) { submit() }
                    .disabled(model.isRegister && model.registrationClosed(app.authConfig))
                Button(model.toggleTitle) {
                    withAnimation(.easeInOut(duration: 0.2)) { model.toggleMode() }
                    focus = nil
                }
                .buttonStyle(.nl(.ghost, block: true))
                .disabled(model.isBusy)
                if let url = AppLinks.privacyPolicy {
                    policyNote(url)
                }
            }
            .padding(.top, 4)
        }
    }

    /// `注册即表示你已阅读并同意《隐私政策》` (login: `登录即…`), shown in both modes (DESIGN §F.6 RB-3).
    private func policyNote(_ url: URL) -> some View {
        var text = AttributedString(model.isRegister ? "注册即表示你已阅读并同意" : "登录即表示你已阅读并同意")
        var link = AttributedString("《隐私政策》")
        link.link = url
        link.foregroundColor = Theme.accentText
        text += link
        return Text(text)
            .font(Theme.Font.small)
            .foregroundStyle(Theme.ink3)
            .tint(Theme.accentText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAction(named: Text("打开隐私政策")) { openURL(url) }
    }

    /// `服务器：45.63.23.52:8787` → address sheet (DESIGN §A.8).
    private var serverRow: some View {
        Button {
            focus = nil
            showServerSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(verbatim: "服务器：\(ServerConfig.displayName(app.serverURL))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(Theme.Font.small)
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("更换服务器地址"))
    }

    private func submit() {
        focus = nil
        Task { await model.submit(app: app) }
    }
}

// MARK: - Art panel (web `.auth-art`, phone layout: min height 220, padding 32×24, h1 26 pt)

private struct LoginArtPanel: View {
    private let features: [(icon: String, text: String)] = [
        ("sparkles", "用一句话描述吃了什么，Claude 自动拆解成 40+ 种营养素与食物组"),
        ("exclamationmark.shield", "对照美国 DRI、膳食指南、HEI-2020 与 IARC 致癌物分级逐项打分"),
        ("chart.xyaxis.line", "摄入、消耗、体重交叉对照，按日 / 周 / 月 / 年追踪"),
        ("person.2", "和家人朋友一起记录，自己决定分享哪些数据"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LoginBrand()

            VStack(alignment: .leading, spacing: 20) {
                Text("把每一餐，\n变成看得见的健康趋势")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(features, id: \.text) { f in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: f.icon)
                                .font(.system(size: 16))
                                .frame(width: 20, height: 20)
                                .padding(.top, 1)
                                .accessibilityHidden(true)
                            Text(f.text)
                                .font(.system(size: 15))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Color.white.opacity(0.88))
                    }
                }
            }

            Text("评分仅用于自我管理参考，不构成医疗建议。")
                .font(Theme.Font.small)
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .background(Theme.accent)
    }
}

/// Web `.auth-art` brand row: translucent white square with a leaf + `食迹 NutriLog` (700, 18 pt).
private struct LoginBrand: View {
    var body: some View {
        HStack(spacing: 12) {
            ProfileBrandMark(background: Color.white.opacity(0.14))
            Text("食迹 NutriLog")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
