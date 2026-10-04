import Foundation

// MARK: - JSON coding (DESIGN §A.10: keys verbatim, no key strategies)

/// Type-erased `Encodable` request body.
struct AnyEncodable: Encodable, Sendable {
    private let encodeFn: @Sendable (Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ value: T) { encodeFn = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

/// Encoder/decoder factories. Coders are created per use (they are not `Sendable`, and statics must be).
enum JSONCoding {
    /// Request encoder. Never sets a key strategy, so `sodium_mg` / `energyTarget` stay verbatim.
    /// A NaN or ±∞ that slipped through is sent as `"0"`; the server coerces numeric strings with `Number(x)`
    /// (meals §0.5: "never send NaN or Infinity; sanitize to 0") instead of the whole request failing to encode.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "0", negativeInfinity: "0", nan: "0")
        return e
    }

    /// Response decoder. Default strategies only: keys verbatim, dates stay `String` (decoded by `Timestamps`/`LocalDay`).
    static func decoder() -> JSONDecoder { JSONDecoder() }

    /// Short human-readable location of a decoding failure, e.g. `score.items[3].value`.
    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "格式不符" }
        let context: DecodingError.Context
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): context = c
        case .keyNotFound(let key, let c):
            return path(c.codingPath + [key]).isEmpty ? "缺少字段" : path(c.codingPath + [key])
        @unknown default: return "格式不符"
        }
        let p = path(context.codingPath)
        return p.isEmpty ? "格式不符" : p
    }

    private static func path(_ keys: [CodingKey]) -> String {
        var out = ""
        for key in keys {
            if let i = key.intValue { out += "[\(i)]" } else { out += out.isEmpty ? key.stringValue : "." + key.stringValue }
        }
        return out
    }
}
