import SwiftUI

// MARK: - 资料与分享 (web `pages/Settings.tsx` card `#share`; web2 §5.5, auth §3.12, §3.14)
// `PUT /settings` always carries all five fields: omitting a sharing field would reset it on the server.
// Reached from 更多 and from Community's `我的分享设置` (`Route.shareSettings`).

struct ShareSettingsScreen: View {
    @Environment(AppState.self) private var app

    init() {}

    var body: some View {
        Group {
            if let user = app.user {
                ShareSettingsContent(user: user)
            } else {
                LoadingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.page)
            }
        }
        .navigationTitle("资料与分享")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Local copy of the five settings fields plus the member list for `选择成员`.
@MainActor @Observable final class ShareSettingsModel {
    var displayName: String
    var avatarColor: String
    var shareMode: String
    var shareDetail: String
    var shareWith: [Int]
    private(set) var users: [CommunityUser]?
    private(set) var usersError: String?
    private(set) var isLoadingUsers = false
    private(set) var isSaving = false

    init(user: User) {
        let body = ShareSettingsModel.body(from: user)
        displayName = body.display_name
        avatarColor = body.avatar_color
        shareMode = body.share_mode
        shareDetail = body.share_detail
        shareWith = body.share_with
    }

    static func body(from user: User) -> SettingsBody {
        SettingsBody(display_name: user.display_name, avatar_color: user.avatar_color, share_mode: user.share_mode,
                     share_detail: user.share_detail, share_with: user.share_with ?? [])
    }

    /// All five fields (auth §3.12), exactly as the web sends them.
    var body: SettingsBody {
        SettingsBody(display_name: displayName, avatar_color: avatarColor, share_mode: shareMode, share_detail: shareDetail,
                     share_with: shareWith)
    }

    /// Other members for `选择成员` (web: `users.filter(!is_me)`).
    var otherUsers: [CommunityUser] { (users ?? []).filter { !$0.is_me } }

    func toggleMember(_ id: Int) {
        if shareWith.contains(id) { shareWith.removeAll { $0 == id } } else { shareWith.append(id) }
    }

    /// `GET /users` (auth §3.14). Can be slow on large servers (14 days of scores per member).
    func loadUsers(app: AppState) async {
        isLoadingUsers = true
        defer { isLoadingUsers = false }
        do {
            users = try await app.api.users()
            usersError = nil
        } catch is CancellationError {
            return
        } catch {
            usersError = APIError.from(error).message
        }
    }

    /// `PUT /settings` → `refreshMe()` → toast `已保存`.
    func save(app: AppState) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let payload = body
        do {
            try await app.api.saveSettings(payload)
            await app.refreshMe()
            if let user = app.user {
                // Reflect what the server kept (an empty name keeps the old one; the name is trimmed to 32).
                let fresh = Self.body(from: user)
                displayName = fresh.display_name
                avatarColor = fresh.avatar_color
            }
            app.toasts.show("已保存")
        } catch {
            app.toasts.error(error)
        }
    }
}

private struct ShareSettingsContent: View {
    @Environment(AppState.self) private var app
    @State private var model: ShareSettingsModel
    @FocusState private var focus: Bool?

    init(user: User) {
        _model = State(initialValue: ShareSettingsModel(user: user))
    }

    var body: some View {
        ProfileScrollPage {
            Card {
                HStack(spacing: 14) {
                    Avatar(name: previewName, color: model.avatarColor, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: previewName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(verbatim: "@\(app.user?.username ?? "")")
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .accessibilityElement(children: .combine)

                ProfileField("昵称") {
                    ProfileTextInput("昵称", text: $model.displayName, prompt: app.user?.display_name, field: true, focus: $focus,
                                     contentType: .nickname, submitLabel: .done, maxLength: 32)
                }

                ProfileField("头像颜色") {
                    FlowLayout(spacing: 6) {
                        ForEach(Vocab.avatarColors, id: \.self) { color in
                            colorSwatch(color)
                        }
                    }
                }
            }

            Card {
                ProfileField("谁能看到我的每日数据（所有人都能看到你的用户名）") {
                    Seg(ShareMode.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) }, selection: $model.shareMode)
                }
                if model.shareMode != ShareMode.private.rawValue {
                    ProfileField("共享内容") {
                        Seg(ShareDetail.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) }, selection: $model.shareDetail)
                    }
                }
                if model.shareMode == ShareMode.selected.rawValue {
                    ProfileField("选择成员") { memberPicker }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.shareMode)

            HStack {
                Spacer(minLength: 0)
                ProfileSubmitButton("保存", isBusy: model.isSaving) {
                    focus = nil
                    Task { await model.save(app: app) }
                }
            }
        }
        .task { if model.users == nil { await model.loadUsers(app: app) } }
        .refreshable { await model.loadUsers(app: app) }
    }

    private var previewName: String {
        let t = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (app.user?.display_name ?? "") : t
    }

    private func colorSwatch(_ color: String) -> some View {
        let on = model.avatarColor.lowercased() == color.lowercased()
        return Button {
            model.avatarColor = color
        } label: {
            Circle()
                .fill(Color(hex: color))
                .frame(width: 28, height: 28)
                .overlay { Circle().strokeBorder(on ? Theme.ink : Theme.surface, lineWidth: on ? 3 : 2) }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "头像颜色：\(Vocab.avatarColorNames[color.lowercased()] ?? color)"))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder
    private var memberPicker: some View {
        if let users = model.users {
            if users.count <= 1 {
                Text("还没有其他成员")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(model.otherUsers) { u in
                        ProfileToggleChip(u.display_name, isOn: model.shareWith.contains(u.id)) {
                            model.toggleMember(u.id)
                        } leading: {
                            Avatar(name: u.display_name, color: u.avatar_color, size: 20)
                        }
                        .accessibilityLabel(Text(verbatim: "\(u.display_name) @\(u.username)"))
                    }
                }
            }
        } else if let error = model.usersError, !model.isLoadingUsers {
            VStack(alignment: .leading, spacing: 8) {
                ProfileFieldError(error)
                Button("重试") { Task { await model.loadUsers(app: app) } }
                    .buttonStyle(.nl(.plain, size: .sm))
            }
        } else {
            HStack(spacing: 8) {
                Spinner()
                Text("加载中…").font(Theme.Font.small).foregroundStyle(Theme.ink3)
            }
        }
    }
}
