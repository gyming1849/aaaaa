import Foundation
import Observation

// MARK: - Body screen state (web1 §7.1; body §3)
//
// Loads, exactly like the web page:
// - `GET /body?start={today−365}`: weight history (once; again after every body mutation).
// - `GET /activity?start={date−30}&end={date}`: the day row and its workouts (again on every date change).
// - `GET /trends?start={today−89}&end={today}`: 90-day weight chart and 30-day steps chart (whenever `body` reloads).
// - `GET /labs`: lab results.
// A change of `app.dataVersion` made elsewhere (Today, the recognizer sheet, HealthKit sync) reloads everything.
// Mutations made here reload only what they touched and then call `app.noteDataChanged()` for the other screens.

/// The 记录体重 form (web `w` state). Empty fields are nil and sent as null.
struct BodyWeightForm: Equatable, Sendable {
    var weight_kg: Double?
    var body_fat_pct: Double?
    var waist_cm: Double?
    var sbp: Double?
    var dbp: Double?
    var bp_treated = false
    var time = "22:00"

    /// `保存` is enabled when weight, body fat, waist or systolic BP is filled (the server's `请至少填写一项` rule).
    var canSave: Bool { weight_kg != nil || body_fat_pct != nil || waist_cm != nil || sbp != nil }

    /// After a save the five values are cleared; time and the medication flag are kept.
    mutating func clearValues() {
        weight_kg = nil; body_fat_pct = nil; waist_cm = nil; sbp = nil; dbp = nil
    }
}

enum BodyLabUnit: String, Hashable, Sendable { case mmol, mgdl }

/// The 体检化验指标 form (web `Labs` state). Values are typed in the selected unit and converted on save.
struct BodyLabForm: Equatable, Sendable {
    var date = ""
    var unit: BodyLabUnit = .mgdl
    var total_chol: Double?
    var hdl: Double?
    var ldl: Double?
    var fasting_glucose: Double?
    var hba1c: Double?
    var lipid_treated = false
    var diabetes = false

    /// mmol/L → mg/dL (body §3.5): cholesterol × 38.67, glucose × 18, rounded to an integer. HbA1c is always %.
    static let cholesterolFactor = 38.67
    static let glucoseFactor = 18.0

    var unitLabel: String { unit == .mmol ? "mmol/L" : "mg/dL" }

    func converted(_ v: Double?, factor: Double) -> Double? {
        guard let v, v.isFinite else { return nil }
        return unit == .mmol ? (v * factor).rounded() : v
    }

    func input() -> LabInput {
        LabInput(date: date,
                 total_chol: converted(total_chol, factor: Self.cholesterolFactor),
                 hdl: converted(hdl, factor: Self.cholesterolFactor),
                 ldl: converted(ldl, factor: Self.cholesterolFactor),
                 non_hdl: nil,
                 fasting_glucose: converted(fasting_glucose, factor: Self.glucoseFactor),
                 hba1c: hba1c,
                 lipid_treated: lipid_treated, diabetes: diabetes, note: nil)
    }

    /// After a save the five values are cleared; unit, date and the two flags are kept.
    mutating func clearValues() {
        total_chol = nil; hdl = nil; ldl = nil; fasting_glucose = nil; hba1c = nil
    }
}

/// The six fields of the 步数与活动能量 form, in web order. `distance_km` is not editable here but is re-sent as stored.
enum BodyActivityField: String, CaseIterable, Identifiable, Sendable {
    case steps, active_kcal, resting_kcal, exercise_min, sleep_hours, stand_hours
    var id: String { rawValue }

    var label: String {
        switch self {
        case .steps: "步数"
        case .active_kcal: "活动能量"
        case .resting_kcal: "静息能量（可选）"
        case .exercise_min: "锻炼分钟（可选）"
        case .sleep_hours: "睡眠（小时）"
        case .stand_hours: "站立（小时，可选）"
        }
    }

    var unit: String? {
        switch self {
        case .active_kcal, .resting_kcal: "kcal"
        default: nil
        }
    }

    var keyPath: WritableKeyPath<ActivityValues, Double?> {
        switch self {
        case .steps: \.steps
        case .active_kcal: \.active_kcal
        case .resting_kcal: \.resting_kcal
        case .exercise_min: \.exercise_min
        case .sleep_hours: \.sleep_hours
        case .stand_hours: \.stand_hours
        }
    }
}

