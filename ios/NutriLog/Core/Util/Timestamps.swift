import Foundation

// MARK: - Server timestamp parsing (auth §9, rep §0.4)
// `expires_at` is ISO-8601 with milliseconds and `Z`; `created_at` / `last_used_at` / `updated_at` are SQLite
// `datetime('now')` strings `YYYY-MM-DD HH:MM:SS` in UTC without a zone suffix.

enum Timestamps {
    /// ISO-8601 (`2027-10-03T21:38:50.123Z`, with or without fractional seconds, `Z` or `±hh:mm`).
    /// Falls back to the SQLite form so either kind of server string is accepted.
    static func iso(_ s: String?) -> Date? {
        guard let t = trimmed(s) else { return nil }
        return parseISO(t) ?? parseSQLite(t)
    }

    /// SQLite `YYYY-MM-DD HH:MM:SS` interpreted as UTC (a `T` separator, fractional seconds or a trailing `Z` are tolerated).
    /// Falls back to ISO-8601 for strings with an explicit offset.
    static func sqlite(_ s: String?) -> Date? {
        guard let t = trimmed(s) else { return nil }
        return parseSQLite(t) ?? parseISO(t)
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func parseISO(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle())
    }

    private static func parseSQLite(_ s: String) -> Date? {
        let u = Array(s.utf8)
        // YYYY-MM-DD[ T]HH:MM:SS[.fff][Z]
        guard u.count >= 19, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
              u[10] == UInt8(ascii: " ") || u[10] == UInt8(ascii: "T"),
              u[13] == UInt8(ascii: ":"), u[16] == UInt8(ascii: ":"),
              let year = num(u, 0..<4), let month = num(u, 5..<7), let day = num(u, 8..<10),
              let hour = num(u, 11..<13), let minute = num(u, 14..<16), let second = num(u, 17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var nanos = 0
        var i = 19
        if i < u.count, u[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 100_000_000
            while i < u.count, let dgt = num(u, i..<(i + 1)) {
                nanos += dgt * scale
                scale /= 10
                i += 1
            }
        }
        if i < u.count, u[i] == UInt8(ascii: "Z") { i += 1 }
        guard i == u.count else { return nil }   // an explicit offset is handled by the ISO parser
        var cal = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        cal.timeZone = utc
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanos)
        guard let date = cal.date(from: comps), cal.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func num(_ u: [UInt8], _ r: Range<Int>) -> Int? {
        guard r.upperBound <= u.count else { return nil }
        var v = 0
        for i in r {
            let c = u[i]
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
            v = v * 10 + Int(c - UInt8(ascii: "0"))
        }
        return v
    }
}
