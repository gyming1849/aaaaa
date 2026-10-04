import Foundation

// WP0-B Networking logic tests: ServerConfig.normalize, multipart bodies, error mapping, request building, the 401
// classification, JobPoller and PhotoCache. The real `APIClient` runs against a mock `URLProtocol` with hand-written
// responses; nothing touches the network, the Keychain or UserDefaults writes.

// MARK: - Mock transport

struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
    var path: String { url.path }
    var query: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    var bearer: String? { headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) } }
    var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

struct MockResponse: Sendable {
    var status = 200
    var body = Data()
    var contentType = "application/json"
    var error: URLError?
    var delay: TimeInterval = 0
    static func json(_ status: Int, _ text: String, delay: TimeInterval = 0) -> MockResponse {
        MockResponse(status: status, body: Data(text.utf8), delay: delay)
    }
    static func fail(_ code: URLError.Code) -> MockResponse { MockResponse(error: URLError(code)) }
}

final class MockServer: @unchecked Sendable {
    static let shared = MockServer()
    private let lock = NSLock()
    private var handler: @Sendable (RecordedRequest) -> MockResponse = { _ in .json(500, "{}") }
    private var log: [RecordedRequest] = []

    func reset(_ handler: @escaping @Sendable (RecordedRequest) -> MockResponse) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        log = []
    }
    var requests: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return log }
    func respond(_ r: RecordedRequest) -> MockResponse {
        lock.lock()
        log.append(r)
        let h = handler
        lock.unlock()
        return h(r)
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let rec = RecordedRequest(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:],
                                  body: body, timeout: request.timeoutInterval)
        let res = MockServer.shared.respond(rec)
        if res.delay > 0 { Thread.sleep(forTimeInterval: res.delay) }
        if let e = res.error { client?.urlProtocol(self, didFailWithError: e); return }
        let http = HTTPURLResponse(url: request.url!, statusCode: res.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": res.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: res.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

actor CallCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}

@MainActor final class PhaseRecorder { var phases: [JobPhase] = [] }

/// Thread-safe counter for use inside the synchronous mock handler.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

let base = URL(string: "http://test.local:8787")!

func makeClient(token: String? = "nla_A", base: URL = base) -> APIClient {
    let cfg = APIClient.defaultConfiguration()
    cfg.protocolClasses = [MockURLProtocol.self]
    return APIClient(baseURL: base, token: token, configuration: cfg)
}

func apiError(_ body: () async throws -> Void) async -> APIError? {
    do { try await body(); return nil } catch { return APIError.from(error) }
}

let unauthorizedBody = #"{"error":"未登录或令牌已失效"}"#

// MARK: - ServerConfig.normalize (DESIGN §A.8)

section("ServerConfig")
let normalizeCases: [(String, String?)] = [
    ("45.63.23.52:8787", "http://45.63.23.52:8787"),
    ("  http://45.63.23.52:8787/  ", "http://45.63.23.52:8787"),
    ("http://45.63.23.52:8787/api/v1", "http://45.63.23.52:8787"),
    ("http://45.63.23.52:8787/api/v1/", "http://45.63.23.52:8787"),
    ("http://45.63.23.52:8787/api", "http://45.63.23.52:8787"),
    ("HTTPS://Example.COM/nl/api/v1", "https://example.com/nl"),
    ("https://example.com/nutrilog/", "https://example.com/nutrilog"),
    ("localhost:18787?x=1#frag", "http://localhost:18787"),
    ("", nil),
    ("   ", nil),
    ("ftp://example.com", nil),
    ("http://", nil),
    ("http://exa mple.com", nil),
]
for (input, expected) in normalizeCases {
    expectEqual(ServerConfig.normalize(input)?.absoluteString, expected, "normalize \(input.debugDescription)")
}
expectEqual(ServerConfig.displayName(URL(string: "http://45.63.23.52:8787")!), "45.63.23.52:8787", "displayName ip:port")
expectEqual(ServerConfig.displayName(URL(string: "https://example.com/nl")!), "example.com/nl", "displayName with path")
expectEqual(ServerConfig.defaultURL.absoluteString, "http://45.63.23.52:8787", "default URL without Info.plist")

