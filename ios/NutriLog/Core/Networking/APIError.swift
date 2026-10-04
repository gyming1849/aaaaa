import Foundation

// MARK: - Errors (DESIGN §B.4, auth §1.3 / §7, rep §0.3, meals §0.4)

/// Every error thrown by `APIClient`. Screens show `message` (verbatim server text where there is one).
enum APIError: Error, LocalizedError, Sendable, Equatable {
    case http(status: Int, message: String)
    case unauthorized(message: String)
    case network(message: String)
    case decoding(message: String)
    case jobFailed(message: String)
    case unsupportedByServer

    var message: String {
        switch self {
        case .http(_, let m), .unauthorized(let m), .network(let m), .jobFailed(let m): return m
        case .decoding(let m): return "数据解析失败：\(m)"
        case .unsupportedByServer: return "服务器版本过旧，暂不支持此功能"
        }
    }

    var status: Int? { if case .http(let s, _) = self { return s }; if case .unauthorized = self { return 401 }; return nil }
    var errorDescription: String? { message }

    /// Normalises any thrown error into an `APIError` (URLSession errors that escaped the client become `.network`).
    static func from(_ error: Error) -> APIError {
        if let e = error as? APIError { return e }
        if error is CancellationError { return .network(message: cancelledMessage) }
        if let e = error as? URLError { return from(urlError: e) }
        return .network(message: error.localizedDescription)
    }

    // MARK: Client-side wording

    /// `URLError` (no HTTP response at all), B.4 rule 6.
    static let networkMessage = "网络连接失败，请检查网络或服务器地址"
    static let timeoutMessage = "请求超时"
    /// Raised when the session token turned out to be revoked or expired (B.4 rule 3).
    static let sessionExpiredMessage = "登录已失效，请重新登录"
    /// Fallback when an AI job ends in `error` without a message (meals §2.7, web2 Appendix D).
    static let jobFailedMessage = "AI 任务失败"
    /// Web abort wording (web2 Appendix D).
    static let cancelledMessage = "已取消"

    /// Web fallback when the body has no `error` (auth §0, web2 §1.3): `请求失败（{status}）`.
    static func fallbackMessage(status: Int) -> String { "请求失败（\(status)）" }

    static func from(urlError e: URLError) -> APIError {
        e.code == .timedOut ? .network(message: timeoutMessage) : .network(message: networkMessage)
    }

    /// The server's `{"error": "…"}` text, or the web fallback for an empty / non-JSON body (e.g. a proxy HTML page).
    static func message(fromBody data: Data, status: Int) -> String {
        if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            let text = body.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return fallbackMessage(status: status)
    }
}

/// Error body shape of every endpoint: `{"error": "<中文>"}`.
struct APIErrorBody: Decodable, Sendable { let error: String }

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }
