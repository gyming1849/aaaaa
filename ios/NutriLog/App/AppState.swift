import SwiftUI
import Observation

// MARK: - App state (DESIGN §B.3)

/// Session state machine and shared services. Views read it with `@Environment(AppState.self) private var app`.
///
/// Feature code uses only `api`, `toasts`, `router`, `healthSync`, `me`, `meta`, `today`, `profile`, `user`, `isMockAI`,
/// `profileTimeZone`, `dataVersion`, `noteDataChanged()`, `refreshMe()`, `didSaveProfile(_:)`, `logout()`,
/// `deleteAccount(password:)`, `setServerURL(_:)`, `ensureMeta()` and the lookup helpers.
@MainActor @Observable final class AppState {
    enum Phase: Equatable { case launching, unreachable(String), loggedOut, onboarding, ready }
    private(set) var phase: Phase = .launching
    private(set) var me: Me?
    private(set) var meta: Meta?
    /// The message of the last failed `standards/meta` request, `nil` after a success (additive; requested by WP8).
    /// Lets a screen tell a failed `ensureMeta(force:)` apart from a successful one.
    private(set) var metaError: String?
    private(set) var authConfig: AuthConfig?
    private(set) var dataVersion: Int = 0
    /// 跟随系统 / 浅色 / 深色 (更多 → 外观). Persisted in UserDefaults `nl.theme`.
    var themePreference: ThemePreference = AppState.initialTheme() {
        didSet { if themePreference != oldValue { UserDefaults.standard.set(themePreference.rawValue, forKey: Self.themeKey) } }
    }
    let api: APIClient
    let toasts = ToastCenter()
    let router = AppRouter()
    let healthSync: HealthSyncService
    /// Third-party AI consent per server and account (`AIConsent.swift`).
    let aiConsent = AIConsentStore()
    /// Community members this viewer blocked on this device (`BlockedMembers.swift`).
    let blocked = BlockedMembersStore()
    var today: String { me?.today ?? LocalDay.deviceToday() }
    var profile: Profile? { me?.profile }
    var user: User? { me?.user }
    var isMockAI: Bool { me?.ai.isMock ?? true }
    var profileTimeZone: TimeZone { TimeZone(identifier: me?.profile?.timezone ?? "Asia/Shanghai") ?? .current }
    var serverURL: URL { ServerConfig.current }

    static let themeKey = ThemePreference.defaultsKey   // "nl.theme" (WP0-C owns the constant)
    /// `me` is refreshed on foreground when older than this (rolls `today` over, §B.3).
    static let meRefreshInterval: TimeInterval = 5 * 60
    /// Token refresh window (§B.3, §C.8).
    static let tokenRefreshDays = 30

    @ObservationIgnored private var bootGeneration = 0
    @ObservationIgnored private var lastMeRefreshAt: Date?
    @ObservationIgnored private var isClearingSession = false
    @ObservationIgnored private var metaIsFresh = false
    @ObservationIgnored private var metaRefreshTask: Task<Void, Never>?
    /// Bumped by a server switch: a `standards/meta` response from the old server is dropped.
    @ObservationIgnored private var metaGeneration = 0
    /// One-shot `refreshMe()` at the next profile-time-zone midnight while the app stays in the foreground.
    @ObservationIgnored private var rolloverTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshingToken = false
    #if DEBUG
    @ObservationIgnored private var debugLaunchApplied = false
    #endif

    init() {
        DeviceInfo.prime()
        #if DEBUG
        let launch = DebugLaunchOptions.current
        launch.applyPersistentOverrides()
        let initialToken = launch.token ?? TokenStore.load(for: ServerConfig.current)?.token
        #else
        let initialToken = TokenStore.load(for: ServerConfig.current)?.token
        #endif
        api = APIClient(baseURL: ServerConfig.current, token: initialToken)
        healthSync = HealthSyncService(api: api)
        healthSync.attach(to: self)
        // Installed before any background work can run (HealthKit observers start in didFinishLaunching, before RootView
        // bootstraps): a revoked token seen by a background sync then clears the session instead of only being recorded.
        // bootstrap() installs it again (idempotent).
        let api = self.api
        let handler: @Sendable () async -> Void = { [weak self] in await self?.handleUnauthorized() }
        Task { await api.setUnauthorizedHandler(handler) }
    }

    // MARK: Bootstrap

    /// Launch / re-login flow (§B.3). Safe to call repeatedly: only the latest call may change `phase`.
    /// `showLaunching: false` (retry from the unreachable screen) keeps that screen, its 重试 spinner and 更换服务器 up while
    /// the retry runs.
    func bootstrap(showLaunching: Bool = true) async {
        bootGeneration += 1
        let generation = bootGeneration
        if case .unreachable = phase, !showLaunching {} else { phase = .launching }
        await api.setUnauthorizedHandler { [weak self] in await self?.handleUnauthorized() }
        if await api.currentToken() == nil, let stored = TokenStore.load(for: await api.baseURL) {
            // The Keychain may have been locked when `init` ran (a launch before the first unlock, or a prewarm).
            await api.setToken(stored.token)
        }
        guard generation == bootGeneration else { return }
        guard await api.currentToken() != nil else {
            await discardOrphanedUserState()
            guard generation == bootGeneration else { return }
            phase = .loggedOut                      // LoginScreen loads auth/config itself
            return
        }
        let configError = await loadAuthConfig(timeout: APIClient.launchTimeout)
        guard generation == bootGeneration else { return }
        if let configError {
            phase = .unreachable(configError.message)   // same host: auth/me would only time out again
            return
        }

        let fetched: Me
        do {
            fetched = try await api.me(timeout: APIClient.launchTimeout)
        } catch {
            guard generation == bootGeneration else { return }
            let e = APIError.from(error)
            // A 401 the client had already recorded (e.g. by a background sync) must still wipe the session.
            if case .unauthorized = e { await handleUnauthorized() } else { phase = .unreachable(e.message) }
            return
        }
        guard generation == bootGeneration else { return }
        adoptMe(fetched)
        await ensureMeta()
        await maybeRefreshToken()
        guard generation == bootGeneration else { return }
        phase = fetched.profile == nil ? .onboarding : .ready
        #if DEBUG
        applyDebugLaunchActions()
        #endif
        Task { await self.pushAIConsentIfNeeded() }
        if phase == .ready { await healthSync.onSessionReady() }
    }

