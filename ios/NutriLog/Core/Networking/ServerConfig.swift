import Foundation

// MARK: - Server URL (DESIGN §A.8)

/// Base URL of the NutriLog server (without `/api/v1`). Default: Info.plist `NLDefaultServerURL`; user override in
/// UserDefaults `nl.serverURL`.
enum ServerConfig {
    static let defaultsKey = "nl.serverURL"
    static let fallbackURLString = "http://45.63.23.52:8787"

    static let defaultURL: URL = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "NLDefaultServerURL") as? String, let url = normalize(raw) { return url }
        return URL(string: fallbackURLString)!
    }()

    /// The override if one is saved, else `defaultURL`.
    static var current: URL {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey), let url = normalize(raw) { return url }
        return defaultURL
    }

    /// Persists `url` (normalised). Saving the default removes the override.
    static func save(_ url: URL) {
        let normalized = normalize(url.absoluteString) ?? url
        if normalized == defaultURL {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(normalized.absoluteString, forKey: defaultsKey)
        }
    }

    /// Trims, adds `http://` when no scheme is given, lowercases scheme and host, strips trailing `/`, `/api` and `/api/v1`,
    /// drops query and fragment. Rejects anything that is not http(s) with a host.
    /// `45.63.23.52:8787` → `http://45.63.23.52:8787`; `https://x.com/nl/api/v1/` → `https://x.com/nl`.
    static func normalize(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard var comps = URLComponents(string: t),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return nil }
        comps.scheme = scheme
        comps.percentEncodedHost = comps.percentEncodedHost?.lowercased()
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api/v1", "/api"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        comps.percentEncodedPath = path
        return comps.url
    }

    /// `host[:port][/path]` for display, e.g. `45.63.23.52:8787` (login screen row `服务器：…`).
    static func displayName(_ url: URL) -> String {
        var s = url.host ?? url.absoluteString
        if let port = url.port { s += ":\(port)" }
        let path = url.path
        if !path.isEmpty, path != "/" { s += path }
        return s
    }

    /// Reachability probe before saving a new address: `GET <url>/api/v1/health` must answer `{"ok": true}`.
    /// Uses its own short-lived cookieless session (the candidate URL is not the client's base URL yet).
    static func probe(_ url: URL) async -> Bool {
        guard let target = URL(string: url.absoluteString + "/api/v1/health") else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never; cfg.httpShouldSetCookies = false; cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 10
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return (try? JSONDecoder().decode(HealthPing.self, from: data))?.ok == true
        } catch {
            AppLog.net.notice("server probe failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Shown when the probe fails (§A.8).
    static let unreachableMessage = "无法连接服务器"
}