/// Task identity of the screen loader: the selected date, the global data version and the server "today"
/// (a rollover moves the `today−365` / `today−89` windows).
struct BodyLoadKey: Hashable, Sendable {
    let date: String
    let version: Int
    let today: String
}

@MainActor @Observable final class BodyModel {
    /// Selected day (`YYYY-MM-DD`, ≤ today). Empty until the screen first appears.
    var date = ""

    // Loaded data
    private(set) var bodyRows: [BodyMetric] = []
    private(set) var activityList: ActivityList?
    /// `date` of the activity window currently held in `activityList` (the window is `end−30 … end`).
    private(set) var activityWindowEnd: String?
    private(set) var trendDays: [TrendDay] = []
    private(set) var labs: [LabResult] = []
    private(set) var bodyLoaded = false
    private(set) var trendLoaded = false
    private(set) var labsLoaded = false
    private(set) var loadError: String?
    private(set) var isLoading = false

    // 记录体重
    var weightForm = BodyWeightForm()
    private(set) var isSavingWeight = false

    // 步数与活动能量: local edits per field (`.some(nil)` = the user cleared the field). Reset on date change.
    var activityEdits: [BodyActivityField: Double?] = [:]
    private(set) var isSavingActivity = false

    // 记录运动 → 手动选择运动类型
    var manualActivityKey = "walk_brisk"
    var manualMinutes: Double? = 30
    private(set) var isAddingExercise = false
    /// Optimistic `in_device` values while a PATCH is in flight.
    private(set) var pendingInDevice: [Int: Bool] = [:]

    // 体检化验指标
    var labForm = BodyLabForm()
    private(set) var isSavingLab = false

    @ObservationIgnored private var handledVersion: Int?
    @ObservationIgnored private var handledToday: String?
    @ObservationIgnored private var needsBody = true
    @ObservationIgnored private var needsTrend = true
    @ObservationIgnored private var needsLabs = true
    /// Per-resource request generations: a response is applied only when no newer load or local edit happened since it
    /// started (overlapping `.task` / pull-to-refresh / mutation reloads must not bring back a deleted row).
    @ObservationIgnored private var bodyGen = 0
    @ObservationIgnored private var activityGen = 0
    @ObservationIgnored private var trendGen = 0
    @ObservationIgnored private var labsGen = 0
    /// `isLoading` stays true until the last of overlapping `load` calls ends.
    @ObservationIgnored private var inFlightLoads = 0

    init() {}

    // MARK: Derived

    /// The stored `activity_days` row of `date` (nil = 未记录).
    var day: ActivityDay? { activityList?.days.first { $0.date == date } }

    /// True once the activity window for the selected date has loaded (the form then shows real stored values).
    var activityReady: Bool { activityWindowEnd == date && !date.isEmpty }

    /// Workouts of the selected date, newest first (server order).
    var exercisesOnDate: [Exercise] { activityList?.exercises.filter { $0.date == date } ?? [] }

    /// History list: the newest 30 body rows.
    var recentBodyRows: ArraySlice<BodyMetric> { bodyRows.prefix(30) }

    /// Form value of an activity field: the local edit if any, else the stored value.
    func activityValue(_ field: BodyActivityField) -> Double? {
        if let edit = activityEdits[field] { return edit }
        return ActivityValues(day)[keyPath: field.keyPath]
    }

    func setActivityValue(_ field: BodyActivityField, _ value: Double?) {
        if value == ActivityValues(day)[keyPath: field.keyPath], activityEdits[field] == nil { return }
        activityEdits.updateValue(value, forKey: field)
    }

    func inDevice(_ e: Exercise) -> Bool { pendingInDevice[e.id] ?? e.inDevice }

    // MARK: Loading

    /// Called on first appearance (and whenever `date` is still empty).
    func prepare(today: String) {
        if date.isEmpty { date = today }
        if labForm.date.isEmpty { labForm.date = date }
    }

    /// The local edits belong to one date (web quirk fixed: they are reset when the date changes).
    func dateDidChange() {
        activityEdits = [:]
        pendingInDevice = [:]
    }

