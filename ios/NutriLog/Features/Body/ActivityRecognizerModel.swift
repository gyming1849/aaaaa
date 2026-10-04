import Foundation
import Observation

// MARK: - ActivityRecognizer state (web1 §6; body §4)
// manual: a draft prefilled from the day's stored activity (body fields empty, no workouts), committed with source "manual".
// ai: text and/or screenshots → `POST /ai/activity` → `JobPoller` → `ActivityDraft`, committed with source "ai".
// Every draft change re-scores the day with `POST /preview` after 350 ms; `POST /activity/commit` merges it.

/// `ACT_FIELDS` (3-column grid on the web): label, unit.
enum ActivityRecognizerActField: String, CaseIterable, Identifiable, Sendable {
    case steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours
    var id: String { rawValue }
    var label: String {
        switch self {
        case .steps: "步数"
        case .active_kcal: "活动能量"
        case .resting_kcal: "静息能量"
        case .distance_km: "步行+跑步距离"
        case .exercise_min: "锻炼分钟"
        case .sleep_hours: "睡眠"
        }
    }
    var unit: String {
        switch self {
        case .steps: "步"
        case .active_kcal, .resting_kcal: "kcal"
        case .distance_km: "km"
        case .exercise_min: "分钟"
        case .sleep_hours: "小时"
        }
    }
    var keyPath: WritableKeyPath<ActivityValues, Double?> {
        switch self {
        case .steps: \.steps
        case .active_kcal: \.active_kcal
        case .resting_kcal: \.resting_kcal
        case .distance_km: \.distance_km
        case .exercise_min: \.exercise_min
        case .sleep_hours: \.sleep_hours
        }
    }
}

/// `BODY_FIELDS` (4-column grid on the web): label, unit.
enum ActivityRecognizerBodyField: String, CaseIterable, Identifiable, Sendable {
    case weight_kg, body_fat_pct, sbp, dbp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .weight_kg: "体重"
        case .body_fat_pct: "体脂率"
        case .sbp: "收缩压"
        case .dbp: "舒张压"
        }
    }
    var unit: String {
        switch self {
        case .weight_kg: "kg"
        case .body_fat_pct: "%"
        case .sbp, .dbp: "mmHg"
        }
    }
    var keyPath: WritableKeyPath<BodyDraft, Double?> {
        switch self {
        case .weight_kg: \.weight_kg
        case .body_fat_pct: \.body_fat_pct
        case .sbp: \.sbp
        case .dbp: \.dbp
        }
    }
}

/// Everything `/preview` depends on; the sheet re-runs its debounced preview task when this changes.
struct ActivityRecognizerPreviewKey: Hashable, Sendable {
    let date: String
    let activity: ActivityValues
    let body: BodyDraft
    let workouts: [WorkoutDraft]
}

@MainActor @Observable final class ActivityRecognizerModel {
    let mode: RecognizerMode
    /// Date the sheet was opened for; `current` is that date's stored activity row.
    let openerDate: String
    let current: ActivityDay?

    /// AI input stage: the date sent with `POST /ai/activity` (header date picker, ≤ today).
    var requestDate: String
    var text = ""
    private(set) var photos: PhotoUploadModel?

    private(set) var isRecognizing = false
    private(set) var elapsed = 0
    private(set) var jobPhase: JobPhase?

    /// nil = AI input stage. manual mode starts with a draft.
    var draft: ActivityDraft?
    private(set) var preview: DayPreview?
    private(set) var isSaving = false

    /// Stored activity row of `draft.date` (to explain that an emptied field is kept by the commit).
    private(set) var stored: ActivityDay?
    private(set) var storedDate: String?

    @ObservationIgnored private var recognizeTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var prefilledDate: String?
    @ObservationIgnored private var didAppear = false

    /// AI jobs younger than this are resumed when the sheet reopens for the same date (e.g. after a relaunch).
    static let resumeWindow: TimeInterval = 30 * 60
    static let pendingKind = "activity"

    init(date: String, current: ActivityDay?, mode: RecognizerMode) {
        self.mode = mode
        self.openerDate = date
        self.current = current
        self.requestDate = date
        self.stored = current
        self.storedDate = date
        if mode == .manual {
            draft = ActivityDraft(date: date, date_from_image: false, activity: Self.prefill(current),
                                  body: BodyDraft(weight_kg: nil, body_fat_pct: nil, sbp: nil, dbp: nil),
                                  workouts: [], notes: "", provider: "", model: "")
            prefilledDate = date
        }
    }

