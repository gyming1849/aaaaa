import Foundation

// MARK: - APIClient (DESIGN §B.4)

/// The single HTTP client. Every call goes to `<baseURL>/api/v1/<path>` over a **cookieless** session (auth §2.2: a stored
/// `nl_session` cookie would override the Bearer token) with `Authorization: Bearer nla_…`.
///
/// Response mapping (in order, §B.4):
/// 1. 2xx → decode `R` inside this actor (large payloads such as `/trends` never touch the main actor).
/// 2. 401 on a credential endpoint (`auth/token`, `auth/register`, `auth/logout`, `auth/config`) → `.http(401, error)`:
///    a login/registration failure, not a session expiry.
/// 3. 401 elsewhere → distinguish real revocation from noise (see `classifyUnauthorized`), then call the unauthorized
///    handler once per token and throw `.unauthorized("登录已失效，请重新登录")`.
/// 4. 404 `接口不存在` → `.unsupportedByServer` (new endpoints on an old server).
/// 5. Other non-2xx → `.http(status, body.error ?? "请求失败（status）")`.
/// 6. `URLError` → `.network(…)` (`请求超时` for timeouts); a cancelled task → `CancellationError`.
/// 7. Decoding failure → `.decoding(<key path>)`, details logged.
/// No automatic retries (except one transparent replay when the token was rotated while the request was in flight).
actor APIClient {
    nonisolated let session: URLSession
    private(set) var baseURL: URL
    private var token: String?
    private var unauthorizedHandler: (@Sendable () async -> Void)?
    /// Token for which the unauthorized handler already ran, so a burst of parallel 401s logs out only once.
    private var revokedToken: String?

    init(baseURL: URL, token: String?) {
        self.init(baseURL: baseURL, token: token, configuration: APIClient.defaultConfiguration())
    }

    /// Designated init; tests pass `defaultConfiguration()` with `protocolClasses` set to a mock `URLProtocol`.
    init(baseURL: URL, token: String?, configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
        self.baseURL = baseURL; self.token = token
    }

    /// Cookieless configuration (auth §2.2: a stored `nl_session` cookie would override the Bearer token), 60 s timeout,
    /// no HTTP cache (photos are cached by `PhotoCache`; JSON must always be fresh).
    static func defaultConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieAcceptPolicy = .never; cfg.httpShouldSetCookies = false; cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        return cfg
    }

    func setToken(_ token: String?) {
        self.token = token
        if token != nil, token == revokedToken { revokedToken = nil }
    }
    func setBaseURL(_ url: URL) { baseURL = url }
    func setUnauthorizedHandler(_ handler: @escaping @Sendable () async -> Void) { unauthorizedHandler = handler }
    func currentToken() -> String? { token }

    // MARK: Core requests

    /// Core request. `path` is relative to /api/v1 without leading slash, e.g. "day/2026-10-03".
    /// `timeout` overrides the per-path default (`timeout(for:)`), e.g. the short launch probes.
    func send<R: Decodable & Sendable>(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: AnyEncodable? = nil, timeout: TimeInterval? = nil, as type: R.Type = R.self) async throws -> R {
        let data = try await execute(method, .api(path, query), body: try jsonBody(method, body), accept: "application/json", timeout: timeout ?? Self.timeout(for: path))
        return try decode(R.self, from: data, path: path)
    }

    /// Same as `send` for endpoints whose response (`{"ok": true}`) carries nothing the caller needs.
    func sendNoContent(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: AnyEncodable? = nil) async throws {
        _ = try await execute(method, .api(path, query), body: try jsonBody(method, body), accept: "application/json", timeout: Self.timeout(for: path))
    }

    /// Multipart POST (meals §2.1). 180 s timeout.
    func upload<R: Decodable & Sendable>(_ path: String, form: MultipartFormData, files: [MultipartFile], fields: [String: String] = [:], as type: R.Type = R.self) async throws -> R {
        let body = PreparedBody(data: form.body(files: files, fields: fields), contentType: form.contentType)
        let data = try await execute(.post, .api(path, []), body: body, accept: "application/json", timeout: Self.uploadTimeout)
        return try decode(R.self, from: data, path: path)
    }

    /// Authenticated GET of a server-absolute path such as `/api/uploads/<id>` (resolved against the host root, auth §1.2).
    /// Only same-server paths are accepted, so the Bearer token never leaves for another host.
    func rawData(absolutePath: String) async throws -> Data {
        guard !absolutePath.contains("://"), !absolutePath.hasPrefix("//") else {
            throw APIError.http(status: 400, message: Self.invalidURLMessage)
        }
        let path = absolutePath.hasPrefix("/") ? absolutePath : "/" + absolutePath
        return try await execute(.get, .absolute(path), body: nil, accept: Self.imageAccept, timeout: 60)
    }

    // MARK: - Internals

    private enum Target: Sendable {
        case api(String, [URLQueryItem])   // relative to /api/v1
        case absolute(String)              // relative to the server root, starts with "/"
        var logPath: String { switch self { case .api(let p, _): p; case .absolute(let p): p } }
    }

    private struct PreparedBody: Sendable { let data: Data; let contentType: String }

    static let credentialPaths: Set<String> = ["auth/token", "auth/register", "auth/logout", "auth/config"]
    static let defaultTimeout: TimeInterval = 60
    static let longTimeout: TimeInterval = 120
    static let uploadTimeout: TimeInterval = 180
    /// `auth/config` and `auth/me` during launch: a black-holed server shows 重试 / 更换服务器 after ~15 s, not 60–120 s.
    static let launchTimeout: TimeInterval = 15
    /// `auth/logout` is best effort and runs after the local wipe; it must never hold anything up.
    static let logoutTimeout: TimeInterval = 10
    static let imageAccept = "image/*,*/*;q=0.8"
    static let invalidURLMessage = "服务器地址无效"

    /// 120 s for `/trends`, `/period` and `/health/sync*`; 10 s for the best-effort `auth/logout`; 60 s otherwise (§B.4).
    static func timeout(for path: String) -> TimeInterval {
        if path == "auth/logout" { return logoutTimeout }
        if path == "trends" || path == "period" || path == "health/sync" || path.hasPrefix("health/sync/") { return longTimeout }
        return defaultTimeout
    }

    /// POST/PUT/PATCH always carry `Content-Type: application/json` and a body (`{}` at minimum, auth §0).
    /// GET and DELETE never send one.
    private func jsonBody(_ method: HTTPMethod, _ body: AnyEncodable?) throws -> PreparedBody? {
        switch method {
        case .get, .delete: return nil
        case .post, .put, .patch:
            do {
                let data = try JSONCoding.encoder().encode(body ?? AnyEncodable(EmptyBody()))
                return PreparedBody(data: data, contentType: "application/json")
            } catch {
                AppLog.net.error("encode failed: \(String(describing: error), privacy: .private)")
                throw APIError.http(status: 400, message: "请求格式不正确")
            }
        }
    }

    private func execute(_ method: HTTPMethod, _ target: Target, body: PreparedBody?, accept: String, timeout: TimeInterval) async throws -> Data {
        var replayed = false
        while true {
            try Task.checkCancellation()
            let sentToken = token
            let request = try makeRequest(method, target, body: body, accept: accept, timeout: timeout, token: sentToken)
            let (data, http) = try await transport(request, method: method, logPath: target.logPath)
            let status = http.statusCode
            if (200..<300).contains(status) { return data }

            let message = APIError.message(fromBody: data, status: status)
            if status == 401 {
                if case .api(let path, _) = target, Self.credentialPaths.contains(path) {
                    throw APIError.http(status: 401, message: message)
                }
                switch await classifyUnauthorized(target: target, sentToken: sentToken, fromServer: Self.isServerErrorBody(data)) {
                case .rotated where !replayed:
                    replayed = true
                    continue
                case .rotated, .noToken, .alreadyHandled:
                    throw APIError.unauthorized(message: APIError.sessionExpiredMessage)
                case .notConfirmed:
                    throw APIError.http(status: 401, message: message)
                case .revoked:
                    AppLog.net.notice("session token rejected by the server; signing out")
                    revokedToken = sentToken
                    if let handler = unauthorizedHandler { await handler() }
                    throw APIError.unauthorized(message: APIError.sessionExpiredMessage)
                }
            }
            if status == 404, message == "接口不存在" { throw APIError.unsupportedByServer }
            throw APIError.http(status: status, message: message)
        }
    }

    private enum UnauthorizedKind { case noToken, rotated, alreadyHandled, revoked, notConfirmed }

    /// A 401 only means "this session is gone" when the token we sent is still the current one and the server rejects it
    /// for `auth/me` as well. This keeps a 401 from a request that raced a login / token refresh, or from a route with its own
    /// credential rules or an intermediary, from logging the user out (auth §1.4).
    /// `fromServer`: the body is the server's `{"error": …}`; a 401 without it (captive portal, proxy) never counts as revocation.
    private func classifyUnauthorized(target: Target, sentToken: String?, fromServer: Bool) async -> UnauthorizedKind {
        guard let sentToken else { return .noToken }
        if token != sentToken { return token == nil ? .noToken : .rotated }
        if revokedToken == sentToken { return .alreadyHandled }
        if case .api(let path, _) = target, path == "auth/me" { return fromServer ? .revoked : .notConfirmed }

        let verdict = await probeSession(token: sentToken)
        if token != sentToken { return token == nil ? .noToken : .rotated }   // changed while probing
        if revokedToken == sentToken { return .alreadyHandled }
        switch verdict {
        case .valid, .unknown: return .notConfirmed
        case .invalid: return .revoked
        }
    }

    private enum SessionVerdict { case valid, invalid, unknown }

    /// `GET auth/me` with the given token, outside the normal error mapping.
    private func probeSession(token: String) async -> SessionVerdict {
        guard let request = try? makeRequest(.get, .api("auth/me", []), body: nil, accept: "application/json", timeout: 20, token: token),
              let result = try? await transport(request, method: .get, logPath: "auth/me (probe)") else { return .unknown }
        switch result.1.statusCode {
        case 200..<300: return .valid
        case 401: return Self.isServerErrorBody(result.0) ? .invalid : .unknown
        default: return .unknown
        }
    }

    /// The NutriLog server always answers 401 with `{"error": …}` (auth §0); anything else came from an intermediary.
    private static func isServerErrorBody(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(APIErrorBody.self, from: data)) != nil
    }

    // MARK: Logout (best effort, after the local wipe)

    /// `POST auth/logout {}` built now, for the current base URL and token (nil when signed out). The caller wipes the
    /// local session and then sends it with `sendLogout(_:)`, so it still reaches the old server with the old token even
    /// after `setBaseURL` / `setToken(nil)`.
    func logoutRequest() -> URLRequest? {
        guard let token, !token.isEmpty, let data = try? JSONCoding.encoder().encode(EmptyBody()) else { return nil }
        return try? makeRequest(.post, .api("auth/logout", []), body: PreparedBody(data: data, contentType: "application/json"),
                                accept: "application/json", timeout: Self.logoutTimeout, token: token)
    }

    /// Sends a request from `logoutRequest()`. Every error is swallowed; the raw transport is used, so a 401 never reaches
    /// the unauthorized handler.
    func sendLogout(_ request: URLRequest) async {
        do {
            _ = try await transport(request, method: .post, logPath: "auth/logout")
        } catch {
            AppLog.net.notice("logout request failed (ignored)")
        }
    }

    private func makeRequest(_ method: HTTPMethod, _ target: Target, body: PreparedBody?, accept: String, timeout: TimeInterval, token: String?) throws -> URLRequest {
        guard let url = Self.url(base: baseURL, target: target) else {
            throw APIError.network(message: Self.invalidURLMessage)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data
        }
        return request
    }

    /// `<base>/api/v1/<path>?<query>` (or `<base><absolute>`). The base may carry a path prefix (reverse proxy).
    /// Query values are percent-encoded strictly (`+`, `&`, `=` … included), so Chinese usernames and searches survive.
    private static func url(base: URL, target: Target) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var prefix = comps.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        comps.query = nil; comps.fragment = nil
        switch target {
        case .api(let path, let query):
            let encodedPath = path.split(separator: "/", omittingEmptySubsequences: true)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? String($0) }
                .joined(separator: "/")
            comps.percentEncodedPath = prefix + "/api/v1/" + encodedPath
            if !query.isEmpty {
                comps.percentEncodedQuery = query.map { item in
                    let name = item.name.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? item.name
                    guard let value = item.value else { return name }
                    return name + "=" + (value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value)
                }.joined(separator: "&")
            }
        case .absolute(let path):
            let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let rawPath = String(parts[0])
            comps.percentEncodedPath = prefix + (rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath)
            if parts.count > 1 { comps.percentEncodedQuery = String(parts[1]).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
        }
        return comps.url
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#;")
        return set
    }()

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private func transport(_ request: URLRequest, method: HTTPMethod, logPath: String) async throws -> (Data, HTTPURLResponse) {
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.network(message: APIError.networkMessage) }
            let elapsed = (ContinuousClock.now - started).components
            let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            AppLog.net.debug("\(method.rawValue, privacy: .public) \(logPath, privacy: .public) → \(http.statusCode, privacy: .public) (\(data.count, privacy: .public) B, \(ms, privacy: .public) ms)")
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            AppLog.net.error("\(method.rawValue, privacy: .public) \(logPath, privacy: .public) failed: URLError \(error.code.rawValue, privacy: .public)")
            throw APIError.from(urlError: error)
        }
    }

    private func decode<R: Decodable>(_ type: R.Type, from data: Data, path: String) throws -> R {
        do {
            return try JSONCoding.decoder().decode(R.self, from: data)
        } catch {
            AppLog.net.error("decode \(String(describing: R.self), privacy: .public) from \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw APIError.decoding(message: JSONCoding.describe(error))
        }
    }
}
