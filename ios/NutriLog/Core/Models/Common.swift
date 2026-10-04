import Foundation

// MARK: - Common (meals §0.5, rep §0.5–0.8)

/// Nutrient (43 keys) / food-group (22 keys) vector. Keys are the server keys verbatim.
typealias Vec = [String: Double]

extension Dictionary where Key == String, Value == Double {
    /// Missing keys read as 0 (server always sends every key, but be tolerant).
    func v(_ key: String) -> Double { self[key] ?? 0 }
}

/// `good | ok | warn | bad | info` (rep §0.8). Unknown strings decode as `.info`.
enum ScoreStatus: String, Codable, Sendable, CaseIterable {
    case good, ok, warn, bad, info
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScoreStatus(rawValue: raw) ?? .info
    }
}

struct KeyZh: Codable, Sendable, Hashable { let key: String; let zh: String }
struct OkResponse: Decodable, Sendable { let ok: Bool }
struct IdResponse: Decodable, Sendable { let id: Int }
struct JobCreated: Decodable, Sendable { let job_id: String }
enum JobStatus: String, Codable, Sendable { case queued, running, done, error }

/// `GET /ai/jobs/{id}` (meals §2.7). `result` is non-nil only when `status == .done`
/// (and may legitimately be nil for `summary` jobs).
struct Job<T: Decodable & Sendable>: Decodable, Sendable {
    let id: String; let kind: String; let status: JobStatus; let error: String?; let result: T?
}

/// `{title?, url}` (meals §1.12–1.14). `title` may be absent; extra properties are ignored.
struct SourceLink: Codable, Sendable, Hashable { var title: String?; var url: String }

/// `GET /health` → `{"ok": true, "version": "1"}`.
struct HealthPing: Decodable, Sendable { let ok: Bool; let version: String }

/// Encodes as `{}`; POST/PUT/PATCH always carry a JSON body (auth §0).
struct EmptyBody: Encodable, Sendable {}

// MARK: - Tolerant decoding helpers (used by hand-written `init(from:)` in Core/Models)

/// String coding key so hand-written decoders read the JSON keys verbatim (no key strategy, no renaming).
struct JSONKey: CodingKey, Hashable, Sendable, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(stringLiteral value: String) { stringValue = value }
}

extension KeyedDecodingContainer where Key == JSONKey {
    /// Required value; a missing key or `null` throws.
    func req<T: Decodable>(_ key: JSONKey) throws -> T { try decode(T.self, forKey: key) }

    /// Optional value: an absent key and an explicit `null` both give `nil` (rep §0.6).
    func opt<T: Decodable>(_ key: JSONKey) throws -> T? { try decodeIfPresent(T.self, forKey: key) }

    /// Value with a fallback for an absent key or `null`. A present value of the wrong type still throws.
    func or<T: Decodable>(_ key: JSONKey, _ fallback: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? fallback }

    /// Integer that may arrive as a JSON integer, an integral double, a boolean (`true` → 1) or a numeric string.
    /// Used for raw DB 0/1 flags (`in_device`, `bp_treated`, `lipid_treated`, `diabetes`; body §1.4).
    func flexIntIfPresent(_ key: JSONKey) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let b = try? decode(Bool.self, forKey: key) { return b ? 1 : 0 }
        if let d = try? decode(Double.self, forKey: key), d.isFinite, abs(d) < 9.0e15 { return Int(d.rounded()) }
        if let s = try? decode(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite, abs(d) < 9.0e15 { return Int(d.rounded()) }
            if t == "true" { return 1 }
            if t == "false" { return 0 }
        }
        throw DecodingError.typeMismatch(Int.self, .init(codingPath: codingPath + [key], debugDescription: "Expected an integer, 0/1 or boolean"))
    }

    func flexInt(_ key: JSONKey) throws -> Int {
        guard let v = try flexIntIfPresent(key) else {
            throw DecodingError.valueNotFound(Int.self, .init(codingPath: codingPath + [key], debugDescription: "Missing or null integer"))
        }
        return v
    }

    func flexInt(_ key: JSONKey, or fallback: Int) throws -> Int { try flexIntIfPresent(key) ?? fallback }

    /// Boolean that may arrive as a JSON boolean, a number (non-zero → true) or a string.
    func flexBoolIfPresent(_ key: JSONKey) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let b = try? decode(Bool.self, forKey: key) { return b }
        if let i = try? decode(Int.self, forKey: key) { return i != 0 }
        if let d = try? decode(Double.self, forKey: key) { return d != 0 && !d.isNaN }
        if let s = try? decode(String.self, forKey: key) {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: break
            }
        }
        throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath + [key], debugDescription: "Expected a boolean or 0/1"))
    }

    func flexBool(_ key: JSONKey, or fallback: Bool) throws -> Bool { try flexBoolIfPresent(key) ?? fallback }
}