    /// Manual draft values: the six form fields from the stored row (`stand_hours` is not in the form).
    static func prefill(_ day: ActivityDay?) -> ActivityValues {
        ActivityValues(steps: day?.steps, active_kcal: day?.active_kcal, resting_kcal: day?.resting_kcal, distance_km: day?.distance_km,
                       exercise_min: day?.exercise_min, sleep_hours: day?.sleep_hours, stand_hours: nil)
    }

    /// The default workout added by `添加一项`.
    static func newWorkout() -> WorkoutDraft {
        WorkoutDraft(description: "快走", activity_key: "walk_brisk", met: 4.8, duration_min: 30, distance_km: 0, in_device: false)
    }

    /// Client estimate `round(max(0, (met − 1) × weight × min/60))` with the profile weight (web `kcalOf`).
    nonisolated static func kcal(met: Double, durationMin: Double, weightKg: Double) -> Double {
        let v = max(0, (met - 1) * weightKg * (durationMin / 60))
        return v.isFinite ? v.rounded() : 0
    }

    // MARK: Derived

    var effectiveDate: String { draft?.date ?? requestDate }

    var canRecognize: Bool {
        guard !isRecognizing else { return false }
        if photos?.isUploading == true { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(photos?.ids.isEmpty ?? true)
    }

    var previewKey: ActivityRecognizerPreviewKey? {
        draft.map { ActivityRecognizerPreviewKey(date: $0.date, activity: $0.activity, body: $0.body, workouts: $0.workouts) }
    }

    /// True when a field that has a stored value is empty in the draft: the commit keeps (does not clear) that value.
    var keepsStoredValues: Bool {
        guard let draft, storedDate == draft.date, let stored else { return false }
        let saved = ActivityValues(stored)
        return ActivityRecognizerActField.allCases.contains { draft.activity[keyPath: $0.keyPath] == nil && saved[keyPath: $0.keyPath] != nil }
    }

    // MARK: Lifecycle

    /// First appearance: create the photo model, and in `ai` mode resume a pending job for this date.
    func appear(app: AppState) {
        if photos == nil {
            photos = PhotoUploadModel(api: app.api, limit: APIClient.maxPhotos) { [weak app] message in app?.toasts.error(message) }
        }
        guard !didAppear else { return }
        didAppear = true
        if app.meta == nil { Task { await app.ensureMeta() } }
        guard mode == .ai, draft == nil, !isRecognizing,
              let pending = PendingJobStore.latest(kind: Self.pendingKind, maxAge: Self.resumeWindow),
              pending.context["date"] == requestDate else { return }
        text = pending.context["text"] ?? ""
        let ids = (pending.context["photos"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if !ids.isEmpty { photos?.restore(ids: ids) }
        start(app: app, resume: pending)
    }

    /// The sheet went away: stop polling (the server job keeps running) and the timers.
    func stop(app: AppState) {
        if let task = recognizeTask {
            task.cancel()
            recognizeTask = nil
        }
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: Header date

    /// The header date picker edits the request date before recognition and the draft's date afterwards
    /// (an explicitly chosen date replaces the "date read from the screenshot" warning).
    func setDate(_ date: String) {
        if draft != nil {
            guard draft?.date != date else { return }
            draft?.date = date
            draft?.date_from_image = false
        } else {
            requestDate = date
        }
    }

    /// `.task(id: draft?.date)`: the stored row for the draft's date; manual mode re-prefills the form for a new date.
    func loadStored(app: AppState) async {
        guard let d = draft?.date else { return }
        var row: ActivityDay?
        if d == openerDate {
            row = current
        } else {
            do {
                let list = try await app.api.activity(start: d, end: d)
                row = list.days.first { $0.date == d }
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                row = nil
            }
        }
        guard draft?.date == d else { return }
        stored = row
        storedDate = d
        if mode == .manual, prefilledDate != d {
            draft?.activity = Self.prefill(row)
            prefilledDate = d
        }
    }

    // MARK: Draft edits

    func activityValue(_ field: ActivityRecognizerActField) -> Double? { draft?.activity[keyPath: field.keyPath] }
    func setActivityValue(_ field: ActivityRecognizerActField, _ value: Double?) { draft?.activity[keyPath: field.keyPath] = value }
    func bodyValue(_ field: ActivityRecognizerBodyField) -> Double? { draft?.body[keyPath: field.keyPath] }
    func setBodyValue(_ field: ActivityRecognizerBodyField, _ value: Double?) { draft?.body[keyPath: field.keyPath] = value }

    func addWorkout() { draft?.workouts.append(Self.newWorkout()) }

    func removeWorkout(id: UUID) { draft?.workouts.removeAll { $0.id == id } }

    func workout(id: UUID) -> WorkoutDraft? { draft?.workouts.first { $0.id == id } }

    func updateWorkout(_ workout: WorkoutDraft) {
        guard let i = draft?.workouts.firstIndex(where: { $0.id == workout.id }) else { return }
        draft?.workouts[i] = workout
    }

    // MARK: AI recognition

    func recognize(app: AppState) {
        guard canRecognize else { return }
        start(app: app, resume: nil)
    }

    private func start(app: AppState, resume: PendingJob?) {
        recognizeTask?.cancel()
        isRecognizing = true
        jobPhase = nil
        startedAt = resume?.createdAt ?? Date()
        tick()
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
        let text = self.text
        let date = requestDate
        let ids = photos?.ids ?? []
        recognizeTask = Task { [weak self] in
            await self?.run(app: app, resume: resume, text: text, date: date, photoIds: ids)
        }
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = JobProgressView.elapsed(since: startedAt, now: Date())
    }

    private func run(app: AppState, resume: PendingJob?, text: String, date: String, photoIds: [String]) async {
        var jobId = resume?.id
        defer {
            isRecognizing = false
            tickTask?.cancel()
            tickTask = nil
            recognizeTask = nil
        }
        do {
            let id: String
            if let jobId {
                id = jobId
            } else {
                id = try await app.api.startActivityAI(ActivityAIRequest(text: text, date: date, photos: photoIds))
                jobId = id
                // A kept orphan (connectivity error below) must never be resumed in place of this newer result.
                for old in PendingJobStore.all(kind: Self.pendingKind) where old.id != id { PendingJobStore.remove(id: old.id) }
                PendingJobStore.save(PendingJob(id: id, kind: Self.pendingKind, createdAt: startedAt ?? Date(),
                                                context: ["date": date, "text": text, "photos": photoIds.joined(separator: ",")]))
            }
            let result = try await JobPoller(api: app.api).wait(jobId: id, as: ActivityDraft.self) { [weak self] phase in
                self?.jobPhase = phase
            }
            PendingJobStore.remove(id: id)
            guard let result else { throw APIError.jobFailed(message: APIError.jobFailedMessage) }
            guard !Task.isCancelled else { return }
            draft = result
            prefilledDate = result.date
        } catch is CancellationError {
            if let jobId { PendingJobStore.remove(id: jobId) }
            app.toasts.show(APIError.cancelledMessage)
        } catch {
            let e = APIError.from(error)
            // Connectivity: the server job keeps running; keep it so reopening the sheet for this date resumes it.
            if let jobId {
                if case .network = e {} else { PendingJobStore.remove(id: jobId) }
            }
            app.toasts.error(e)
        }
    }

    // MARK: Preview and commit

    /// Debounced 350 ms; any failure (e.g. `时长不能小于 1` while typing) just hides the preview, like the web.
    func refreshPreview(app: AppState) async {
        guard let key = previewKey else {
            preview = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let req = PreviewRequest(date: key.date, meal: nil, activity: key.activity,
                                     body: PreviewBody(weight_kg: key.body.weight_kg, body_fat_pct: key.body.body_fat_pct,
                                                       sbp: key.body.sbp, dbp: key.body.dbp, bp_treated: nil),
                                     workouts: key.workouts)
            let result = try await app.api.preview(req)
            guard previewKey == key else { return }
            preview = result
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            preview = nil
        }
    }

    /// `POST /activity/commit {...draft, source}`. Returns true on success (the caller closes the sheet).
    func commit(app: AppState) async -> Bool {
        guard let d = draft, !isSaving else { return false }
        if d.workouts.contains(where: { !$0.duration_min.isFinite || $0.duration_min < 1 }) {
            app.toasts.error("时长不能小于 1")
            return false
        }
        if d.workouts.contains(where: { !$0.met.isFinite || $0.met < 1 }) {
            app.toasts.error("MET不能小于 1")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let body = CommitBody(weight_kg: d.body.weight_kg, body_fat_pct: d.body.body_fat_pct, sbp: d.body.sbp, dbp: d.body.dbp,
                                  bp_treated: false, time: nil)
            _ = try await app.api.commitActivity(ActivityCommitRequest(date: d.date, source: mode == .manual ? "manual" : "ai",
                                                                       activity: d.activity, body: body, workouts: d.workouts))
            app.toasts.show("已合并到当天记录")
            app.noteDataChanged()
            return true
        } catch {
            app.toasts.error(error)
            return false
        }
    }
}
