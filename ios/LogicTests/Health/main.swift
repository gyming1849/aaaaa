import Foundation
import HealthKit

// WP9 Health logic tests: SleepAggregator, WorkoutMapper (speed buckets, indoor/open-water rules, in_device),
// DayAggregator (rounding, clamping, `clear` from the sent-days ledger), upload chunking and text helpers.

let shanghai = TimeZone(identifier: "Asia/Shanghai")!
let utc = TimeZone(identifier: "UTC")!

/// `"2026-10-01 23:30"` in `tz`.
func at(_ s: String, _ tz: TimeZone = shanghai) -> Date {
    let parts = s.split(separator: " ")
    let d = LocalDay.parts(String(parts[0]))!
    let hm = parts[1].split(separator: ":").map { Int($0)! }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hm[0], minute: hm[1]))!
}

func seg(_ a: String, _ b: String, _ value: Int, watch: Bool = false) -> SleepSegment {
    SleepSegment(start: at(a), end: at(b), value: value, isWatch: watch)
}

// MARK: - SleepAggregator
section("SleepAggregator")
do {
    let w = SleepAggregator.window(for: "2026-10-02", in: shanghai)
    expectEqual(w?.start, at("2026-10-01 18:00"), "window starts 18:00 the evening before")
    expectEqual(w?.end, at("2026-10-02 18:00"), "window ends 18:00 on the day")
    expectEqual(w?.start, Date(timeIntervalSince1970: 1_790_848_800), "window start is 10:00Z for +08:00")

    // Overlapping sources (no Watch): union, not sum.
    let overlap = [seg("2026-10-01 23:00", "2026-10-02 07:00", 1), seg("2026-10-02 00:00", "2026-10-02 06:30", 3)]
    let n1 = SleepAggregator.hoursByDay(overlap, dates: ["2026-10-02"], in: shanghai)["2026-10-02"]
    expectApprox(n1?.hours, 8, "overlapping sources are unioned")
    expectEqual(n1?.approximate, false, "asleep data is not approximate")

    // Watch preference: iPhone/third-party asleep ignored when a Watch asleep sample exists.
    let mixed = [
        seg("2026-10-01 22:00", "2026-10-02 07:30", 1),
        seg("2026-10-01 23:30", "2026-10-02 03:00", 3, watch: true),
        seg("2026-10-02 03:00", "2026-10-02 04:00", 4, watch: true),
        seg("2026-10-02 04:00", "2026-10-02 06:45", 5, watch: true),
    ]
    expectApprox(SleepAggregator.hoursByDay(mixed, dates: ["2026-10-02"], in: shanghai)["2026-10-02"]?.hours, 7.25, "Watch samples preferred")

    // Awake gaps are not counted.
    let awake = [
        seg("2026-10-01 23:00", "2026-10-02 02:00", 3, watch: true),
        seg("2026-10-02 02:00", "2026-10-02 02:30", 2, watch: true),
        seg("2026-10-02 02:30", "2026-10-02 07:00", 4, watch: true),
    ]
    expectApprox(SleepAggregator.hoursByDay(awake, dates: ["2026-10-02"], in: shanghai)["2026-10-02"]?.hours, 7.5, "awake excluded")

    // 18:00 split: a segment crossing 18:00 is clipped into both nights; an afternoon nap counts for the same day.
    let split = [seg("2026-10-02 14:00", "2026-10-02 15:00", 1), seg("2026-10-02 17:00", "2026-10-02 19:00", 1)]
    let byDay = SleepAggregator.hoursByDay(split, dates: ["2026-10-02", "2026-10-03"], in: shanghai)
    expectApprox(byDay["2026-10-02"]?.hours, 2, "nap + clipped part before 18:00")
    expectApprox(byDay["2026-10-03"]?.hours, 1, "part after 18:00 belongs to the next day")

    // inBed fallback, flagged approximate; ignored when asleep data exists.
    let inBedOnly = [seg("2026-10-01 23:00", "2026-10-02 07:00", 0)]
    let n2 = SleepAggregator.hoursByDay(inBedOnly, dates: ["2026-10-02"], in: shanghai)["2026-10-02"]
    expectApprox(n2?.hours, 8, "inBed fallback hours")
    expectEqual(n2?.approximate, true, "inBed fallback is approximate")
    let both = [seg("2026-10-01 22:00", "2026-10-02 08:00", 0), seg("2026-10-01 23:00", "2026-10-02 06:00", 1)]
    let n3 = SleepAggregator.hoursByDay(both, dates: ["2026-10-02"], in: shanghai)["2026-10-02"]
    expectApprox(n3?.hours, 7, "asleep beats inBed")
    expectEqual(n3?.approximate, false, "asleep with inBed is exact")

    // Empty → nil (never 0); out-of-window samples ignored.
    expectNil(SleepAggregator.hoursByDay([], dates: ["2026-10-02"], in: shanghai)["2026-10-02"], "no data → nil")
    let elsewhere = [seg("2026-09-28 23:00", "2026-09-29 07:00", 1)]
    expectNil(SleepAggregator.hoursByDay(elsewhere, dates: ["2026-10-02"], in: shanghai)["2026-10-02"], "other nights ignored")

    // Rounding to 0.01 h.
    let odd = [seg("2026-10-01 23:00", "2026-10-02 06:20", 1)]
    expectApprox(SleepAggregator.hoursByDay(odd, dates: ["2026-10-02"], in: shanghai)["2026-10-02"]?.hours, 7.33, "rounded to 0.01")

    let span = SleepAggregator.querySpan(dates: ["2026-10-03", "2026-10-01", "2026-10-02"], in: shanghai)
    expectEqual(span?.start, at("2026-09-30 18:00"), "query span start")
    expectEqual(span?.end, at("2026-10-03 18:00"), "query span end")
    expectApprox(SleepAggregator.unionDuration([(at("2026-10-01 01:00"), at("2026-10-01 02:00")), (at("2026-10-01 01:30"), at("2026-10-01 03:00")), (at("2026-10-01 04:00"), at("2026-10-01 05:00"))]), 3 * 3600, "unionDuration")
}

