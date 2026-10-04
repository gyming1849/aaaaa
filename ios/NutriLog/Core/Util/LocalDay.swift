import Foundation

// MARK: - Calendar dates as `YYYY-MM-DD` strings (web2 §1.4, web1 §0.2)
// The web does all date arithmetic in UTC on the date string, so this is pure proleptic-Gregorian day arithmetic:
// no device time zone, no DST. "Today" is always `app.today` (= `me.today`), never the device date.
// Invalid input is returned unchanged (or 0 / [] / nil), so a bad string can never crash a view.

enum LocalDay {
    private static let weekdayZh = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// `date ± n` days.
    static func addDays(_ date: String, _ n: Int) -> String {
        guard let z = dayNumber(date) else { return date }
        return string(fromDayNumber: z + n)
    }

    /// Whole days from `a` to `b` (`b − a`); 0 if either is invalid.
    static func diffDays(_ a: String, _ b: String) -> Int {
        guard let za = dayNumber(a), let zb = dayNumber(b) else { return 0 }
        return zb - za
    }

    /// Monday of the week containing `date`.
    static func weekStart(_ date: String) -> String {
        guard let z = dayNumber(date) else { return date }
        return string(fromDayNumber: z - (weekday(dayNumber: z) + 6) % 7)
    }

    static func monthStart(_ date: String) -> String { String(date.prefix(8)) + "01" }

    /// Last day of the month containing `date`.
    static func monthEnd(_ date: String) -> String {
        guard let p = parse(date) else { return date }
        return format(p.year, p.month, daysInMonth(p.year, p.month))
    }

    /// `date` moved by `n` calendar months; the day is clamped to the target month's length (`01-31 + 1 → 02-28`).
    static func addMonths(_ date: String, _ n: Int) -> String {
        guard let p = parse(date) else { return date }
        let total = p.year * 12 + (p.month - 1) + n
        let y = Int((Double(total) / 12).rounded(.down))
        let m = total - y * 12 + 1
        guard (0...9999).contains(y) else { return date }
        return format(y, m, min(p.day, daysInMonth(y, m)))
    }

    /// Every date from `start` through `end` inclusive; `[]` if `start > end` or either is invalid.
    static func range(_ start: String, _ end: String) -> [String] {
        guard let a = dayNumber(start), let b = dayNumber(end), a <= b else { return [] }
        return (a...b).map { string(fromDayNumber: $0) }
    }

    /// `M/D` without zero padding, e.g. `2026-09-04` → `9/4`.
    static func shortDate(_ date: String) -> String {
        guard let p = parse(date) else { return date }
        return "\(p.month)/\(p.day)"
    }

    /// `{M}月{D}日 {周X}`, prefixed with `今天 · ` or `昨天 · ` relative to `today` (e.g. `今天 · 9月30日 周三`).
    static func dateLabel(_ date: String, today: String) -> String {
        guard let p = parse(date), let z = dayNumber(date) else { return date }
        let base = "\(p.month)月\(p.day)日 \(weekdayZh[weekday(dayNumber: z)])"
        guard dayNumber(today) != nil else { return base }
        switch diffDays(date, today) {
        case 0: return "今天 · \(base)"
        case 1: return "昨天 · \(base)"
        default: return base
        }
    }

    /// Strict `YYYY-MM-DD` check with a real calendar day (rejects `2026-02-30`).
    static func isValid(_ date: String) -> Bool { parse(date) != nil }

    /// The calendar day of `date` in `timeZone` (use the profile time zone for HealthKit day keys).
    static func key(for date: Date, in timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return format(c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Start of the day `key` in `timeZone`.
    static func date(fromKey key: String, in timeZone: TimeZone) -> Date? {
        guard let p = parse(key) else { return nil }
        return calendar(timeZone).date(from: DateComponents(year: p.year, month: p.month, day: p.day))
    }

    /// The device's calendar date. Only a fallback before `me` is loaded.
    static func deviceToday() -> String { key(for: Date(), in: .current) }

    /// Current wall-clock time `HH:MM` in `timeZone`.
    static func nowHHMM(in timeZone: TimeZone = .current) -> String { hhmm(Date(), in: timeZone) }

    /// `HH:MM` (24 h, zero padded) of `date` in `timeZone`.
    static func hhmm(_ date: Date, in timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.hour, .minute], from: date)
        return pad2(c.hour ?? 0) + ":" + pad2(c.minute ?? 0)
    }

    // MARK: Extras

    /// Weekday of `date`, 0 = Sunday … 6 = Saturday.
    static func weekday(_ date: String) -> Int? { dayNumber(date).map { weekday(dayNumber: $0) } }

    /// Numeric parts of a valid date.
    static func parts(_ date: String) -> (year: Int, month: Int, day: Int)? {
        guard let p = parse(date) else { return nil }
        return (p.year, p.month, p.day)
    }

    /// True for a strict `HH:MM` 24-hour time (the server only checks `^\d{2}:\d{2}$`, so validate here).
    static func isValidTime(_ time: String) -> Bool {
        let u = Array(time.utf8)
        guard u.count == 5, u[2] == UInt8(ascii: ":"),
              let h = digits(u, 0..<2), let m = digits(u, 3..<5) else { return false }
        return h < 24 && m < 60
    }

    // MARK: Private helpers

    private struct YMD { let year: Int; let month: Int; let day: Int }

    private static func parse(_ s: String) -> YMD? {
        let u = Array(s.utf8)
        guard u.count == 10, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
              let y = digits(u, 0..<4), let m = digits(u, 5..<7), let d = digits(u, 8..<10),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        return YMD(year: y, month: m, day: d)
    }

    private static func digits(_ u: [UInt8], _ r: Range<Int>) -> Int? {
        var v = 0
        for i in r {
            let c = u[i]
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
            v = v * 10 + Int(c - UInt8(ascii: "0"))
        }
        return v
    }

    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return isLeap(y) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (H. Hinnant's `days_from_civil`).
    private static func dayNumber(_ s: String) -> Int? {
        guard let p = parse(s) else { return nil }
        let y = p.month <= 2 ? p.year - 1 : p.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (p.month + 9) % 12
        let doy = (153 * mp + 2) / 5 + p.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of `dayNumber` (`civil_from_days`).
    private static func string(fromDayNumber z0: Int) -> String {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return format(y, m, d)
    }

    /// 0 = Sunday (1970-01-01 was a Thursday).
    private static func weekday(dayNumber z: Int) -> Int { ((z % 7) + 7 + 4) % 7 }

    private static func format(_ y: Int, _ m: Int, _ d: Int) -> String {
        let ys = String(y)
        return String(repeating: "0", count: max(0, 4 - ys.count)) + ys + "-" + pad2(m) + "-" + pad2(d)
    }

    private static func pad2(_ v: Int) -> String { v < 10 ? "0\(v)" : String(v) }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}