    /// `.task(id: BodyLoadKey)`: loads what is missing or stale for the current date and data version.
    func refresh(app: AppState) async {
        prepare(today: app.today)
        let today = app.today
        if let previous = handledToday, previous != today {
            // The day rolled over while the screen was alive: the 365/90-day windows end at the new today.
            needsBody = true
            needsTrend = true
            // Still showing the old "today" → follow it to the new one (an explicitly picked past date stays).
            if date == previous { date = today }
        }
        handledToday = today
        if handledVersion != app.dataVersion {
            if handledVersion != nil { needsBody = true; needsTrend = true; needsLabs = true; activityWindowEnd = nil }
            handledVersion = app.dataVersion
        }
        await load(app: app, body: needsBody, activity: activityWindowEnd != date, trend: needsTrend, labs: needsLabs)
    }

    /// Pull to refresh / 重试: everything again.
    func reloadAll(app: AppState) async {
        prepare(today: app.today)
        handledVersion = app.dataVersion
        handledToday = app.today
        await load(app: app, body: true, activity: true, trend: true, labs: true)
    }

    private func load(app: AppState, body: Bool, activity: Bool, trend: Bool, labs: Bool) async {
        guard body || activity || trend || labs else { return }
        if app.meta == nil { Task { await app.ensureMeta() } }
        loadError = nil
        inFlightLoads += 1
        isLoading = true
        defer {
            inFlightLoads -= 1
            if inFlightLoads == 0 { isLoading = false }
        }
        async let b: Void = body ? loadBody(app: app) : ()
        async let a: Void = activity ? loadActivity(app: app) : ()
        async let t: Void = trend ? loadTrend(app: app) : ()
        async let l: Void = labs ? loadLabs(app: app) : ()
        _ = await (b, a, t, l)
    }

    private func loadBody(app: AppState) async {
        bodyGen += 1
        let gen = bodyGen
        do {
            let rows = try await app.api.bodyMetrics(start: LocalDay.addDays(app.today, -365), end: nil)
            guard gen == bodyGen else { return }
            bodyRows = rows
            bodyLoaded = true
            needsBody = false
        } catch {
            if gen == bodyGen { record(error) }
        }
    }

    private func loadActivity(app: AppState) async {
        let d = date
        guard !d.isEmpty else { return }
        activityGen += 1
        let gen = activityGen
        do {
            let list = try await app.api.activity(start: LocalDay.addDays(d, -30), end: d)
            guard d == date, gen == activityGen else { return }
            activityList = list
            activityWindowEnd = d
        } catch {
            if d == date, gen == activityGen { record(error) }
        }
    }

    private func loadTrend(app: AppState) async {
        trendGen += 1
        let gen = trendGen
        do {
            let today = app.today
            let res = try await app.api.trends(start: LocalDay.addDays(today, -89), end: today, user: nil)
            guard gen == trendGen else { return }
            trendDays = res.days
            trendLoaded = true
            needsTrend = false
        } catch {
            if gen == trendGen { record(error) }
        }
    }

    private func loadLabs(app: AppState) async {
        labsGen += 1
        let gen = labsGen
        do {
            let rows = try await app.api.labs()
            guard gen == labsGen else { return }
            labs = rows
            labsLoaded = true
            needsLabs = false
        } catch {
            if gen == labsGen { record(error) }
        }
    }

    private func record(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        loadError = APIError.from(error).message
    }

    /// After a mutation made on this screen: tell the other screens, without reloading this one twice.
    private func didMutate(app: AppState) {
        app.noteDataChanged()
        handledVersion = app.dataVersion
    }

    // MARK: 记录体重

    func saveWeight(app: AppState) async {
        let f = weightForm
        guard f.canSave, !isSavingWeight, !date.isEmpty else { return }
        // LE8 only uses readings with both values (body §3.2: the client should require both).
        if (f.sbp == nil) != (f.dbp == nil) {
            app.toasts.error("请同时填写收缩压和舒张压")
            return
        }
        isSavingWeight = true
        defer { isSavingWeight = false }
        do {
            _ = try await app.api.addBodyMetric(BodyInput(date: date, time: f.time, weight_kg: f.weight_kg, body_fat_pct: f.body_fat_pct,
                                                          waist_cm: f.waist_cm, sbp: f.sbp, dbp: f.dbp, bp_treated: f.bp_treated, note: nil))
            app.toasts.show("已记录")
            weightForm.clearValues()
            didMutate(app: app)
            async let b: Void = loadBody(app: app)
            async let t: Void = loadTrend(app: app)
            _ = await (b, t)
        } catch {
            app.toasts.error(error)
        }
    }

