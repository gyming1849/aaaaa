import SwiftUI
import Observation

// MARK: - Report / block (App Store guideline 1.2; DESIGN §F.6 RB-5)
// The server has no report or block API, so blocking is client-side: a blocked member's community card and their public
// foods (食物库 全部可用, the Log Meal food picker and quick foods) are hidden for this viewer on this device. 举报 opens a
// mail to `NLSupportEmail` (hidden while unset). The list is per server and viewer and is wiped on logout (§A.9).

/// UserDefaults `nl.blocked.<server>.<viewerId>` = `{"<memberId>": "<display name（@username）>"}`.
@MainActor @Observable final class BlockedMembersStore {
    /// Blocked member id → label shown in 已屏蔽的成员.
    private(set) var members: [Int: String] = [:]
    @ObservationIgnored private var key: String?

    static let prefix = "nl.blocked."

    /// Loads the signed-in viewer's list (`AppState.adoptMe`).
    func load(server: URL, viewerId: Int) {
        let k = Self.prefix + ServerConfig.displayName(server) + "." + String(viewerId)
        guard k != key else { return }
        key = k
        let stored = (UserDefaults.standard.dictionary(forKey: k) as? [String: String]) ?? [:]
        var out: [Int: String] = [:]
        for (id, label) in stored { if let n = Int(id) { out[n] = label } }
        members = out
    }

    func isBlocked(_ id: Int) -> Bool { members[id] != nil }

    /// Foods without the public ones of blocked members (own foods always stay).
    func visible(_ foods: [Food]) -> [Food] { members.isEmpty ? foods : foods.filter { $0.mine || !isBlocked($0.owner_id) } }

    func block(_ id: Int, label: String) {
        guard id > 0 else { return }
        members[id] = label
        save()
    }

    func unblock(_ id: Int) {
        members[id] = nil
        save()
    }

    /// Logout: every viewer's list on every server.
    func wipeAll() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(Self.prefix) {
            UserDefaults.standard.removeObject(forKey: k)
        }
        members = [:]
        key = nil
    }

    private func save() {
        guard let key else { return }
        var out: [String: String] = [:]
        for (id, label) in members { out[String(id)] = label }
        UserDefaults.standard.set(out, forKey: key)
    }
}

/// `{display name}（@{username}）`.
enum BlockedMembersText {
    static func label(displayName: String, username: String) -> String { "\(displayName)（@\(username)）" }

    /// `mailto:` report for a member, nil without `NLSupportEmail`.
    static func reportMember(username: String, displayName: String, server: URL) -> URL? {
        AppLinks.supportMail(subject: "举报用户 @\(username)",
                             body: "服务器：\(ServerConfig.displayName(server))\n用户：\(displayName)（@\(username)）\n原因：")
    }

    /// `mailto:` report for a public food, nil without `NLSupportEmail`.
    static func reportFood(id: Int, name: String, owner: String?, server: URL) -> URL? {
        AppLinks.supportMail(subject: "举报食物 #\(id) \(name)",
                             body: "服务器：\(ServerConfig.displayName(server))\n食物：#\(id) \(name)\n创建者：\(owner ?? "—")\n原因：")
    }
}

// MARK: - 已屏蔽的成员 (更多 → 设置)

struct BlockedMembersScreen: View {
    @Environment(AppState.self) private var app

    init() {}

    var body: some View {
        let rows = app.blocked.members.sorted { $0.value < $1.value }
        List {
            Section {
                if rows.isEmpty {
                    Text("没有屏蔽任何成员").font(Theme.Font.body).foregroundStyle(Theme.ink3)
                } else {
                    ForEach(rows, id: \.key) { id, label in
                        HStack(spacing: 12) {
                            Text(verbatim: label).font(Theme.Font.body).foregroundStyle(Theme.ink)
                            Spacer(minLength: 8)
                            Button("取消屏蔽") { app.blocked.unblock(id) }
                                .buttonStyle(.nl(.plain, size: .sm))
                        }
                    }
                }
            } footer: {
                Text("屏蔽只在这台设备上生效：被屏蔽成员的社区卡片和公开食物不再显示给你。对方不会收到通知。")
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle(SettingsPage.blocked.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
