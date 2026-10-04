import Foundation
import Observation

// MARK: - Login / register state (web `pages/Login.tsx`; web2 §5.8, auth §3.2–§3.3, §9)

/// Form state for `LoginScreen`. iOS logs in with `POST /auth/token` and registers with `device_name` (both through
/// `AppState`), never with the cookie endpoints. Client validation mirrors the server and uses its exact messages.
@MainActor @Observable final class LoginModel {
    enum Mode: Sendable { case login, register }
    enum Field: Hashable, Sendable { case username, displayName, password, inviteCode }

    private(set) var mode: Mode = .login
    var username = "" { didSet { errors[.username] = nil } }
    var displayName = ""
    var password = "" { didSet { errors[.password] = nil } }
    var inviteCode = "" { didSet { errors[.inviteCode] = nil } }
    private(set) var isBusy = false
    private(set) var errors: [Field: String] = [:]

    init() {}

    var isRegister: Bool { mode == .register }
    var title: String { isRegister ? "创建账号" : "欢迎回来" }
    var subtitle: String { isRegister ? "注册后先建立个人档案" : "登录以继续记录" }
    var submitTitle: String { isRegister ? "注册" : "登录" }
    var toggleTitle: String { isRegister ? "已有账号？登录" : "还没有账号？注册" }

    /// `还没有账号？注册` / `已有账号？登录`: switches mode and clears messages (the typed username is kept).
    func toggleMode() {
        mode = isRegister ? .login : .register
        errors = [:]
    }

    func error(_ field: Field) -> String? { errors[field] }

    /// Whether the invite field is shown: hidden only when the server says no invite code is needed (DESIGN §C.6).
    /// With no `/auth/config` answer it stays visible, as on the web (`邀请码（站点设置了才需要）`).
    func showsInviteField(_ config: AuthConfig?) -> Bool { config?.invite_required ?? true }

    /// Registration closed by the server (`ALLOW_REGISTRATION=false`).
    func registrationClosed(_ config: AuthConfig?) -> Bool { config?.allow_registration == false }

    // MARK: Validation

    /// Server username rule (auth §3.2): the trimmed value is cut to 32 characters, then must match
    /// `^[\w一-龥.-]{2,32}$` (`\w` ASCII only). Longer input is accepted and truncated by the server, so it is not rejected here.
    static func isValidUsername(_ name: String) -> Bool {
        let scalars = Array(String(name.prefix(32)).unicodeScalars)
        guard (2...32).contains(scalars.count) else { return false }
        return scalars.allSatisfy { s in
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true          // 0-9 A-Z a-z
            case 0x5F, 0x2E, 0x2D: return true                              // _ . -
            case 0x4E00...0x9FA5: return true                               // 一-龥
            default: return false
            }
        }
    }

    /// Returns the first error (also stored per field), or nil when the form can be sent.
    @discardableResult
    func validate(config: AuthConfig?) -> String? {
        var e: [Field: String] = [:]
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            e[.username] = "用户名不能为空"
        } else if isRegister, !Self.isValidUsername(name) {
            e[.username] = "用户名为 2–32 位，可用中文、字母、数字、_ . -"
        }
        if pass.isEmpty {
            e[.password] = "密码不能为空"
        } else if isRegister {
            let minLength = max(1, config?.min_password ?? 6)
            if pass.utf16.count < minLength { e[.password] = "密码至少 \(minLength) 位" }
        }
        errors = e
        if isRegister, registrationClosed(config) { return "当前站点已关闭注册" }
        let order: [Field] = [.username, .displayName, .password, .inviteCode]
        return order.lazy.compactMap { e[$0] }.first
    }

    // MARK: Submit

    /// Validates, then `app.login` / `app.register`. On success `AppState` bootstraps and replaces this screen
    /// (with Onboarding after a registration). Errors are toasted with the server message and attached to the field.
    func submit(app: AppState) async {
        guard !isBusy else { return }
        if let message = validate(config: app.authConfig) {
            app.toasts.error(message)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            if isRegister {
                try await app.register(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                       password: password,
                                       displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                       inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                try await app.login(username: username, password: password)
            }
        } catch {
            let message = APIError.from(error).message
            attach(serverMessage: message)
            app.toasts.error(error)
        }
    }

    /// Puts a known server message under the field it is about (auth §3.2–§3.3 error lists).
    private func attach(serverMessage message: String) {
        switch message {
        case "用户名不能为空", "用户名为 2–32 位，可用中文、字母、数字、_ . -", "用户名已被占用":
            errors[.username] = message
        case "密码不能为空", "密码至少 6 位", "用户名或密码错误":
            errors[.password] = message
        case "邀请码不正确":
            errors[.inviteCode] = message
        default:
            break
        }
    }
}