    /// `GET auth/config` (public, best effort). Old servers (404, or 401 without a token) → `AuthConfig.legacy`;
    /// a network failure leaves the previous value and is returned (bootstrap stops early on it). A response that
    /// arrives after a server switch is dropped.
    @discardableResult
    func loadAuthConfig(timeout: TimeInterval? = nil) async -> APIError? {
        let base = await api.baseURL
        do {
            let config = try await api.authConfig(timeout: timeout)
            if await api.baseURL == base { authConfig = config }
            return nil
        } catch {
            let e = APIError.from(error)
            guard await api.baseURL == base else { return nil }
            switch e {
            case .unsupportedByServer, .http:
                authConfig = .legacy
                return nil
            case .network:
                AppLog.app.notice("auth/config unavailable: \(e.message, privacy: .public)")
                return e
            case .decoding, .unauthorized, .jobFailed:
                AppLog.app.notice("auth/config unavailable: \(e.message, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: Login / register / logout

    /// `POST auth/token` → Keychain → bootstrap. Throws the server message (e.g. `用户名或密码错误`).
    func login(username: String, password: String) async throws {
        let res = try await api.login(username: username, password: password, deviceName: DeviceInfo.deviceName)
        await adoptToken(res.token, expiresAt: res.expires_at)
        await bootstrap()
    }

    /// `POST auth/register` (always with `device_name`) → Keychain → bootstrap (→ onboarding, since there is no profile yet).
    func register(username: String, password: String, displayName: String, inviteCode: String) async throws {
        let body = RegisterBody(username: username, password: password, display_name: displayName,
                                invite_code: inviteCode, device_name: DeviceInfo.deviceName)
        let res = try await api.register(body)
        await adoptToken(res.token, expiresAt: res.expires_at)
        await bootstrap()
    }

    /// Wipes everything tied to the user right away (§A.9), then revokes the token on the server in the background
    /// (best effort, 10 s). The request is built first, so it still goes to the old server with the old token even when
    /// `setServerURL` switches the address right after.
    func logout() async {
        let revoke = await api.logoutRequest()
        await clearSession()
        if let revoke { Task { [api] in await api.sendLogout(revoke) } }
    }

    /// Called by `APIClient` when the server confirms the token is no longer valid (§B.4 rule 3).
    func handleUnauthorized() async {
        guard phase != .loggedOut, !isClearingSession else { return }
        isClearingSession = true
        defer { isClearingSession = false }
        await clearSession()
        toasts.error(APIError.sessionExpiredMessage)
    }

    /// `POST account/delete` (§C.5); on success the local session is wiped. Throws `.unsupportedByServer` on old servers.
    func deleteAccount(password: String) async throws {
        try await api.deleteAccount(password: password)
        await clearSession()
    }

    // MARK: Refresh

    func refreshMe() async {
        guard await api.currentToken() != nil else { return }
        do {
            let fresh = try await api.me()
            adoptMe(fresh)
            if phase == .onboarding, fresh.profile != nil {
                phase = .ready
                await healthSync.onSessionReady()
            }
        } catch {
            AppLog.app.notice("refreshMe failed: \(APIError.from(error).message, privacy: .public)")
        }
    }

    /// Screens reload with `.task(id: app.dataVersion)` / `.onChange(of: app.dataVersion)`.
    func noteDataChanged() { dataVersion += 1 }

    /// `refreshMe()` when the profile-time-zone day has moved past `me.today` (pull-to-refresh on 今日 / 趋势 / 身体).
    func refreshMeIfDayChanged() async {
        if dayRolledOver { await refreshMe() }
    }

    /// scenePhase → `.active`: refresh `me` when stale or the day rolled over, retry a failed token rotation, then let
    /// HealthKit sync run (§B.3).
    func onForeground() async {
        switch phase {
        case .ready, .onboarding:
            let stale = lastMeRefreshAt.map { Date().timeIntervalSince($0) >= Self.meRefreshInterval } ?? true
            if stale || dayRolledOver { await refreshMe() }
            if phase == .ready || phase == .onboarding { await maybeRefreshToken() }
            if phase == .ready { await healthSync.onForeground() }
        case .loggedOut:
            // A launch before the first unlock could not read the Keychain; now that the user is here it can.
            if await api.currentToken() == nil, TokenStore.load(for: await api.baseURL) != nil { await bootstrap() }
        case .unreachable, .launching:
            break   // RootUnreachableView retries on foreground itself, unless its 更换服务器 sheet is open
        }
    }

    /// Standards meta (§A.9): the cached copy is used immediately; the server copy is fetched once per session
    /// (awaited when nothing is cached or `force`, otherwise in the background) and replaces the cache.
    func ensureMeta(force: Bool = false) async {
        if meta == nil, let cached = DiskCache.load("meta", as: Meta.self) { meta = cached }
        if metaIsFresh && !force { return }
        if meta == nil || force {
            await refreshMetaFromServer()
        } else if metaRefreshTask == nil {
            let generation = metaGeneration
            metaRefreshTask = Task { [weak self] in
                await self?.refreshMetaFromServer()
                if self?.metaGeneration == generation { self?.metaRefreshTask = nil }
            }
        }
    }

    // MARK: Server address

    /// Switches the server (§A.8). The caller probes the address first (`ServerConfig.probe`) and, when signed in, confirms
    /// with `更换服务器需要重新登录`: a signed-in session is logged out (against the old server) before switching.
    /// From the unreachable screen the session follows the new address only when the user confirmed it is the same server
    /// (`keepSession`, e.g. IP → HTTPS domain) and the app re-bootstraps there; otherwise the local session is wiped first
    /// (no `auth/logout`: the old server is down), so the old token is never sent to another host.
    func setServerURL(_ url: URL, keepSession: Bool = false) async {
        let target = ServerConfig.normalize(url.absoluteString) ?? url
        let current = await api.baseURL
        let changed = target != current
        var keepsToken = false
        if changed {
            switch phase {
            case .ready, .onboarding: await logout()
            case .unreachable, .launching:
                if keepSession { keepsToken = true } else { await clearSession() }
            case .loggedOut:
                TokenStore.clear()   // a token the Keychain could not be read for at launch must not reach the new host
            }
        }
        ServerConfig.save(target)
        guard changed else { return }
        await api.setBaseURL(target)
        if keepsToken, let kept = TokenStore.load() {
            // The kept session now belongs to the new address (otherwise the next launch would discard it).
            TokenStore.save(StoredToken(token: kept.token, expires_at: kept.expires_at, server: target.absoluteString))
        }
        metaGeneration += 1
        metaRefreshTask?.cancel()
        metaRefreshTask = nil
        meta = nil
        metaError = nil
        metaIsFresh = false
        authConfig = nil
        DiskCache.removeAll()
        await PhotoCache.shared.clear()
        switch phase {
        case .unreachable, .launching: await bootstrap()      // only reached with keepSession
        case .loggedOut, .onboarding, .ready: await loadAuthConfig()
        }
    }

    /// After `PUT profile` succeeded (onboarding or 个人档案). Every cached score is recomputed server-side, so screens reload.
    func didSaveProfile(_ profile: Profile) async {
        if let m = me { me = Me(user: m.user, profile: profile, today: m.today, ai: m.ai, conditions: m.conditions) }
        let wasOnboarding = phase == .onboarding
        await refreshMe()
        if wasOnboarding, phase == .onboarding, me?.profile != nil { phase = .ready }
        noteDataChanged()
        await healthSync.onSessionReady()   // the profile time zone may have changed
    }

    // MARK: Lookups

    func nutrientDef(_ key: String) -> NutrientDef? { meta?.nutrients.first { $0.key == key } }
    func hazardDef(_ key: String) -> HazardDef? { meta?.hazards.first { $0.key == key } }
    func source(_ id: String) -> SourceDef? { meta?.sources.first { $0.id == id } }
    func activityDef(_ key: String) -> ActivityDef? { meta?.activities.first { $0.key == key } }

    // MARK: - Internals

    private func adoptMe(_ fresh: Me) {
        me = fresh
        lastMeRefreshAt = Date()
        DiskCache.save(fresh, key: "me")
        blocked.load(server: serverURL, viewerId: fresh.user.id)
        scheduleRollover()
    }

    private func adoptToken(_ token: String, expiresAt: String) async {
        let server = await api.baseURL
        TokenStore.save(StoredToken(token: token, expires_at: expiresAt, server: server.absoluteString))
        await api.setToken(token)
    }

    /// The profile-time-zone calendar day has moved past `me.today` (midnight rollover). Only with a profile: without one
    /// the server's `today` is the UTC date.
    private var dayRolledOver: Bool {
        guard let me, me.profile != nil else { return false }
        return LocalDay.key(for: Date(), in: profileTimeZone) != me.today
    }

    /// While the app stays in the foreground past midnight (profile time zone, not the device's), `today` rolls over with
    /// one `refreshMe()`; `adoptMe` re-arms it for the following day. A suspended app finishes the sleep on resume, and
    /// `onForeground` covers that case too. Nothing is armed when the next midnight is already past on this device's clock.
    private func scheduleRollover() {
        rolloverTask?.cancel()
        rolloverTask = nil
        guard let me, me.profile != nil,
              let next = LocalDay.date(fromKey: LocalDay.addDays(me.today, 1), in: profileTimeZone) else { return }
        let delay = next.timeIntervalSinceNow + 2       // small margin for server / device clock skew
        guard delay > 0 else { return }
        rolloverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshMe()
        }
    }

    /// No token, but user state from a session is still on disk: the `ThisDeviceOnly` Keychain item did not come along on a
    /// backup restore or device migration while UserDefaults and Application Support did. Treat it as a logout (HealthKit
    /// anchors, ledger and settings belong to the old phone) and give this install a new `device_id`.
    private func discardOrphanedUserState() async {
        #if DEBUG
        if DebugLaunchOptions.current.token != nil { return }
        #endif
        guard TokenStore.isDefinitelyAbsent,
              HealthSyncSettings.hasState || DiskCache.load("me", as: Me.self) != nil else { return }
        AppLog.app.notice("no session token but leftover user state (restored backup?): wiping it")
        await healthSync.onLogout()
        DiskCache.removeAll()
        PendingJobStore.removeAll()
        UserDefaults.standard.removeObject(forKey: DeviceInfo.installIdKey)   // regenerated lazily
    }

    /// Logout without the network call: Keychain token, caches, pending jobs, photos, HealthKit state, navigation (§A.9).
    private func clearSession() async {
        bootGeneration += 1          // an in-flight bootstrap must not resurrect the session
        TokenStore.clear()
        await api.setToken(nil)
        DiskCache.removeAll()
        PendingJobStore.removeAll()
        await PhotoCache.shared.clear()
        await healthSync.onLogout()
        router.reset()
        blocked.wipeAll()
        aiConsent.wipeAll()
        rolloverTask?.cancel()
        rolloverTask = nil
        me = nil
        lastMeRefreshAt = nil
        phase = .loggedOut
    }

    private func refreshMetaFromServer() async {
        let generation = metaGeneration
        do {
            let fresh = try await api.standardsMeta()
            guard generation == metaGeneration else { return }   // the server was switched meanwhile
            meta = fresh
            metaError = nil
            metaIsFresh = true
            DiskCache.save(fresh, key: "meta")
        } catch is CancellationError {
            return
        } catch {
            guard generation == metaGeneration else { return }
            let message = APIError.from(error).message
            metaError = message
            AppLog.app.notice("standards/meta unavailable: \(message, privacy: .public)")
        }
    }

    /// Rotates the app token when it expires within 30 days and the server supports it (§C.8). Runs at bootstrap and on
    /// every foreground, so a rotation whose response was lost is retried while the old token is in its grace window.
    private func maybeRefreshToken() async {
        guard !isRefreshingToken else { return }
        guard authConfig?.supports("token_refresh") == true,
              let stored = TokenStore.load(), stored.expires(withinDays: Self.tokenRefreshDays) else { return }
        guard await api.currentToken() == stored.token else { return }
        isRefreshingToken = true
        defer { isRefreshingToken = false }
        do {
            let res = try await api.refreshToken()
            guard await api.currentToken() == stored.token else { return }   // signed out or switched meanwhile
            let server = await api.baseURL
            TokenStore.save(StoredToken(token: res.token, expires_at: res.expires_at, server: server.absoluteString))
            await api.setToken(res.token)
            AppLog.app.info("app token refreshed")
        } catch {
            AppLog.app.notice("token refresh failed: \(APIError.from(error).message, privacy: .public)")
        }
    }

    private static func initialTheme() -> ThemePreference {
        #if DEBUG
        if let theme = DebugLaunchOptions.current.theme { return theme }
        #endif
        return ThemePreference(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .system
    }

    #if DEBUG
    /// `-NLTab`, `-NLPush`, `-NLOpenLogMeal` (README): applied once, the first time the session is ready.
    private func applyDebugLaunchActions() {
        guard !debugLaunchApplied, phase == .ready else { return }
        debugLaunchApplied = true
        let launch = DebugLaunchOptions.current
        if let tab = launch.tab { router.selectedTab = tab }
        if let route = launch.push { router.push(route) }
        if launch.openLogMeal { router.openLogMeal(date: launch.logMealDate) }
    }
    #endif
}
