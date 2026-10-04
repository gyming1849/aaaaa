import Foundation

// MARK: - Account (auth §3–4, DESIGN §C)

/// `PublicUser` (`/auth/token`) and `MeUser` (`/auth/me`, which adds `share_with`).
struct User: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let username: String; let display_name: String; let avatar_color: String
    let share_mode: String; let share_detail: String; let api_token_hint: String?
    let share_with: [Int]?
}

/// `me.ai` (auth §3.8): provider `cli | api | mock`; model `"offline"` when mock.
struct AIInfo: Codable, Sendable, Hashable { let provider: String; let model: String; var isMock: Bool { provider == "mock" } }

struct ConditionDef: Codable, Sendable, Hashable, Identifiable { let key: String; let zh: String; let effect: String; var id: String { key } }

/// auth §4.3. `PUT /profile` is a full replace: always send the complete object.
struct Profile: Codable, Sendable, Equatable {
    var sex: String; var birth_date: String; var height_cm: Double; var weight_kg: Double
    var activity_level: String; var goal: String; var goal_rate_kg_week: Double; var target_weight_kg: Double?
    var physiology: String; var sodium_mode: String; var conditions: [String]; var timezone: String
    var nicotine: String; var secondhand_smoke: Bool
    static func newDefault(timezone: String) -> Profile {
        Profile(sex: "male", birth_date: "1995-01-01", height_cm: 170, weight_kg: 65, activity_level: "low_active", goal: "maintain",
                goal_rate_kg_week: 0.5, target_weight_kg: nil, physiology: "none", sodium_mode: "cdrr", conditions: [],
                timezone: timezone, nicotine: "unknown", secondhand_smoke: false)
    }
}

extension Profile {
    /// Responses always carry every key (auth §4.3), but `nicotine` / `secondhand_smoke` are optional in the web type,
    /// so absent optional fields fall back to the server defaults of `PUT /profile` (auth §3.10).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        sex = try c.req("sex")
        birth_date = try c.req("birth_date")
        height_cm = try c.req("height_cm")
        weight_kg = try c.req("weight_kg")
        activity_level = try c.or("activity_level", "low_active")
        goal = try c.or("goal", "maintain")
        goal_rate_kg_week = try c.or("goal_rate_kg_week", 0.5)
        target_weight_kg = try c.opt("target_weight_kg")
        physiology = try c.or("physiology", "none")
        sodium_mode = try c.or("sodium_mode", "cdrr")
        conditions = try c.or("conditions", [])
        timezone = try c.or("timezone", "Asia/Shanghai")
        nicotine = try c.or("nicotine", "unknown")
        secondhand_smoke = try c.flexBool("secondhand_smoke", or: false)
    }
}

/// `GET /auth/me`. `profile` is `null` until onboarding; `today` is in the profile time zone.
struct Me: Codable, Sendable { let user: User; let profile: Profile?; let today: String; let ai: AIInfo; let conditions: [ConditionDef] }

struct LoginBody: Encodable, Sendable { let username: String; let password: String; let device_name: String }
struct RegisterBody: Encodable, Sendable { let username: String; let password: String; let display_name: String; let invite_code: String; let device_name: String }

/// `/auth/token` (with `user`), `/auth/register` + `device_name` and `/auth/refresh` (no `user`).
struct TokenResponse: Decodable, Sendable { let token: String; let expires_at: String; let user: User? }

/// `GET /auth/sessions` row (auth §4.7). Timestamps: `created_at`/`last_used_at` SQLite UTC, `expires_at` ISO-8601.
struct SessionRow: Decodable, Sendable, Identifiable, Hashable {
    let id: Int; let kind: String; let device_name: String?; let created_at: String?; let last_used_at: String?; let expires_at: String
    let current: Bool?            // S7 (new server field); nil on old servers
}

/// `PUT /settings`: always send all five fields (auth §3.12).
struct SettingsBody: Encodable, Sendable { var display_name: String; var avatar_color: String; var share_mode: String; var share_detail: String; var share_with: [Int] }
struct PasswordBody: Encodable, Sendable { let old_password: String; let new_password: String }
struct ProfileSaveResponse: Decodable, Sendable { let ok: Bool; let profile: Profile }
struct PersonalTokenResponse: Decodable, Sendable { let token: String }

/// `GET /auth/config` (DESIGN §C.6).
struct AuthConfig: Decodable, Sendable { let allow_registration: Bool; let invite_required: Bool; let min_password: Int; let server_version: String; let features: [String] }

extension AuthConfig {
    /// Conservative fallbacks for a partial response: registration open, invite required, 6-character minimum, no features.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        allow_registration = try c.flexBool("allow_registration", or: true)
        invite_required = try c.flexBool("invite_required", or: true)
        min_password = try c.flexInt("min_password", or: 6)
        server_version = try c.or("server_version", "")
        features = try c.or("features", [])
    }

    /// Assumed when `GET /auth/config` is missing on an old server (§C.6): invite required, no features.
    static let legacy = AuthConfig(allow_registration: true, invite_required: true, min_password: 6, server_version: "", features: [])

    func supports(_ feature: String) -> Bool { features.contains(feature) }
}

struct DeleteAccountBody: Encodable, Sendable { let password: String }
/// `PUT ai/consent` body (App-only; servers with feature `ai_consent`).
struct AIConsentBody: Encodable, Sendable { let granted: Bool }