// MARK: - Multipart (meals §2.1)

section("Multipart")
let form = MultipartFormData(boundary: "B")
expectEqual(form.contentType, "multipart/form-data; boundary=B", "content type")
let mp = form.body(files: [MultipartFile(fieldName: "photos", filename: "photo1.jpg", mimeType: "image/jpeg", data: Data("JPEG".utf8))],
                   fields: ["note": "hi"])
expectEqual(String(decoding: mp, as: UTF8.self),
            "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhi\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"photos\"; filename=\"photo1.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nJPEG\r\n--B--\r\n",
            "body bytes")
check(MultipartFormData().boundary.hasPrefix("NutriLog-"), "default boundary prefix")

// MARK: - Error mapping (B.4)

section("APIError")
expectEqual(APIError.message(fromBody: Data(#"{"error":"用户名或密码错误"}"#.utf8), status: 401), "用户名或密码错误", "server error text")
expectEqual(APIError.message(fromBody: Data("<html>502 Bad Gateway</html>".utf8), status: 502), "请求失败（502）", "HTML body fallback")
expectEqual(APIError.message(fromBody: Data(), status: 500), "请求失败（500）", "empty body fallback")
expectEqual(APIError.message(fromBody: Data(#"{"error":"  "}"#.utf8), status: 400), "请求失败（400）", "blank error fallback")
expectEqual(APIError.decoding(message: "x").message, "数据解析失败：x", "decoding message")
expectEqual(APIError.unsupportedByServer.message, "服务器版本过旧，暂不支持此功能", "unsupported message")
expectEqual(APIError.unauthorized(message: "m").status, 401, "unauthorized status")
expectEqual(APIError.from(URLError(.timedOut)), .network(message: "请求超时"), "timeout mapping")
expectEqual(APIError.from(URLError(.notConnectedToInternet)), .network(message: "网络连接失败，请检查网络或服务器地址"), "offline mapping")

section("JSONCoding")
struct NaNBody: Encodable, Sendable { let a: Double; let b: Double }
let nanJSON = (try? JSONCoding.encoder().encode(NaNBody(a: .nan, b: 1.5))).map { String(decoding: $0, as: UTF8.self) } ?? ""
check(nanJSON.contains(#""a":"0""#) && nanJSON.contains(#""b":1.5"#), "NaN is sanitised, finite kept", nanJSON)
struct SnakeBody: Encodable, Sendable { let sodium_mg: Double; let energyTarget: Double }
let snake = (try? JSONCoding.encoder().encode(SnakeBody(sodium_mg: 1, energyTarget: 2))).map { String(decoding: $0, as: UTF8.self) } ?? ""
check(snake.contains("sodium_mg") && snake.contains("energyTarget"), "keys verbatim", snake)

// MARK: - StoredToken expiry (§B.3 refresh window)

section("StoredToken")
let now = Date(timeIntervalSince1970: 1_790_000_000)
let iso: (Date) -> String = { $0.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
check(StoredToken(token: "t", expires_at: iso(now.addingTimeInterval(10 * 86_400))).expires(withinDays: 30, now: now), "10 days left → refresh")
check(!StoredToken(token: "t", expires_at: iso(now.addingTimeInterval(200 * 86_400))).expires(withinDays: 30, now: now), "200 days left → keep")
check(!StoredToken(token: "t", expires_at: "").expires(withinDays: 30, now: now), "unknown expiry → never refresh")
expectEqual(DeviceInfo.compose("小林的 iPhone"), "小林的 iPhone · 食迹 iOS", "device name")
expectEqual(DeviceInfo.compose(String(repeating: "x", count: 100)).count, 60, "device name ≤ 60")

// MARK: - Request building

section("Requests")
do {
    let api = makeClient()
    MockServer.shared.reset { _ in .json(400, #"{"error":"日期格式不正确"}"#) }
    let e = await apiError { _ = try await api.day("2026-10-03", user: "小林") }
    expectEqual(e, .http(status: 400, message: "日期格式不正确"), "400 passes the server message")
    let r = MockServer.shared.requests.first
    expectEqual(r?.method, "GET", "GET method")
    expectEqual(r?.path, "/api/v1/day/2026-10-03", "path under /api/v1")
    expectEqual(r?.query, "user=%E5%B0%8F%E6%9E%97", "Chinese username percent-encoded")
    expectEqual(r?.headers["Authorization"], "Bearer nla_A", "Bearer header")
    expectEqual(r?.headers["Accept"], "application/json", "Accept header")
    expectNil(r?.headers["Content-Type"], "GET has no content type")
    check(r?.body?.isEmpty ?? true, "GET has no body")
    expectEqual(r?.timeout, 60, "default timeout 60 s")

    MockServer.shared.reset { _ in .json(200, "[]") }
    let foods = try? await api.foods(query: " a+b c&d ", scope: .all)
    expectEqual(foods?.count, 0, "foods decoded")
    expectEqual(MockServer.shared.requests.first?.query, "q=a%2Bb%20c%26d&scope=all", "strict query encoding")
    _ = try? await api.foods(query: "  ", scope: .mine)
    expectEqual(MockServer.shared.requests.last?.query, "scope=mine", "empty q omitted")

    MockServer.shared.reset { _ in .json(200, #"{"token":"nl_x"}"#) }
    let personal = try? await api.regeneratePersonalToken()
    expectEqual(personal, "nl_x", "settings/token result")
    let post = MockServer.shared.requests.first
    expectEqual(post?.method, "POST", "POST method")
    expectEqual(post?.headers["Content-Type"], "application/json", "POST content type")
    expectEqual(post?.bodyText, "{}", "bodiless POST sends {}")

    MockServer.shared.reset { _ in .json(200, #"{"ok":true}"#) }
    try? await api.deleteMeal(id: 7)
    let del = MockServer.shared.requests.first
    expectEqual(del?.method, "DELETE", "DELETE method")
    expectEqual(del?.path, "/api/v1/meals/7", "DELETE path")
    check(del?.body?.isEmpty ?? true, "DELETE has no body")
    expectNil(del?.headers["Content-Type"], "DELETE has no content type")

    try? await api.putActivity(date: "2026-10-02", ActivityValues(steps: 8000, sleep_hours: nil))
    let put = MockServer.shared.requests.last
    expectEqual(put?.method, "PUT", "PUT method")
    expectEqual(put?.bodyText, #"{"steps":8000}"#, "nil activity fields omitted (= cleared)")

    try? await api.setExerciseInDevice(id: 3, inDevice: true)
    expectEqual(MockServer.shared.requests.last?.method, "PATCH", "PATCH method")
    expectEqual(MockServer.shared.requests.last?.bodyText, #"{"in_device":true}"#, "PATCH body")

    MockServer.shared.reset { _ in .json(200, #"{"start":"2026-01-01","end":"2026-01-02","days":[]}"#) }
    _ = try? await api.trends(start: "2026-01-01", end: "2026-01-02", user: nil)
    expectEqual(MockServer.shared.requests.first?.timeout, 120, "trends timeout 120 s")
    expectEqual(MockServer.shared.requests.first?.query, "start=2026-01-01&end=2026-01-02", "trends query, no user")

    MockServer.shared.reset { _ in .json(200, #"[{"name":"饮用水","food_id":null,"amount_g":250,"n":3,"last":"2026-10-01"},{"name":"鸡蛋","food_id":7,"amount_g":50,"n":2,"last":"2026-10-02"}]"#) }
    let recent = try? await api.recentItems()
    expectEqual(recent?.map(\.name), ["鸡蛋"], "recent items drop 饮用水")

    MockServer.shared.reset { r in
        r.bodyText.contains(#""device_name":"iPhone · 食迹 iOS""#) && r.bodyText.contains(#""username":"demo""#)
            ? .json(200, #"{"token":"nla_new","expires_at":"2027-10-03T21:38:50.123Z","user":null}"#)
            : .json(400, #"{"error":"bad body"}"#)
    }
    let login = try? await api.login(username: " demo ", password: " pw ", deviceName: "iPhone · 食迹 iOS")
    expectEqual(login?.token, "nla_new", "login trims and sends device_name")
    expectEqual(MockServer.shared.requests.first?.path, "/api/v1/auth/token", "login uses auth/token, never auth/login")

    let prefixed = makeClient(base: URL(string: "https://example.com/nl")!)
    MockServer.shared.reset { _ in .json(200, #"{"ok":true,"version":"1"}"#) }
    let ping = try? await prefixed.health()
    expectEqual(ping?.version, "1", "health decoded")
    expectEqual(MockServer.shared.requests.first?.url.absoluteString, "https://example.com/nl/api/v1/health", "base path prefix kept")
}

// MARK: - Response mapping and the 401 rules (B.4)

section("Responses")
do {
    let api = makeClient()
    let handlerCalls = CallCounter()
    await api.setUnauthorizedHandler { await handlerCalls.hit() }

    MockServer.shared.reset { _ in .json(401, #"{"error":"用户名或密码错误"}"#) }
    var e = await apiError { _ = try await api.login(username: "a", password: "b", deviceName: "d") }
    expectEqual(e, .http(status: 401, message: "用户名或密码错误"), "auth/token 401 is a login failure")
    e = await apiError { _ = try await api.authConfig() }
    expectEqual(e, .http(status: 401, message: "用户名或密码错误"), "auth/config 401 is not a session expiry")
    await api.logout()
    expectEqual(await handlerCalls.count, 0, "credential paths never call the handler")

    // 401 while the token is still valid (auth/me probe → 200): not a revocation.
    MockServer.shared.reset { r in r.path.hasSuffix("/auth/me") ? .json(200, "{}") : .json(401, unauthorizedBody) }
    e = await apiError { _ = try await api.users() }
    expectEqual(e, .http(status: 401, message: "未登录或令牌已失效"), "unconfirmed 401 keeps the session")
    expectEqual(MockServer.shared.requests.map(\.path), ["/api/v1/users", "/api/v1/auth/me"], "probe with auth/me")
    expectEqual(MockServer.shared.requests.last?.bearer, "nla_A", "probe sends the same token")
    expectEqual(await handlerCalls.count, 0, "handler not called when the token is valid")

    // Real revocation: auth/me also 401 → handler once, then `.unauthorized`.
    MockServer.shared.reset { _ in .json(401, unauthorizedBody) }
    e = await apiError { _ = try await api.users() }
    expectEqual(e, .unauthorized(message: "登录已失效，请重新登录"), "revoked token → unauthorized")
    expectEqual(await handlerCalls.count, 1, "handler called once")
    e = await apiError { _ = try await api.labs() }
    expectEqual(e, .unauthorized(message: "登录已失效，请重新登录"), "later 401 with the same token")
    expectEqual(await handlerCalls.count, 1, "handler not called twice for the same token")

    // 401 on auth/me itself needs no probe.
    let api2 = makeClient(token: "nla_C")
    let calls2 = CallCounter()
    await api2.setUnauthorizedHandler { await calls2.hit() }
    e = await apiError { _ = try await api2.me() }
    expectEqual(e, .unauthorized(message: "登录已失效，请重新登录"), "auth/me 401")
    expectEqual(MockServer.shared.requests.filter { $0.bearer == "nla_C" }.count, 1, "no probe for auth/me")
    expectEqual(await calls2.count, 1, "auth/me 401 calls the handler")

    // No token at all: never the handler.
    let anon = makeClient(token: nil)
    let calls3 = CallCounter()
    await anon.setUnauthorizedHandler { await calls3.hit() }
    e = await apiError { _ = try await anon.users() }
    expectEqual(e, .unauthorized(message: "登录已失效，请重新登录"), "anonymous 401")
    expectNil(MockServer.shared.requests.last?.headers["Authorization"], "no Authorization header without a token")
    expectEqual(await calls3.count, 0, "anonymous 401 does not call the handler")

    // Token rotated while the request was in flight → transparent replay with the new token.
    let api3 = makeClient(token: "nla_A")
    let calls4 = CallCounter()
    await api3.setUnauthorizedHandler { await calls4.hit() }
    MockServer.shared.reset { r in
        if r.bearer == "nla_A" {
            let done = DispatchSemaphore(value: 0)
            Task { await api3.setToken("nla_B"); done.signal() }
            done.wait()
            return .json(401, unauthorizedBody)
        }
        return .json(200, "[]")
    }
    let rotated = try? await api3.users()
    expectEqual(rotated?.count, 0, "replayed request succeeds")
    expectEqual(MockServer.shared.requests.map(\.bearer), ["nla_A", "nla_B"], "replay uses the new token")
    expectEqual(await calls4.count, 0, "rotation is not a revocation")

    // Other statuses.
    MockServer.shared.reset { _ in .json(404, #"{"error":"接口不存在"}"#) }
    e = await apiError { _ = try await api3.healthSyncState() }
    expectEqual(e, .unsupportedByServer, "404 接口不存在 → unsupportedByServer")
    expectEqual(MockServer.shared.requests.first?.timeout, 120, "health/sync/state timeout 120 s")
    MockServer.shared.reset { _ in .json(404, #"{"error":"食物不存在"}"#) }
    e = await apiError { _ = try await api3.food(id: 9) }
    expectEqual(e, .http(status: 404, message: "食物不存在"), "plain 404")
    MockServer.shared.reset { _ in MockResponse(status: 502, body: Data("<html>bad gateway</html>".utf8), contentType: "text/html") }
    e = await apiError { _ = try await api3.users() }
    expectEqual(e, .http(status: 502, message: "请求失败（502）"), "proxy HTML page")
    MockServer.shared.reset { _ in .json(200, #"{"ok":"yes","version":"1"}"#) }
    e = await apiError { _ = try await api3.health() }
    expectEqual(e, .decoding(message: "ok"), "decoding error names the key path")
    MockServer.shared.reset { _ in .fail(.notConnectedToInternet) }
    e = await apiError { _ = try await api3.users() }
    expectEqual(e, .network(message: "网络连接失败，请检查网络或服务器地址"), "offline")
    MockServer.shared.reset { _ in .fail(.timedOut) }
    e = await apiError { _ = try await api3.users() }
    expectEqual(e, .network(message: "请求超时"), "timeout")

    // A same-origin absolute path only; the token never goes to another host.
    MockServer.shared.reset { _ in .json(200, "{}") }
    e = await apiError { _ = try await api3.rawData(absolutePath: "http://evil.example/x") }
    check(e != nil && MockServer.shared.requests.isEmpty, "rawData rejects absolute URLs")
    e = await apiError { _ = try await api3.photoData(id: "../etc") }
    expectEqual(e, .http(status: 404, message: "不存在"), "invalid photo id rejected locally")

    // A 401 without the server's `{"error": …}` body (captive portal, proxy) never counts as a revocation.
    let portal = makeClient(token: "nla_P")
    let calls5 = CallCounter()
    await portal.setUnauthorizedHandler { await calls5.hit() }
    MockServer.shared.reset { _ in MockResponse(status: 401, body: Data("<html>login</html>".utf8), contentType: "text/html") }
    e = await apiError { _ = try await portal.me() }
    expectEqual(e, .http(status: 401, message: "请求失败（401）"), "HTML 401 on auth/me is not a revocation")
    expectEqual(await calls5.count, 0, "HTML 401 on auth/me does not call the handler")
    MockServer.shared.reset { r in
        r.path.hasSuffix("/auth/me") ? MockResponse(status: 401, body: Data("<html>login</html>".utf8), contentType: "text/html")
            : .json(401, unauthorizedBody)
    }
    e = await apiError { _ = try await portal.users() }
    expectEqual(e, .http(status: 401, message: "未登录或令牌已失效"), "probe answered by an intermediary → not confirmed")
    expectEqual(await calls5.count, 0, "intermediary probe does not call the handler")

    // Launch probes and logout use short timeouts.
    MockServer.shared.reset { _ in .json(500, #"{"error":"x"}"#) }
    _ = await apiError { _ = try await portal.me(timeout: APIClient.launchTimeout) }
    _ = await apiError { _ = try await portal.authConfig(timeout: APIClient.launchTimeout) }
    await portal.logout()
    expectEqual(MockServer.shared.requests.map(\.timeout), [15, 15, 10], "auth/me + auth/config 15 s at launch, auth/logout 10 s")

    // The logout request is built before the local wipe and still goes to the old server with the old token.
    let leaving = makeClient(token: "nla_OLD")
    let revoke = await leaving.logoutRequest()
    await leaving.setToken(nil)
    await leaving.setBaseURL(URL(string: "http://other.local:9000")!)
    MockServer.shared.reset { _ in .json(401, unauthorizedBody) }
    if let revoke { await leaving.sendLogout(revoke) } else { check(false, "logoutRequest built") }
    expectEqual(MockServer.shared.requests.map(\.url.absoluteString), ["http://test.local:8787/api/v1/auth/logout"], "old base URL")
    expectEqual(MockServer.shared.requests.first?.bearer, "nla_OLD", "old token")
    expectEqual(MockServer.shared.requests.first?.method, "POST", "POST")
    expectEqual(MockServer.shared.requests.first?.bodyText, "{}", "body {}")
    expectNil(await leaving.logoutRequest(), "no logout request without a token")
}

// MARK: - Uploads (meals §2.1)

section("Uploads")
do {
    let api = makeClient()
    MockServer.shared.reset { _ in .json(200, #"{"photos":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa.jpg","url":"/api/uploads/aaaaaaaaaaaaaaaaaaaaaaaa.jpg"},{"id":"bbbbbbbbbbbbbbbbbbbbbbbb.jpg","url":"/api/uploads/bbbbbbbbbbbbbbbbbbbbbbbb.jpg"}]}"#) }
    let photos = try? await api.uploadPhotos(jpegs: [Data("one".utf8), Data("two".utf8)])
    expectEqual(photos?.map(\.id), ["aaaaaaaaaaaaaaaaaaaaaaaa.jpg", "bbbbbbbbbbbbbbbbbbbbbbbb.jpg"], "upload result")
    let r = MockServer.shared.requests.first
    expectEqual(r?.path, "/api/v1/uploads", "upload path")
    check(r?.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=NutriLog-") ?? false, "multipart content type")
    let text = r?.bodyText ?? ""
    check(text.contains(#"name="photos"; filename="photo1.jpg""#) && text.contains(#"name="photos"; filename="photo2.jpg""#), "field photos, photo{n}.jpg")
    check(text.contains("Content-Type: image/jpeg"), "image/jpeg parts")
    expectEqual(r?.timeout, 180, "upload timeout 180 s")
    MockServer.shared.reset { _ in .json(200, #"{"photos":[]}"#) }
    let e = await apiError { _ = try await api.uploadPhotos(jpegs: Array(repeating: Data([1]), count: 7)) }
    check(e?.status == 400 && MockServer.shared.requests.isEmpty, "more than 6 photos rejected before sending")
    let none = try? await api.uploadPhotos(jpegs: [])
    expectEqual(none?.count, 0, "nothing to upload")
}

// MARK: - JobPoller (meals §2.7)

section("JobPoller")
do {
    let api = makeClient()
    let polls = LockedCounter()
    MockServer.shared.reset { _ in
        switch polls.next() {
        case 1: return .json(200, #"{"id":"j","kind":"meal","status":"queued","error":null,"result":null}"#)
        case 2: return .json(200, #"{"id":"j","kind":"meal","status":"running","error":null,"result":null}"#)
        case 3: return .fail(.networkConnectionLost)
        default: return .json(200, #"{"id":"j","kind":"meal","status":"done","error":null,"result":{"ok":true,"version":"7"}}"#)
        }
    }
    let recorder = PhaseRecorder()
    let result = try? await JobPoller(api: api, interval: .milliseconds(5)).wait(jobId: "j", as: HealthPing.self) { recorder.phases.append($0) }
    expectEqual(result?.version, "7", "done returns result")
    expectEqual(recorder.phases, [.queued, .running], "phases reported")
    expectEqual(MockServer.shared.requests.first?.path, "/api/v1/ai/jobs/j", "poll path")
    expectEqual(MockServer.shared.requests.count, 4, "one network blip tolerated")

    MockServer.shared.reset { _ in .json(200, #"{"id":"j","kind":"summary","status":"done","error":null,"result":null}"#) }
    let empty: WeeklySummary?? = try? await JobPoller(api: api).wait(jobId: "j", as: WeeklySummary.self)
    check(empty != nil && empty! == nil, "done with null result returns nil")

    MockServer.shared.reset { _ in .json(200, #"{"id":"j","kind":"meal","status":"error","error":"服务器重启，任务中断，请重试","result":null}"#) }
    var e = await apiError { _ = try await JobPoller(api: api).wait(jobId: "j", as: HealthPing.self) }
    expectEqual(e, .jobFailed(message: "服务器重启，任务中断，请重试"), "error status")
    MockServer.shared.reset { _ in .json(200, #"{"id":"j","kind":"meal","status":"error","error":null,"result":null}"#) }
    e = await apiError { _ = try await JobPoller(api: api).wait(jobId: "j", as: HealthPing.self) }
    expectEqual(e, .jobFailed(message: "AI 任务失败"), "error fallback text")
    MockServer.shared.reset { _ in .json(404, #"{"error":"任务不存在"}"#) }
    e = await apiError { _ = try await JobPoller(api: api).wait(jobId: "j", as: HealthPing.self) }
    expectEqual(e, .http(status: 404, message: "任务不存在"), "unknown job")

    MockServer.shared.reset { _ in .json(200, #"{"id":"j","kind":"meal","status":"running","error":null,"result":null}"#) }
    let poll = Task { try await JobPoller(api: api, interval: .milliseconds(10)).wait(jobId: "j", as: HealthPing.self) }
    try? await Task.sleep(for: .milliseconds(60))
    poll.cancel()
    var cancelled = false
    do { _ = try await poll.value } catch is CancellationError { cancelled = true } catch {}
    check(cancelled, "cancelling the task stops polling with CancellationError")
    try? await Task.sleep(for: .milliseconds(150))   // a cancelled URLSessionTask may still reach the mock; let it settle
}

// MARK: - PhotoCache (meals §2.2)

section("PhotoCache")
do {
    let api = makeClient()
    MockServer.shared.reset { r in
        if r.path.hasSuffix("missing.jpg") { return .json(404, #"{"error":"不存在"}"#) }
        return MockResponse(status: 200, body: Data("12345".utf8), contentType: "image/jpeg", delay: 0.05)
    }
    // Only `uploads/` requests count: a late request from an earlier (cancelled) section must not skew the numbers.
    func photoRequests() -> [RecordedRequest] { MockServer.shared.requests.filter { $0.path.hasPrefix("/api/v1/uploads/") } }
    let cache = PhotoCache(capacityBytes: 10)
    async let first = cache.data(for: "a.jpg", api: api)
    async let second = cache.data(for: "a.jpg", api: api)
    let pair = try? await (first, second)
    expectEqual(pair?.0, Data("12345".utf8), "bytes returned")
    expectEqual(photoRequests().count, 1, "concurrent requests coalesced")
    expectEqual(photoRequests().first?.path, "/api/v1/uploads/a.jpg", "photo path is /api/v1/uploads/{id}")
    expectEqual(photoRequests().first?.headers["Authorization"], "Bearer nla_A", "photo request is authenticated")
    _ = try? await cache.data(for: "a.jpg", api: api)
    expectEqual(photoRequests().count, 1, "cache hit")
    _ = try? await cache.data(for: "b.jpg", api: api)
    _ = try? await cache.data(for: "c.jpg", api: api)     // 15 bytes > 10: evicts a (LRU)
    _ = try? await cache.data(for: "a.jpg", api: api)
    expectEqual(photoRequests().count, 4, "LRU eviction refetches the oldest")
    var e = await apiError { _ = try await cache.data(for: "missing.jpg", api: api) }
    expectEqual(e, .http(status: 404, message: "不存在"), "404 surfaces")
    e = await apiError { _ = try await cache.data(for: "missing.jpg", api: api) }
    expectEqual(photoRequests().count, 5, "404 remembered")
    await cache.store(Data("xy".utf8), for: "seeded.jpg")
    let seeded = try? await cache.data(for: "seeded.jpg", api: api)
    expectEqual(seeded, Data("xy".utf8), "seeded bytes served")
    expectEqual(photoRequests().count, 5, "seeded photo needs no request")
    await cache.clear()
    _ = try? await cache.data(for: "seeded.jpg", api: api)
    expectEqual(photoRequests().count, 6, "clear empties the cache")
}

summary()