// MARK: - WorkoutMapper
section("WorkoutMapper")
do {
    func key(_ type: HKWorkoutActivityType, km: Double? = nil, minutes: Double = 60, indoor: Bool = false,
             swim: HKWorkoutSwimmingLocationType? = nil, mets: Double? = nil) -> String? {
        WorkoutMapper.map(WorkoutFacts(activityType: type, durationSeconds: minutes * 60, distanceKm: km, indoor: indoor,
                                       swimmingLocation: swim, averageMETs: mets))?.activityKey
    }
    // Walking speed buckets (v<4.5 slow, <5.5 moderate, <6.4 brisk, else very brisk; no distance → moderate)
    expectEqual(key(.walking, km: 4), "walk_slow", "walk 4 km/h")
    expectEqual(key(.walking, km: 4.5), "walk_moderate", "walk 4.5 km/h boundary")
    expectEqual(key(.walking, km: 6), "walk_brisk", "walk 6 km/h")
    expectEqual(key(.walking, km: 7), "walk_very_brisk", "walk 7 km/h")
    expectEqual(key(.walking), "walk_moderate", "walk without distance")
    // Running
    expectEqual(key(.running, km: 8), "jogging", "run 8 km/h")
    expectEqual(key(.running, km: 10), "run_10kmh", "run 10 km/h")
    expectEqual(key(.running, km: 12), "run_13kmh", "run 12 km/h")
    expectEqual(key(.running, km: 15), "run_16kmh", "run 15 km/h")
    expectEqual(key(.running), "jogging", "run without distance")
    expectEqual(key(.running, km: 7.4, minutes: 45.2), "run_10kmh", "run 7.4 km in 45.2 min ≈ 9.8 km/h")
    // Cycling: indoor rule first
    expectEqual(key(.cycling, km: 30, indoor: true), "cycle_stationary", "indoor cycling")
    expectEqual(key(.cycling, km: 18), "cycle_leisure", "cycle 18 km/h")
    expectEqual(key(.cycling, km: 20), "cycle_moderate", "cycle 20 km/h")
    expectEqual(key(.cycling, km: 25), "cycle_vigorous", "cycle 25 km/h")
    expectEqual(key(.cycling), "cycle_leisure", "outdoor cycling without distance")
    // Swimming: open water / pool speed / unknown
    expectEqual(key(.swimming, km: 2, swim: .openWater), "swim_open_water", "open water")
    expectEqual(key(.swimming, km: 1, minutes: 30, swim: .pool), "swim_freestyle_slow", "pool 2 km/h")
    expectEqual(key(.swimming, km: 1.5, minutes: 30, swim: .pool), "swim_freestyle_medium", "pool 3 km/h")
    expectEqual(key(.swimming, km: 2, minutes: 30, swim: .pool), "swim_freestyle_fast", "pool 4 km/h")
    expectEqual(key(.swimming, swim: .pool), "swim_leisure", "pool without distance")
    expectEqual(key(.swimming, km: 2, minutes: 30, swim: .unknown), "swim_leisure", "unknown location")
    expectEqual(key(.swimming, km: 2, minutes: 30), "swim_leisure", "no location metadata")
    // Table rows
    expectEqual(key(.hiking), "hiking", "hiking")
    expectEqual(key(.stairClimbing), "stairs", "stair climbing")
    expectEqual(key(.stairs), "stairs", "stairs")
    expectEqual(key(.jumpRope), "jump_rope", "jump rope")
    expectEqual(key(.tennis), "tennis_singles", "tennis")
    expectEqual(key(.tableTennis), "table_tennis", "table tennis")
    expectEqual(key(.traditionalStrengthTraining), "strength_moderate", "traditional strength")
    expectEqual(key(.coreTraining), "strength_moderate", "core training")
    expectEqual(key(.functionalStrengthTraining), "strength_vigorous", "functional strength")
    expectEqual(key(.crossTraining), "circuit", "cross training")
    expectEqual(key(.mixedCardio), "circuit", "mixed cardio")
    expectEqual(key(.highIntensityIntervalTraining), "hiit", "HIIT")
    expectEqual(key(.rowing), "rowing_machine", "rowing")
    expectEqual(key(.cardioDance), "aerobic_dance", "cardio dance")
    expectEqual(key(HKWorkoutActivityType(rawValue: 14)!), "aerobic_dance", "legacy dance (raw 14)")
    expectEqual(key(.socialDance), "dance_social", "social dance")
    expectEqual(key(.flexibility), "other_light", "flexibility")
    expectEqual(key(.cooldown), "other_light", "cooldown")
    expectEqual(key(.mindAndBody), "other_light", "mind and body")
    expectEqual(key(.golf), "other_moderate", "other type → other_moderate")
    expectEqual(key(.golf, mets: 7), "other_vigorous", "other type with METs ≥ 6 → other_vigorous")

    // Descriptions
    func desc(_ type: HKWorkoutActivityType, indoor: Bool = false, swim: HKWorkoutSwimmingLocationType? = nil) -> String? {
        WorkoutMapper.map(WorkoutFacts(activityType: type, durationSeconds: 1800, distanceKm: nil, indoor: indoor, swimmingLocation: swim, averageMETs: nil))?.description
    }
    expectEqual(desc(.running), "户外跑步", "outdoor run name")
    expectEqual(desc(.running, indoor: true), "室内跑步", "indoor run name")
    expectEqual(desc(.swimming, swim: .pool), "泳池游泳", "pool swim name")
    expectEqual(desc(.swimming, swim: .openWater), "开放水域游泳", "open water name")
    expectEqual(desc(.golf), "高尔夫", "golf name")
    expectEqual(desc(.other), "其他中等强度活动", "unknown type falls back to the activity zh")

    // Duration and METs
    expectNil(WorkoutMapper.durationMinutes(seconds: 59), "under a minute is skipped")
    expectApprox(WorkoutMapper.durationMinutes(seconds: 90), 1.5, "90 s")
    expectApprox(WorkoutMapper.durationMinutes(seconds: 45.24 * 60), 45.2, "rounded to 0.1")
    expectApprox(WorkoutMapper.durationMinutes(seconds: 3000 * 60), 1440, "clamped to 1440")
    expectNil(WorkoutMapper.map(WorkoutFacts(activityType: .running, durationSeconds: 30, distanceKm: nil)), "30 s workout dropped")
    expectApprox(WorkoutMapper.clampMET(0.5), 1, "MET floor 1")
    expectApprox(WorkoutMapper.clampMET(30), 25, "MET ceiling 25")
    expectApprox(WorkoutMapper.clampMET(9.27), 9.3, "MET rounded")
    expectNil(WorkoutMapper.clampMET(nil), "no METs → server table")
    expectApprox(WorkoutMapper.map(WorkoutFacts(activityType: .running, durationSeconds: 1800, distanceKm: 5, averageMETs: 9.27))?.met, 9.3, "map carries METs")

    // in_device rule (body §8.1)
    expectEqual(WorkoutMapper.inDevice(deviceKcal: 480, dayActiveKcal: 412.3), true, "device energy + day active energy")
    expectEqual(WorkoutMapper.inDevice(deviceKcal: 480, dayActiveKcal: nil), false, "no day active energy")
    expectEqual(WorkoutMapper.inDevice(deviceKcal: 480, dayActiveKcal: 0), false, "zero day active energy")
    expectEqual(WorkoutMapper.inDevice(deviceKcal: nil, dayActiveKcal: 412), false, "no workout energy")
    expectEqual(WorkoutMapper.inDevice(deviceKcal: 0, dayActiveKcal: 412), false, "zero workout energy")
}

