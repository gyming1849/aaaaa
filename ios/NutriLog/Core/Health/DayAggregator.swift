import Foundation

// MARK: - Daily totals → `SyncDay` (DESIGN §B.5 step 2, body §12.1–§12.3, server ranges §C.2)
// Foundation only, so the logic tests can run it on macOS.

/// The seven `activity_days` fields HealthKit fills. Raw values are the server keys.
enum HealthDayField: String, CaseIterable, Sendable, Codable {
    case steps, active_kcal, resting_kcal, distance_km, exercise_min, stand_hours, sleep_hours

    /// Chinese label (body §11 wording).
    var zh: String {
        switch self {
        case .steps: "步数"
        case .active_kcal: "活动能量"
        case .resting_kcal: "静息能量"
        case .distance_km: "步行+跑步距离"
        case .exercise_min: "锻炼分钟"
        case .stand_hours: "站立小时"
        case .sleep_hours: "睡眠"
        }
    }

    /// Rounding sent to the server (body §12.2): steps 1, energy 0.1, distance 0.01, minutes 1, stand 1, sleep 0.01.
    var decimals: Int {
        switch self {
        case .steps, .exercise_min, .stand_hours: 0
        case .active_kcal, .resting_kcal: 1
        case .distance_km, .sleep_hours: 2
        }
    }

    /// The server's accepted range (`PUT /activity` / `ACT_FIELDS`). An out-of-range value would reject the whole day,
    /// so values are clamped into it.
    var range: ClosedRange<Double> {
        switch self {
        case .steps: 0...200_000
        case .active_kcal: 0...10_000
        case .resting_kcal: 0...5_000
        case .distance_km: 0...500
        case .exercise_min: 0...1_440
        case .stand_hours, .sleep_hours: 0...24
        }
    }

    /// Chinese label for a server key (`kept_manual.fields`); unknown keys are shown as-is.
    static func zh(forKey key: String) -> String { HealthDayField(rawValue: key)?.zh ?? key }
}

/// Half-away-from-zero rounding to a number of decimals (matches the web's `Math.round` for positive values).
enum HealthRound {
    static func value(_ v: Double, decimals: Int) -> Double {
        guard v.isFinite else { return v }
        var p = 1.0
        for _ in 0..<max(0, decimals) { p *= 10 }
        return (v * p).rounded(.toNearestOrAwayFromZero) / p
    }
}

extension SyncDay {
    func value(_ field: HealthDayField) -> Double? {
        switch field {
        case .steps: steps
        case .active_kcal: active_kcal
        case .resting_kcal: resting_kcal
        case .distance_km: distance_km
        case .exercise_min: exercise_min
        case .stand_hours: stand_hours
        case .sleep_hours: sleep_hours
        }
    }

    mutating func set(_ field: HealthDayField, _ v: Double?) {
        switch field {
        case .steps: steps = v
        case .active_kcal: active_kcal = v
        case .resting_kcal: resting_kcal = v
        case .distance_km: distance_km = v
        case .exercise_min: exercise_min = v
        case .stand_hours: stand_hours = v
        case .sleep_hours: sleep_hours = v
        }
    }

    /// Server keys of the fields that carry a value.
    var valuedFields: [String] { HealthDayField.allCases.filter { value($0) != nil }.map(\.rawValue) }

    /// Nothing to send: no value and nothing to clear.
    var isEmpty: Bool { valuedFields.isEmpty && (clear ?? []).isEmpty }
}

// MARK: - Sent-days ledger

/// Which fields were last sent with a value, per date, for the last `windowDays` days. A field recorded here that
/// HealthKit no longer has (the user deleted the samples) is sent in `clear` — but only while the field is readable in
/// the run (DESIGN §B.5 step 2): until then it stays recorded, so the clear can go out later.
struct SentDaysLedger: Codable, Sendable, Equatable {
    static let windowDays = 14

    /// date → server keys sent non-nil (sorted).
    private(set) var days: [String: [String]] = [:]

    init(days: [String: [String]] = [:]) { self.days = days }

    func fields(on date: String) -> Set<String> { Set(days[date] ?? []) }

    /// Updates the entry for `day.date` after it was sent: fields sent in `clear` are forgotten, fields sent with a value are
    /// added, and fields whose clear was held back (not readable in this run) stay recorded. An empty result drops the entry.
    mutating func record(_ day: SyncDay) {
        let next = fields(on: day.date).subtracting(day.clear ?? []).union(day.valuedFields)
        days[day.date] = next.isEmpty ? nil : HealthDayField.allCases.map(\.rawValue).filter(next.contains)
    }

    mutating func forget(_ date: String) { days[date] = nil }

    /// Keeps only `today − (windowDays − 1) … today` (and nothing later than tomorrow).
    mutating func prune(today: String) {
        let oldest = LocalDay.addDays(today, -(Self.windowDays - 1))
        let newest = LocalDay.addDays(today, 1)
        days = days.filter { LocalDay.isValid($0.key) && $0.key >= oldest && $0.key <= newest }
    }
}

// MARK: - Assembly

enum DayAggregator {
    /// Rounds and clamps one reading; NaN / ±∞ become nil.
    static func normalize(_ v: Double?, field: HealthDayField) -> Double? {
        guard let v, v.isFinite else { return nil }
        let rounded = HealthRound.value(v, decimals: field.decimals)
        return min(max(rounded, field.range.lowerBound), field.range.upperBound)
    }

    /// Fields the ledger says were sent with a value for `date` but that HealthKit no longer has, in field order — limited
    /// to `readable` fields (those with a value on at least one date of the run).
    static func clearFields(for day: SyncDay, ledger: SentDaysLedger, readable: Set<HealthDayField>) -> [String] {
        let sent = ledger.fields(on: day.date)
        guard !sent.isEmpty else { return [] }
        return HealthDayField.allCases
            .filter { readable.contains($0) && sent.contains($0.rawValue) && day.value($0) == nil }
            .map(\.rawValue)
    }

    /// One `SyncDay` per date (ascending) that has a value or something to clear. A date without HealthKit data is
    /// never sent as 0 (`nil` = leave the server value alone).
    /// HealthKit reports a read denial as "no data": a field that is empty on every date of the run is treated as not
    /// readable (permission revoked, or Health data still downloading on a restored device), never as deleted.
    /// - Parameter readings: raw (unrounded) values per field per date key.
    static func makeDays(dates: [String], readings: [HealthDayField: [String: Double]], ledger: SentDaysLedger) -> [SyncDay] {
        let unique = Array(Set(dates)).sorted()
        let readable = Set(HealthDayField.allCases.filter { field in
            unique.contains { normalize(readings[field]?[$0], field: field) != nil }
        })
        var out: [SyncDay] = []
        for date in unique {
            var day = SyncDay(date: date)
            for field in HealthDayField.allCases {
                day.set(field, normalize(readings[field]?[date], field: field))
            }
            let clear = clearFields(for: day, ledger: ledger, readable: readable)
            day.clear = clear.isEmpty ? nil : clear
            if !day.isEmpty { out.append(day) }
        }
        return out
    }
}