    /// Swipe to delete (no confirmation, like the web).
    func deleteBodyRow(_ row: BodyMetric, app: AppState) async {
        bodyGen += 1        // a reload started before this edit must not bring the row back
        trendGen += 1
        bodyRows.removeAll { $0.id == row.id }
        do {
            try await app.api.deleteBodyMetric(id: row.id)
            didMutate(app: app)
        } catch {
            app.toasts.error(error)
        }
        async let b: Void = loadBody(app: app)
        async let t: Void = loadTrend(app: app)
        _ = await (b, t)
    }

    // MARK: 步数与活动能量

    /// `PUT /activity/{date}` with all 7 fields: the form values, plus the stored `distance_km`. Empty fields clear.
    func saveActivity(app: AppState) async {
        guard activityReady, !isSavingActivity else { return }
        var values = ActivityValues(day)
        for field in BodyActivityField.allCases {
            if let edit = activityEdits[field] { values[keyPath: field.keyPath] = edit }
        }
        isSavingActivity = true
        defer { isSavingActivity = false }
        do {
            try await app.api.putActivity(date: date, values)
            app.toasts.show("已保存")
            activityEdits = [:]
            didMutate(app: app)
            async let a: Void = loadActivity(app: app)
            async let t: Void = loadTrend(app: app)
            _ = await (a, t)
        } catch {
            app.toasts.error(error)
        }
    }

    // MARK: 记录运动

    /// `POST /exercises {date, activity_key, duration_min, in_device}`; `in_device` is true when the day already
    /// has device active energy (web `!!day.active_kcal`; DESIGN §E.2 WP4: `day.active_kcal > 0`).
    func addManualExercise(app: AppState) async {
        guard !isAddingExercise, !date.isEmpty else { return }
        guard let minutes = manualMinutes else {
            app.toasts.error("时长不能为空")
            return
        }
        let inDevice = (day?.active_kcal ?? 0) > 0
        isAddingExercise = true
        defer { isAddingExercise = false }
        do {
            _ = try await app.api.addExercise(ExerciseInput(date: date, time: nil, activity_key: manualActivityKey, met: nil,
                                                            duration_min: minutes, distance_km: nil, description: nil,
                                                            in_device: inDevice, source: nil))
            didMutate(app: app)
            await loadActivity(app: app)
            app.toasts.show("已记录")
        } catch {
            app.toasts.error(error)
        }
    }

    func setInDevice(_ exercise: Exercise, _ on: Bool, app: AppState) async {
        activityGen += 1
        pendingInDevice[exercise.id] = on
        do {
            try await app.api.setExerciseInDevice(id: exercise.id, inDevice: on)
            didMutate(app: app)
            await loadActivity(app: app)
        } catch {
            app.toasts.error(error)
        }
        pendingInDevice[exercise.id] = nil
    }

    /// Trash button: deletes right away (no confirmation, like the web); the row disappears at once and the reload
    /// brings it back if the request failed.
    func deleteExercise(_ exercise: Exercise, app: AppState) async {
        activityGen += 1
        if let list = activityList {
            activityList = ActivityList(days: list.days, exercises: list.exercises.filter { $0.id != exercise.id })
        }
        do {
            try await app.api.deleteExercise(id: exercise.id)
            didMutate(app: app)
        } catch {
            app.toasts.error(error)
        }
        await loadActivity(app: app)
    }

    // MARK: 体检化验指标

    func saveLab(app: AppState) async {
        guard !isSavingLab else { return }
        if labForm.date.isEmpty { labForm.date = date }
        isSavingLab = true
        defer { isSavingLab = false }
        do {
            _ = try await app.api.addLab(labForm.input())
            app.toasts.show("已保存化验结果")
            labForm.clearValues()
            didMutate(app: app)
            await loadLabs(app: app)
        } catch {
            app.toasts.error(error)
        }
    }

    /// Trash button: deletes right away (no confirmation, web1 §7.2 Row 3); the reload restores the row on failure.
    func deleteLab(_ lab: LabResult, app: AppState) async {
        labsGen += 1
        labs.removeAll { $0.id == lab.id }
        do {
            try await app.api.deleteLab(id: lab.id)
            didMutate(app: app)
        } catch {
            app.toasts.error(error)
        }
        await loadLabs(app: app)
    }
}
