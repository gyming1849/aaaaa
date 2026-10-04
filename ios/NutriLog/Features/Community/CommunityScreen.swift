import SwiftUI
import Observation

// MARK: - 社区 (web2 §5.4, rep §11, auth §3.14)
// Every member's card in one column (web grid → phone). Usernames are always visible; data only when the member shares
// with the viewer. `GET /users` is expensive (14 days of scores per sharing member), so the list is cached for 60 s
// per server + user; pull-to-refresh always refetches. Errors show a retryable banner (the web ignores them).

struct CommunityScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = CommunityModel()

    init() {}

    static let subtitlePrefix = "所有成员都能看到彼此的用户名；每日数据是否共享、共享给谁、共享多少由每个人自己决定（"
    static let shareLinkTitle = "我的分享设置"
    static let subtitleSuffix = "）"
    /// In-text link target; intercepted by `openURL` and routed to `.shareSettings` (never opened externally).
    private static let shareSettingsURL = URL(string: "nutrilog-internal://share-settings")

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                    subtitle
                    content
                }
                .padding(Theme.Metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .debugScrollTo(proxy, ready: model.users != nil)
        }
        .background(Theme.page)
        .navigationTitle("社区")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await model.load(app: app, force: true) }
        .task(id: app.dataVersion) { await model.load(app: app, force: false) }
    }

    /// `…自己决定（我的分享设置）` with an inline link to 资料与分享.
    private var subtitle: some View {
        var text = AttributedString(Self.subtitlePrefix)
        var link = AttributedString(Self.shareLinkTitle)
        link.link = Self.shareSettingsURL
        link.foregroundColor = Theme.accentText
        text += link
        text += AttributedString(Self.subtitleSuffix)
        return Text(text)
            .font(Theme.Font.subtitle)
            .foregroundStyle(Theme.ink3)
            .tint(Theme.accentText)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.shareSettingsURL else { return .discarded }
                app.router.push(.shareSettings)
                return .handled
            })
            .accessibilityAction(named: Text(Self.shareLinkTitle)) { app.router.push(.shareSettings) }
    }

    @ViewBuilder private var content: some View {
        if let error = model.error {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { Task { await model.load(app: app, force: true) } }
                    .buttonStyle(.nl(.plain, size: .sm))
            }
            .nlBanner(.warn)
        }
        if let users = model.users {
            LazyVStack(spacing: 12) {
                // Blocked members are hidden (filtered on every render, so 取消屏蔽 shows them again at once).
                ForEach(users.filter { $0.is_me || !app.blocked.isBlocked($0.id) }) { user in
                    CommunityUserCard(user: user)
                        .debugScrollAnchor(user.username.lowercased())
                }
            }
            .opacity(model.isLoading ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.2), value: model.isLoading)
        } else if model.error == nil {
            LoadingView()
        }
    }
}

// MARK: - Model

@MainActor @Observable final class CommunityModel {
    private(set) var users: [CommunityUser]?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var generation = 0

    /// Cache lifetime (DESIGN §D row 39).
    static let cacheSeconds: TimeInterval = 60

    /// `GET /users`, served from the 60 s cache unless `force`. The cache key includes `dataVersion`, so the viewer's own
    /// card (streak, recent scores) is refreshed after any write.
    func load(app: AppState, force: Bool) async {
        let key = CommunityUsersCache.Key(server: app.serverURL.absoluteString, userId: app.user?.id ?? 0, dataVersion: app.dataVersion)
        if !force, let cached = await CommunityUsersCache.shared.users(for: key, maxAge: Self.cacheSeconds) {
            users = cached
            error = nil
            return
        }
        generation += 1
        let current = generation
        isLoading = true
        error = nil
        defer { if current == generation { isLoading = false } }
        do {
            let fetched = try await app.api.users()
            guard current == generation else { return }
            users = fetched
            await CommunityUsersCache.shared.store(fetched, for: key)
        } catch {
            guard current == generation, !(error is CancellationError), !Task.isCancelled else { return }
            self.error = APIError.from(error).message
        }
    }
}

/// Process-wide 60 s cache of `GET /users` (an actor, so it is Sendable shared state). Keyed by server, viewer and
/// `dataVersion`, so another account or server never sees a stale list.
actor CommunityUsersCache {
    struct Key: Hashable, Sendable {
        let server: String
        let userId: Int
        let dataVersion: Int
    }

    static let shared = CommunityUsersCache()

    private var key: Key?
    private var fetchedAt = Date.distantPast
    private var cached: [CommunityUser] = []

    func users(for key: Key, maxAge: TimeInterval) -> [CommunityUser]? {
        guard self.key == key, Date().timeIntervalSince(fetchedAt) < maxAge else { return nil }
        return cached
    }

    func store(_ users: [CommunityUser], for key: Key) {
        self.key = key
        fetchedAt = Date()
        cached = users
    }

    func clear() {
        key = nil
        cached = []
        fetchedAt = .distantPast
    }
}
