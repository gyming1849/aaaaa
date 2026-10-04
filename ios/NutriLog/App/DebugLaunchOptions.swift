#if DEBUG
import Foundation

// MARK: - DEBUG-only launch-argument hooks for automated simulator QA (documented in README.md)
//
//   -NLServerURL <url>        use this server (normalised like the 服务器 setting and saved, so relaunches keep it)
//   -NLToken <nla_token>      store this app token in the Keychain and skip the login screen
//   -NLTab today|trends|body|more
//   -NLPush <route>           push a Route on the selected tab once the session is ready (see `route(from:)`)
//   -NLOpenLogMeal 1          open the 记一餐 sheet (or `-NLOpenLogMeal 2026-10-01` for that date)
//   -NLTheme light|dark|system
//   -NLScrollTo <anchor>      scroll 今日 / 趋势 / 身体 / 周期报告 / 社区 / 健康同步 / 个人档案 to a named card once loaded
//                             (see `debugScrollAnchor` call sites)
//
// Release builds compile none of this.

struct DebugLaunchOptions: Sendable, Equatable {
    var serverURL: URL?
    var token: String?
    var tab: AppRouter.Tab?
    var push: Route?
    var openLogMeal = false
    var logMealDate: String?
    var theme: ThemePreference?
    var scrollTo: String?

    static var current: DebugLaunchOptions { parse(ProcessInfo.processInfo.arguments) }

    static func parse(_ arguments: [String]) -> DebugLaunchOptions {
        var options = DebugLaunchOptions()
        var values: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg.hasPrefix("-NL"), i + 1 < arguments.count {
                values[String(arg.dropFirst())] = arguments[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        if let raw = values["NLServerURL"] {
            options.serverURL = ServerConfig.normalize(raw)
            if options.serverURL == nil { AppLog.app.error("-NLServerURL ignored: invalid URL") }
        }
        if let raw = values["NLToken"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty { options.token = raw }
        if let raw = values["NLTab"] {
            options.tab = tab(from: raw)
            if options.tab == nil { AppLog.app.error("-NLTab ignored: \(raw, privacy: .public)") }
        }
        if let raw = values["NLPush"] {
            options.push = route(from: raw)
            if options.push == nil { AppLog.app.error("-NLPush ignored: unknown route \(raw, privacy: .public)") }
        }
        if let raw = values["NLOpenLogMeal"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch raw.lowercased() {
            case "", "0", "false", "no": break
            default:
                options.openLogMeal = true
                if LocalDay.isValid(raw) { options.logMealDate = raw }
            }
        }
        if let raw = values["NLTheme"] { options.theme = ThemePreference(rawValue: raw.lowercased()) }
        if let raw = values["NLScrollTo"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            options.scrollTo = raw
        }
        return options
    }

    /// Saves `-NLServerURL` and `-NLToken` before `AppState` builds its `APIClient`.
    func applyPersistentOverrides() {
        if let serverURL {
            ServerConfig.save(serverURL)
            AppLog.app.notice("debug: server URL overridden to \(serverURL.absoluteString, privacy: .public)")
        }
        if let token {
            // The expiry is unknown, so it is stored empty: the token is never auto-refreshed (which would rotate it).
            TokenStore.save(StoredToken(token: token, expires_at: ""))
            AppLog.app.notice("debug: app token injected from launch arguments")
        }
    }

    static func tab(from raw: String) -> AppRouter.Tab? {
        switch raw.lowercased() {
        case "today": .today
        case "trends": .trends
        case "body": .body
        case "more", "settings": .more
        default: nil
        }
    }

    /// Accepted `-NLPush` values (case-insensitive; `:`, `/` or `.` separate an argument):
    /// `foods`, `reports`, `community`, `healthSync`, `shareSettings`, `standards[:mine|dri|hazards|hei|met|rules|sources]`,
    /// `memberDay:<username>`, `memberTrends:<username>`, and the 设置 pages `profile`, `appearance`, `password`, `devices`,
    /// `server`, `deleteAccount` (also as `settings:<page>`).
    static func route(from raw: String) -> Route? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var name = trimmed
        var argument: String?
        if let sep = trimmed.firstIndex(where: { $0 == ":" || $0 == "/" || $0 == "." }) {
            name = String(trimmed[..<sep])
            let rest = String(trimmed[trimmed.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            argument = rest.isEmpty ? nil : rest
        }
        switch name.lowercased() {
        case "foods": return .foods
        case "reports": return .reports
        case "community": return .community
        case "healthsync", "health": return .healthSync
        case "sharesettings", "share": return .shareSettings
        case "standards":
            guard let argument else { return .standards(.mine) }
            return StandardsTab(rawValue: argument.lowercased()).map(Route.standards)
        case "memberday":
            return argument.map { Route.memberDay(username: $0) }
        case "membertrends":
            return argument.map { Route.memberTrends(username: $0) }
        case "settings":
            return argument.flatMap(settingsPage(from:)).map(Route.settings)
        default:
            return settingsPage(from: name).map(Route.settings)
        }
    }

    static func settingsPage(from raw: String) -> SettingsPage? {
        switch raw.lowercased() {
        case "profile": .profile
        case "appearance", "theme": .appearance
        case "password": .password
        case "devices", "sessions": .devices
        case "server": .server
        case "blocked": .blocked
        case "deleteaccount", "delete": .deleteAccount
        default: nil
        }
    }
}
#endif