// MARK: - DayAggregator + ledger
section("DayAggregator")
do {
    expectApprox(DayAggregator.normalize(8532.4, field: .steps), 8532, "steps rounded to integer")
    expectApprox(DayAggregator.normalize(8532.5, field: .steps), 8533, "steps half away from zero")
    expectApprox(DayAggregator.normalize(412.34, field: .active_kcal), 412.3, "energy 0.1")
    expectApprox(DayAggregator.normalize(6.123, field: .distance_km), 6.12, "distance 0.01")
    expectApprox(DayAggregator.normalize(7.256, field: .sleep_hours), 7.26, "sleep 0.01")
    expectApprox(DayAggregator.normalize(250_000, field: .steps), 200_000, "steps clamped to the server max")
    expectApprox(DayAggregator.normalize(6000, field: .resting_kcal), 5000, "resting clamped")
    expectApprox(DayAggregator.normalize(-3, field: .exercise_min), 0, "negative clamped to 0")
    expectNil(DayAggregator.normalize(.nan, field: .steps), "NaN → nil")
    expectNil(DayAggregator.normalize(nil, field: .steps), "nil stays nil")
    expectApprox(DayAggregator.normalize(0, field: .steps), 0, "a real 0 is kept")

    let readings: [HealthDayField: [String: Double]] = [
        .steps: ["2026-10-01": 8532.4, "2026-10-02": 1200],
        .active_kcal: ["2026-10-01": 412.34],
        .sleep_hours: ["2026-10-02": 7.25],
    ]
    var ledger = SentDaysLedger()
    var sent = SyncDay(date: "2026-10-01")
    sent.steps = 8000; sent.sleep_hours = 7; sent.stand_hours = 10
    ledger.record(sent)
    expectEqual(ledger.fields(on: "2026-10-01"), ["steps", "sleep_hours", "stand_hours"], "ledger records valued fields")

    let days = DayAggregator.makeDays(dates: ["2026-10-02", "2026-09-30", "2026-10-01"], readings: readings, ledger: ledger)
    expectEqual(days.map(\.date), ["2026-10-01", "2026-10-02"], "empty day skipped, ascending order")
    let d1 = days.first { $0.date == "2026-10-01" }
    expectApprox(d1?.steps, 8532, "day 1 steps")
    expectApprox(d1?.active_kcal, 412.3, "day 1 active")
    expectNil(d1?.sleep_hours, "missing field stays nil (never 0)")
    // sleep has data on another date of the run (readable) → cleared; stand hours have none anywhere (permission
    // revoked or still downloading: HealthKit hides read denial) → not cleared.
    expectEqual(d1?.clear, ["sleep_hours"], "sent-before but now missing → clear, only for fields readable in the run")
    let d2 = days.first { $0.date == "2026-10-02" }
    expectNil(d2?.clear, "no ledger entry → no clear")
    expectApprox(d2?.sleep_hours, 7.25, "day 2 sleep")

    // The held-back clear stays in the ledger: recording d1 (sent with steps/active and clear sleep) keeps stand_hours.
    if let d1 { ledger.record(d1) }
    expectEqual(ledger.fields(on: "2026-10-01"), ["steps", "active_kcal", "stand_hours"],
                "record: cleared fields dropped, valued added, held-back clear kept")
    ledger.forget("2026-10-01")
    ledger.record(sent)   // restore for the checks below

    // A field empty on every date of the run (e.g. 全部关闭 in Settings → 健康): nothing is cleared, nothing is sent.
    let revoked = DayAggregator.makeDays(dates: ["2026-10-01", "2026-10-02"], readings: [:], ledger: ledger)
    expectEqual(revoked.count, 0, "everything unreadable → no day sent (no clear)")
    var partial = DayAggregator.makeDays(dates: ["2026-10-01"], readings: [.steps: ["2026-10-01": 9000]], ledger: ledger)
    expectNil(partial.first?.clear, "sleep / stand unreadable in the run → no clear")
    if !partial.isEmpty { ledger.record(partial.removeFirst()) }
    expectEqual(ledger.fields(on: "2026-10-01"), ["steps", "sleep_hours", "stand_hours"], "unreadable fields stay in the ledger")

    // A day HealthKit no longer has at all is still sent, with only `clear` (steps are readable on another date).
    var gone = SyncDay(date: "2026-09-29")
    gone.steps = 5000
    ledger.record(gone)
    let onlyClearRun = DayAggregator.makeDays(dates: ["2026-09-29", "2026-09-30"], readings: [.steps: ["2026-09-30": 300]], ledger: ledger)
    let onlyClear = onlyClearRun.filter { $0.date == "2026-09-29" }
    expectEqual(onlyClear.count, 1, "cleared-only day is sent")
    expectEqual(onlyClear.first?.clear, ["steps"], "cleared-only day clear list")
    expectEqual(onlyClear.first?.valuedFields, [], "cleared-only day carries no values")

    // Ledger replacement, removal and pruning
    if let first = onlyClear.first { ledger.record(first) }
    expectEqual(ledger.fields(on: "2026-09-29"), [], "sending a value-less day drops the entry")
    var old = SyncDay(date: "2026-09-10")
    old.steps = 1
    ledger.record(old)
    ledger.prune(today: "2026-10-02")
    expectEqual(ledger.fields(on: "2026-09-10"), [], "older than 14 days pruned")
    expectEqual(ledger.fields(on: "2026-10-01"), ["steps", "sleep_hours", "stand_hours"], "recent entry kept")
    var edge = SyncDay(date: "2026-09-19")
    edge.steps = 1
    ledger.record(edge)
    ledger.prune(today: "2026-10-02")
    expectEqual(ledger.fields(on: "2026-09-19"), ["steps"], "day 14 (today − 13) kept")

    // JSON: nil fields omitted, keys verbatim
    if let obj = encodedObject(d1!, "SyncDay encodes") {
        expectEqual(Set(obj.keys), ["date", "steps", "active_kcal", "clear"], "nil fields are omitted")
    }
    expectEqual(HealthDayField.zh(forKey: "sleep_hours"), "睡眠", "field zh")
    expectEqual(HealthDayField.zh(forKey: "unknown"), "unknown", "unknown key passthrough")
}

