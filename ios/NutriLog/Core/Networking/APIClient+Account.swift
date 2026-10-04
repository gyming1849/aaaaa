import Foundation

// MARK: - Auth & account (auth §3, DESIGN §C.5–§C.8)

extension APIClient {
    /// `GET health` (public): `{"ok": true, "version": "1"}`.
    func health() async throws -> HealthPing { try await send(.get, "health") }

    /// `GET auth/config` (public, §C.6). On an old server this is a 404 (`.unsupportedByServer`) with a valid token,
    /// or a 401 without one (auth §1.4); the caller falls back to `AuthConfig.legacy`.
    /// `timeout`: `APIClient.launchTimeout` during launch; nil keeps the default.
    func authConfig(timeout: TimeInterval? = nil) async throws -> AuthConfig { try await send(.get, "auth/config", timeout: timeout) }

    /// `POST auth/token` (iOS login, auth §3.3). Username and password are trimmed, as the server does.
    /// A 401 here is `.http(401, "用户名或密码错误")`, never a session expiry.
    func login(username: String, password: String, deviceName: String) async throws -> TokenResponse {
        let body = LoginBody(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                             password: password.trimmingCharacters(in: .whitespacesAndNewlines),
                             device_name: Self.nonEmptyDeviceName(deviceName))
        return try await send(.post, "auth/token", body: AnyEncodable(body))
    }

    /// `POST auth/register` (auth §3.2). Always with a non-empty `device_name`, so the server returns an app token instead of
    /// setting a cookie. The response has no `user`; call `me()` next.
    func register(_ body: RegisterBody) async throws -> TokenResponse {
        let fixed = RegisterBody(username: body.username.trimmingCharacters(in: .whitespacesAndNewlines),
                                 password: body.password.trimmingCharacters(in: .whitespacesAndNewlines),
                                 display_name: body.display_name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 invite_code: body.invite_code.trimmingCharacters(in: .whitespacesAndNewlines),
                                 device_name: Self.nonEmptyDeviceName(body.device_name))
        return try await send(.post, "auth/register", body: AnyEncodable(fixed))
    }

    /// `POST auth/logout {}` (auth §3.5). Best effort: every error is swallowed (10 s timeout). `AppState.logout()` uses
    /// `logoutRequest()` + `sendLogout(_:)` instead, so the local wipe never waits for the network.
    func logout() async {
        do { try await sendNoContent(.post, "auth/logout") } catch { AppLog.net.notice("logout request failed (ignored)") }
    }

    /// `GET auth/me` (auth §3.8). `timeout`: `APIClient.launchTimeout` during launch; nil keeps the default.
    func me(timeout: TimeInterval? = nil) async throws -> Me { try await send(.get, "auth/me", timeout: timeout) }

    /// `GET auth/sessions` (auth §3.6; `current` from §C.7 on new servers).
    func sessions() async throws -> [SessionRow] { try await send(.get, "auth/sessions") }

    /// `DELETE auth/sessions/{id}` (auth §3.7). Always `{ok:true}`; deleting our own session logs us out on the next call.
    func deleteSession(id: Int) async throws { try await sendNoContent(.delete, "auth/sessions/\(id)") }

    /// `POST auth/password` (auth §3.9). The server does not trim `old_password`, so it is trimmed here.
    func changePassword(old: String, new: String) async throws {
        let body = PasswordBody(old_password: old.trimmingCharacters(in: .whitespacesAndNewlines), new_password: new)
        try await sendNoContent(.post, "auth/password", body: AnyEncodable(body))
    }

    /// `PUT profile` (auth §3.10): full replace, so always send the complete profile. Returns the stored, normalised profile.
    func saveProfile(_ profile: Profile) async throws -> Profile {
        let res: ProfileSaveResponse = try await send(.put, "profile", body: AnyEncodable(profile))
        return res.profile
    }

    /// `GET profile/targets?date=` (auth §3.11). `nil` date → today in the profile time zone.
    func targets(date: String?) async throws -> Targets {
        try await send(.get, "profile/targets", query: Self.items(["date": date]))
    }

    /// `PUT settings` (auth §3.12). All five fields, always (omitting sharing fields resets them).
    func saveSettings(_ body: SettingsBody) async throws { try await sendNoContent(.put, "settings", body: AnyEncodable(body)) }

    /// `POST settings/token {}` (auth §3.13). Returns the new personal `nl_` token, shown once.
    func regeneratePersonalToken() async throws -> String {
        let res: PersonalTokenResponse = try await send(.post, "settings/token")
        return res.token
    }

    /// `POST auth/refresh {}` (§C.8): rotates the app token. New servers keep the old token valid for ≤ 24 h, so a lost
    /// response can be retried; older servers invalidate it immediately.
    func refreshToken() async throws -> TokenResponse { try await send(.post, "auth/refresh") }

    /// `POST account/delete {password}` (§C.5). `.unsupportedByServer` on servers without WP-S.
    func deleteAccount(password: String) async throws {
        try await sendNoContent(.post, "account/delete", body: AnyEncodable(DeleteAccountBody(password: password.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    /// `PUT ai/consent {granted}`: the in-app answer to the third-party AI consent. Servers with feature `ai_consent` skip
    /// automatic AI summaries for HealthKit-syncing users without it. `.unsupportedByServer` on older servers.
    func setAIConsent(_ granted: Bool) async throws {
        try await sendNoContent(.put, "ai/consent", body: AnyEncodable(AIConsentBody(granted: granted)))
    }

    /// `GET users` (auth §3.14, rep §11): every member, ordered by id, including the caller.
    func users() async throws -> [CommunityUser] { try await send(.get, "users") }

    // MARK: Helpers shared by the endpoint groups

    /// Query items for the non-nil, non-empty values, in a stable order.
    nonisolated static func items(_ pairs: KeyValuePairs<String, String?>) -> [URLQueryItem] {
        pairs.compactMap { key, value in
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return URLQueryItem(name: key, value: v)
        }
    }

    /// The server treats an empty `device_name` as "web client" (cookie, no token), so never send one (auth §3.2).
    nonisolated static func nonEmptyDeviceName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? DeviceInfo.deviceName : String(t.prefix(60))
    }
}
