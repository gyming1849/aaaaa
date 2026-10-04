import Foundation

// MARK: - Sleep night attribution (DESIGN §B.5 step 2, body §12.3)
// `sleep_hours` on date D is the sleep that ended on the morning of D: asleep intervals inside the window
// (D−1 18:00, D 18:00] in the profile time zone, clipped to the window and unioned across sources (never summed).
// When any asleep sample in the window comes from an Apple Watch, only Watch samples count. Without asleep data the
// `inBed` union is used and flagged as approximate. No data → no entry (the server must not get 0).
// Foundation only (HealthKit category raw values are mirrored as plain Ints) so the logic tests can run it on macOS.

/// One `HKCategorySample` of `sleepAnalysis`, reduced to what the aggregation needs.
struct SleepSegment: Sendable, Hashable {
    let start: Date
    let end: Date
    /// `HKCategoryValueSleepAnalysis` raw value: 0 inBed, 1 asleepUnspecified, 2 awake, 3 core, 4 deep, 5 REM.
    let value: Int
    /// `sourceRevision.productType` starts with `Watch`.
    let isWatch: Bool
}

struct SleepNight: Sendable, Equatable {
    /// Hours, rounded to 0.01.
    let hours: Double
    /// True when only `inBed` time was available (iPhone sleep schedule).
    let approximate: Bool
}

enum SleepAggregator {
    /// asleepUnspecified, asleepCore, asleepDeep, asleepREM.
    static let asleepValues: Set<Int> = [1, 3, 4, 5]
    static let inBedValue = 0
    /// The window opens at 18:00 the evening before.
    static let windowHour = 18

    /// `(D−1 18:00, D 18:00]` in `timeZone`.
    static func window(for date: String, in timeZone: TimeZone) -> DateInterval? {
        guard let end = at18(date, timeZone), let start = at18(LocalDay.addDays(date, -1), timeZone), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The span covering every window of `dates` (for the HealthKit query).
    static func querySpan(dates: [String], in timeZone: TimeZone) -> DateInterval? {
        guard let first = dates.min(), let last = dates.max(),
              let a = window(for: first, in: timeZone), let b = window(for: last, in: timeZone) else { return nil }
        return DateInterval(start: a.start, end: b.end)
    }

    /// Night per date; dates without sleep data are absent.
    static func hoursByDay(_ segments: [SleepSegment], dates: [String], in timeZone: TimeZone) -> [String: SleepNight] {
        var out: [String: SleepNight] = [:]
        for date in Set(dates) {
            guard let w = window(for: date, in: timeZone), let n = night(segments, window: w) else { continue }
            out[date] = n
        }
        return out
    }

    /// Aggregates one window.
    static func night(_ segments: [SleepSegment], window: DateInterval) -> SleepNight? {
        let inWindow = segments.compactMap { s -> (SleepSegment, Date, Date)? in
            let a = max(s.start, window.start), b = min(s.end, window.end)
            return b > a ? (s, a, b) : nil
        }
        var asleep = inWindow.filter { asleepValues.contains($0.0.value) }
        if asleep.contains(where: { $0.0.isWatch }) { asleep = asleep.filter { $0.0.isWatch } }
        let asleepSeconds = unionDuration(asleep.map { ($0.1, $0.2) })
        if asleepSeconds > 0 { return SleepNight(hours: hours(asleepSeconds), approximate: false) }
        let inBed = inWindow.filter { $0.0.value == inBedValue }
        let inBedSeconds = unionDuration(inBed.map { ($0.1, $0.2) })
        if inBedSeconds > 0 { return SleepNight(hours: hours(inBedSeconds), approximate: true) }
        return nil
    }

    /// Total length of the union of the intervals (overlaps counted once).
    static func unionDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for iv in sorted {
            if let c = current, iv.0 <= c.1 {
                current = (c.0, max(c.1, iv.1))
            } else {
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                current = iv
            }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    private static func hours(_ seconds: TimeInterval) -> Double {
        min(24, HealthRound.value(seconds / 3600, decimals: 2))
    }

    private static func at18(_ date: String, _ timeZone: TimeZone) -> Date? {
        guard let p = LocalDay.parts(date) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: windowHour))
    }
}