// MARK: - Upload plan
section("HealthUploadPlan")
do {
    let days = (0..<200).map { SyncDay(date: LocalDay.addDays("2026-01-01", 199 - $0), steps: 1) }
    func sample(_ i: Int) -> HealthTagged<SyncSample> {
        HealthTagged(key: "body_mass", value: SyncSample(uuid: "S\(i)", type: .body_mass, date: "2026-10-01", time: "08:00", value: 70))
    }
    func workout(_ i: Int) -> HealthTagged<SyncWorkout> {
        HealthTagged(key: "workout", value: SyncWorkout(uuid: "W\(i)", date: "2026-10-01", time: "18:00", activity_key: "run_10kmh",
                                                         description: "户外跑步", duration_min: 30, in_device: false))
    }
    let plan = HealthUploadPlan.make(days: days, samples: (0..<900).map(sample), workouts: (0..<10).map(workout),
                                     deleted: (0..<2500).map { HealthTagged(key: $0 % 2 == 0 ? "workout" : "waist", value: "D\($0)") })
    let b = plan.batches
    expectEqual(b.count, 3 + 2 + 2, "3 day + 2 object + 2 deletion batches")
    expectEqual(b.prefix(3).map(\.days.count), [90, 90, 20], "days chunked by 90")
    expectEqual(b.first?.days.first?.date, "2026-01-01", "days ascending")
    expectEqual(b[3].samples.count, 800, "first object batch full of samples")
    expectEqual(b[4].samples.count, 100, "remaining samples")
    expectEqual(b[4].workouts.count, 10, "workouts share the last sample batch")
    expectEqual(b[5].deleted.count, 2000, "deletions chunked by 2000")
    expectEqual(b[6].deleted.count, 500, "remaining deletions")
    expectEqual(b[3].keys, ["body_mass"], "batch keys")
    expectEqual(b[4].keys, ["body_mass", "workout"], "mixed batch keys")
    expectEqual(plan.batchesPerKey["body_mass"], 2, "body_mass in 2 batches")
    expectEqual(plan.batchesPerKey["workout"], 3, "workout in 3 batches (objects + 2 deletion batches)")
    expectEqual(plan.batchesPerKey["waist"], 2, "waist deletions in 2 batches")
    expectNil(plan.batchesPerKey["body_fat"], "untouched stream has no batches")

    let many = HealthUploadPlan.make(days: [], samples: [], workouts: (0..<600).map(workout), deleted: [])
    expectEqual(many.batches.map(\.workouts.count), [500, 100], "at most 500 workouts per request")
    expectEqual(HealthUploadPlan.make(days: [], samples: [], workouts: [], deleted: []).batches.count, 0, "nothing to send")
}

// MARK: - Wire format (DESIGN §C.2–§C.4, shapes as returned by server/src/services/healthsync.ts)
section("HealthSync wire format")
do {
    let full = """
    {"ok":true,"timezone":"Asia/Shanghai","server_today":"2026-10-03","timezone_mismatch":false,
     "days":{"upserted":30,"unchanged":2,"kept_manual":[{"date":"2026-10-01","fields":["sleep_hours"]}],
             "rejected":[{"date":null,"error":"日期格式不正确"},{"date":"2026-10-09","error":"日期不能晚于今天"}]},
     "samples":{"inserted":12,"updated":0,"unchanged":3,"skipped_tombstoned":1,"rejected":[{"uuid":"8A1E","error":"体重不能大于 350"}]},
     "workouts":{"inserted":3,"updated":1,"unchanged":0,"skipped_tombstoned":0,"rejected":[],
                 "possible_duplicates":[{"uuid":"W1","exercise_id":812,"description":"游泳"}]},
     "deleted":{"body":1,"exercises":0,"not_found":2},
     "invalidated_from":"2026-09-03"}
    """
    if let r = decodeFixture(HealthSyncResponse.self, full, "full sync response decodes") {
        expectEqual(r.days?.kept_manual.first?.fields, ["sleep_hours"], "kept_manual fields")
        expectNil(r.days?.rejected.first?.date, "rejected day with date null")
        expectEqual(r.days?.rejected.last?.date, "2026-10-09", "rejected day with a date")
        expectNil(r.samples?.rejected.first?.date, "rejected sample has no date key")
        expectEqual(r.samples?.rejected.first?.uuid, "8A1E", "rejected sample uuid")
        expectEqual(r.workouts?.possible_duplicates.first?.exercise_id, 812, "possible duplicate id")
        expectEqual(r.deleted?.not_found, 2, "deleted not_found")
        expectEqual(r.invalidated_from, "2026-09-03", "invalidated_from")
    }
    let minimal = #"{"ok":true,"timezone":"Asia/Shanghai","server_today":"2026-10-03","timezone_mismatch":true,"invalidated_from":null}"#
    if let r = decodeFixture(HealthSyncResponse.self, minimal, "sections absent from the request are absent from the response") {
        expectNil(r.days, "no days section")
        expectNil(r.workouts, "no workouts section")
        expectNil(r.invalidated_from, "invalidated_from null")
        expectEqual(r.timezone_mismatch, true, "timezone_mismatch")
    }

    let state = """
    {"timezone":"Asia/Shanghai","server_today":"2026-10-03",
     "devices":[{"device_id":"4F0C","device_name":null,
                 "kinds":{"days":{"last_synced_at":"2026-10-03 01:02:03","min_date":"2026-07-06","max_date":"2026-10-03","cursor":null},
                          "samples":{"last_synced_at":"2026-10-03 01:02:03","min_date":null,"max_date":null,"cursor":null}}}],
     "counts":{"days":90,"body":120,"workouts":80},
     "legacy_sources":{"apple_shortcut_days":12,"apple_export_days":0}}
    """
    if let s = decodeFixture(HealthSyncState.self, state, "sync state decodes") {
        expectEqual(s.devices.first?.kinds["days"]?.max_date, "2026-10-03", "days max_date for this device")
        expectNil(s.devices.first?.device_name, "device_name null")
        expectNil(s.devices.first?.kinds["samples"]?.min_date, "min_date null when the section had no valid items")
        expectEqual(s.legacy_sources.apple_shortcut_days, 12, "legacy Shortcut days")
        expectEqual(s.counts.body, 120, "server counts")
    }
    let empty = #"{"timezone":"Asia/Shanghai","server_today":"2026-10-03","devices":[],"counts":{"days":0,"body":0,"workouts":0},"legacy_sources":{"apple_shortcut_days":0,"apple_export_days":0}}"#
    expectEqual(decodeFixture(HealthSyncState.self, empty, "state without devices decodes")?.devices.count, 0, "no devices")
    let unlink = #"{"ok":true,"deleted":{"body":3,"exercises":2,"days":30}}"#
    expectEqual(decodeFixture(HealthUnlinkResponse.self, unlink, "unlink response decodes")?.deleted.days, 30, "unlink counts")

    // Request: nil sections omitted, overwrite_manual is a real JSON boolean (body §13.3).
    var req = HealthSyncRequest(device_id: "4F0C", device_name: "iPhone · 食迹 iOS", timezone: "Asia/Shanghai", overwrite_manual: false)
    req.days = [SyncDay(date: "2026-10-02", steps: 8532)]
    if let obj = encodedObject(req, "sync request encodes") {
        expectEqual(Set(obj.keys), ["device_id", "device_name", "timezone", "overwrite_manual", "days"], "only present sections are sent")
    }
    let json = expectNoThrow("sync request JSON") { () -> String in
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(req), as: UTF8.self)
    }
    expectEqual(json?.contains(#""overwrite_manual":false"#), true, "boolean, not a string")
    let bp = SyncSample(uuid: "C1", type: .blood_pressure, date: "2026-10-02", time: "08:00", sbp: 118, dbp: 76, bp_treated: true)
    if let obj = encodedObject(bp, "BP sample encodes") {
        expectEqual(Set(obj.keys), ["uuid", "type", "date", "time", "sbp", "dbp", "bp_treated"], "BP sample keys")
        expectEqual(obj["type"] as? String, "blood_pressure", "sample type raw value")
    }
    if let obj = encodedObject(HealthUnlinkRequest(device_id: "4F0C", delete_data: true), "unlink request encodes") {
        expectEqual(obj["delete_data"] as? Bool, true, "delete_data")
    }
}

// MARK: - Text helpers and persistence
section("HealthSyncText")
do {
    let t = Date(timeIntervalSince1970: 1_790_935_500) // 2026-10-02T10:05:00Z
    expectEqual(HealthSyncText.isoTimestamp(t, in: shanghai), "2026-10-02T18:05:00+08:00", "ISO with +08:00")
    expectEqual(HealthSyncText.isoTimestamp(t, in: utc), "2026-10-02T10:05:00+00:00", "ISO in UTC")
    expectEqual(HealthSyncText.isoTimestamp(t, in: TimeZone(identifier: "America/New_York")!), "2026-10-02T06:05:00-04:00", "ISO negative offset")
    expectEqual(HealthSyncText.isoTimestamp(t, in: TimeZone(identifier: "Asia/Kolkata")!), "2026-10-02T15:35:00+05:30", "ISO half-hour offset")

    let now = at("2026-10-03 09:00")
    expectEqual(HealthSyncText.lastSyncLabel(at("2026-10-03 08:01"), now: now, in: shanghai), "今天 08:01", "today label")
    expectEqual(HealthSyncText.lastSyncLabel(at("2026-10-02 22:30"), now: now, in: shanghai), "昨天 22:30", "yesterday label")
    expectEqual(HealthSyncText.lastSyncLabel(at("2026-09-28 07:05"), now: now, in: shanghai), "9月28日 07:05", "same year label")
    expectEqual(HealthSyncText.lastSyncLabel(at("2025-12-31 23:10"), now: now, in: shanghai), "2025年12月31日 23:10", "other year label")

    expectEqual(HealthSyncText.summary(days: 30, body: 12, workouts: 3, deleted: 0), "同步了 30 天活动、12 条身体数据、3 次运动", "summary")
    expectEqual(HealthSyncText.summary(days: 2, body: 0, workouts: 0, deleted: 1), "同步了 2 天活动、0 条身体数据、0 次运动，删除 1 条", "summary with deletions")
    expectEqual(HealthSyncText.fieldList(["sleep_hours", "steps"]), "睡眠、步数", "kept-manual field list")
    expectEqual(HealthSyncText.monthDay("2026-10-01"), "10月1日", "month day")
    expectEqual(HealthSyncText.truncate("  Withings Body+  ", max: 8), "Withings", "truncate trims and cuts")
    expectNil(HealthSyncText.truncate("   ", max: 8), "blank → nil")
    expectEqual(HealthSyncText.timeZoneWarning("Asia/Shanghai"), "当前设备时区与档案时区不同，按档案时区 Asia/Shanghai 统计每天的数据", "tz warning")
    expectEqual(HealthSyncText.timeZonesDiffer(shanghai, TimeZone(identifier: "Asia/Hong_Kong")!), false, "same offset is not a mismatch")
    expectEqual(HealthSyncText.timeZonesDiffer(shanghai, utc), true, "different offsets")

    // Daily statistics buckets (device calendar) stay on profile midnights only while the zone offset gap is constant.
    let london = TimeZone(identifier: "Europe/London")!
    expectEqual(HealthSyncText.zonesStayAligned(start: "2026-10-01", end: "2026-10-07", timeZone: shanghai, device: shanghai), true,
                "same zone → aligned")
    expectEqual(HealthSyncText.zonesStayAligned(start: "2026-10-01", end: "2026-10-07", timeZone: london, device: shanghai), true,
                "London (BST) on a Shanghai phone, no DST change in range → aligned")
    expectEqual(HealthSyncText.zonesStayAligned(start: "2026-10-20", end: "2026-10-27", timeZone: london, device: shanghai), false,
                "UK DST ends 2026-10-25 → hourly fallback")
    expectEqual(HealthSyncText.zonesStayAligned(start: "2026-10-20", end: "2026-10-27", timeZone: london, device: london), true,
                "DST in the profile zone only matters when the device zone differs")
    expectEqual(HealthSyncText.zonesStayAligned(start: "2026-10-24", end: "2026-10-24", timeZone: london, device: shanghai), true,
                "the day before the change (02:00 on the 25th) is unaffected")
    expectEqual(HealthSyncText.zonesStayAligned(start: "2026-10-25", end: "2026-10-25", timeZone: london, device: shanghai), false,
                "the 25-hour day itself is not (its end, the next midnight, has the new offset)")

    var snap = HealthSyncSnapshot()
    snap.lastSyncAt = t
    snap.keptManual = [HealthKeptManualDay(date: "2026-10-01", fields: ["sleep_hours"])]
    snap.duplicates = [HealthDuplicate(uuid: "W1", exercise_id: 812, manualDescription: "游泳", date: "2026-10-01", workoutDescription: "泳池游泳", durationMin: 45)]
    snap.serverCounts = HealthServerCounts(days: 90, body: 12, workouts: 3)
    let restored = expectNoThrow("snapshot round trip") {
        try JSONDecoder().decode(HealthSyncSnapshot.self, from: JSONEncoder().encode(snap))
    }
    expectEqual(restored, snap, "snapshot survives encoding")
    expectEqual(HealthSyncSettings.backfillOptions, [30, 90, 365], "backfill options")
}

summary()
