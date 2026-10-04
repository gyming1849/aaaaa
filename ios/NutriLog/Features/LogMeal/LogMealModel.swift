import Foundation
import Observation

// MARK: - Log Meal state and flows (web1 §5.1, §5.5; meals §2.4–§2.10, §3, §4)

enum LogMealPhase: Sendable, Equatable { case input, analyzing, review }

/// Inputs of the live merge preview: `.task(id:)` restarts the 400 ms debounce whenever one of them changes
/// (items, date, time, meal type, edit id; web1 §5.5).
struct LogMealPreviewKey: Equatable {
    let phase: LogMealPhase
    let date: String
    let time: String
    let mealType: String
    let editMealId: Int?
    let items: [DraftItem]
}

@MainActor @Observable final class LogMealModel {
    // MARK: Inputs (web1 §5.1)

    let request: LogMealRequest
    /// Edit mode (`编辑这一餐`) when set.
    let editMealId: Int?
    var date: String
    var time: String
    /// `guessMealType(now)` once; not re-guessed when the time changes.
    var mealType: String
    var text = ""
    /// Uploaded photo ids (≤ 6). Not loaded in edit mode: `PUT /meals/{id}` ignores photos.
    let photos: PhotoUploadModel

    // MARK: Flow

    private(set) var phase: LogMealPhase = .input
    /// The last AI result without its items: summary, assumptions, questions, sources, provider, model.
    private(set) var draft: MealDraft?
    private(set) var items: [DraftItem] = []
    private(set) var preview: DayPreview?
    private(set) var isSaving = false
    /// Last polled job status (`排队中…` while `.queued`).
    private(set) var jobPhase: JobPhase?
    private(set) var analysisStartedAt = Date()
    /// A `meal` job started earlier (sheet closed or app killed) that is younger than 30 minutes.
    private(set) var resumableJob: PendingJob?
    /// Identity of the running analysis; the screen runs it with `.task(id:)` so it stops when the sheet goes away.
    private(set) var analysisRunId: UUID?

    // Edit mode loading (`GET /day/{date}`)
    private(set) var isLoadingEdit = false
    private(set) var editError: String?
    private var editSnapshot: LogMealSnapshot?

    // Quick foods (`GET /foods?scope=all`, first 12)
    private(set) var quickFoods: [Food] = []

    @ObservationIgnored let app: AppState
    @ObservationIgnored private var currentRun: LogMealAnalysisRun?
    @ObservationIgnored private var didSave = false

    static let pendingKind = "meal"
    /// Offer to resume a pending meal job younger than this (DESIGN §E.2 WP3).
    static let resumeWindow: TimeInterval = 30 * 60

    init(app: AppState, request: LogMealRequest) {
        self.app = app
        self.request = request
        self.editMealId = request.editMealId
        let today = app.today
        if let d = request.date, LocalDay.isValid(d), LocalDay.diffDays(today, d) <= 0 {
            date = d
        } else {
            date = today
        }
        let now = LocalDay.nowHHMM(in: app.profileTimeZone)
        time = now
        mealType = Vocab.guessMealType(time: now)
        photos = PhotoUploadModel(api: app.api, limit: APIClient.maxPhotos, onError: { [weak toasts = app.toasts] message in
            toasts?.error(message)
        })
        if request.editMealId == nil {
            resumableJob = Self.resumableNewMealJob()
        }
    }

    /// Context key marking a job started while editing a saved meal. Such a job is never offered by a new-meal sheet:
    /// resuming it there would save a second copy of that meal instead of editing it.
    static let editContextKey = "edit_meal_id"

    /// The newest pending `meal` job under 30 minutes old that was started for a new meal.
    private static func resumableNewMealJob() -> PendingJob? {
        let now = Date()
        return PendingJobStore.all(kind: pendingKind).first { job in
            job.context[editContextKey] == nil && now.timeIntervalSince(job.createdAt) < resumeWindow
        }
    }

    // MARK: Derived

    var isEdit: Bool { editMealId != nil }
    /// Edit mode: the meal has been loaded into the form (always true for a new meal).
    var isEditLoaded: Bool { editMealId == nil || editSnapshot != nil }
    var today: String { app.today }
    var title: String { isEdit ? "编辑这一餐" : "记一餐" }

    /// `AI 分析`, or `重新分析文字描述` once there are items under review.
    var analyzeTitle: String { !items.isEmpty && phase == .review ? "重新分析文字描述" : "AI 分析" }

    /// `确认修改` in edit mode, else `确认合并到 今天` / `确认合并到 {date}`.
    var saveTitle: String { isEdit ? "确认修改" : "确认合并到 \(date == app.today ? "今天" : date)" }

    /// Note next to the analyse button (web1 §5.2, meals §2.3).
    var aiNote: String {
        guard let ai = app.me?.ai, !ai.isMock else { return "当前为离线估算模式（未配置 AI）" }
        return "由 \(ai.model) 分析\(ai.provider == "cli" ? "（claude -p）" : "")，包装食品会自动联网查询"
    }

    /// Sum of `nutrients` over all items (the `合计` line, meals §4.4).
    var totals: Vec { ItemMath.totals(items) }

    var previewKey: LogMealPreviewKey {
        LogMealPreviewKey(phase: phase, date: date, time: time, mealType: mealType, editMealId: editMealId, items: items)
    }

    var canAnalyze: Bool { phase != .analyzing && !photos.isUploading }

    /// The 取消 button asks before throwing work away.
    var hasUnsavedChanges: Bool {
        if didSave { return false }
        if isEdit {
            guard let snapshot = editSnapshot else { return false }
            return snapshot != currentSnapshot
        }
        return !items.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.photos.isEmpty
    }

    private var currentSnapshot: LogMealSnapshot {
        LogMealSnapshot(date: date, time: time, mealType: mealType, text: text, items: items)
    }

    // MARK: Loading

    /// Edit mode: `GET /day/{date ?? today}`, find the meal, fill the form and go straight to review (web1 §5.1).
    func loadEditIfNeeded() async {
        guard let editMealId, editSnapshot == nil, !isLoadingEdit else { return }
        isLoadingEdit = true
        defer { isLoadingEdit = false }
        do {
            let day = try await app.api.day(request.date ?? app.today, user: nil)
            guard let meal = day.meals.first(where: { $0.id == editMealId }) else {
                editError = "餐食不存在"
                return
            }
            editError = nil
            date = meal.date
            time = meal.time
            mealType = meal.meal_type
            text = meal.description
            items = meal.items.map(ItemMath.toDraft)
            phase = .review
            editSnapshot = currentSnapshot
        } catch is CancellationError {
            return
        } catch {
            editError = APIError.from(error).message
        }
    }

    /// The item editor reads nutrient / food-group labels and hazard names from `meta`. Fetch it only when the bootstrap
    /// could not (no request when it is already loaded).
    func ensureMeta() async {
        guard app.meta == nil else { return }
        await app.ensureMeta()
    }

    /// `GET /foods?scope=all`, first 12 (web1 §5.2 QuickFoods). Failures just hide the card, like the web.
    func loadQuickFoods() async {
        guard !isEdit, quickFoods.isEmpty else { return }
        do {
            let foods = try await app.api.foods(query: nil, scope: .all)
            quickFoods = Array(app.blocked.visible(foods).prefix(12))
        } catch {
            AppLog.app.notice("quick foods unavailable: \(APIError.from(error).message, privacy: .public)")
        }
    }

    // MARK: AI analysis (web1 §5.5 `analyze`)

    /// Starts `POST /ai/meal`. `extra` is the follow-up answer: the request text becomes `{text}\n补充：{extra}` and the
    /// result replaces every item; a plain (re-)analysis keeps the library items already in the list.
    func analyze(extra: String = "") {
        guard canAnalyze else { return }
        let fullText = extra.isEmpty ? text : "\(text)\n补充：\(extra)"
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, photos.ids.isEmpty {
            app.toasts.error("请描述吃了什么，或上传照片")
            return
        }
        resumableJob = nil
        let req = MealAIRequest(text: fullText, date: date, time: time, meal_type: mealType, photos: photos.ids)
        beginRun(request: req, jobId: nil, extra: extra, fullText: fullText, startedAt: Date())
    }

    /// `继续等待上次的 AI 分析`: restores the saved context and polls the same job id again.
    func resumePendingJob() {
        guard let job = resumableJob, phase != .analyzing else { return }
        resumableJob = nil
        let c = job.context
        if let d = c["date"], LocalDay.isValid(d) { date = d }
        if let t = c["time"], LocalDay.isValidTime(t) { time = t }
        if let m = c["meal_type"], !m.isEmpty { mealType = m }
        if let t = c["text"] { text = t }
        let ids = (c["photos"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if !ids.isEmpty { photos.restore(ids: ids) }
        beginRun(request: nil, jobId: job.id, extra: c["extra"] ?? "", fullText: text, startedAt: job.createdAt)
    }

    /// Forget the pending job (its result is discarded).
    func dismissPendingJob() {
        if let job = resumableJob { PendingJobStore.remove(id: job.id) }
        resumableJob = nil
    }

    /// Client-side cancel: stops polling and discards the result (the server job keeps running). Toast `已取消`.
    /// The UI returns to review / input at once; the cancelled task finds its run gone and exits quietly.
    func cancelAnalysis() {
        guard phase == .analyzing, let run = currentRun else { return }
        if let jobId = run.jobId { PendingJobStore.remove(id: jobId) }
        currentRun = nil
        analysisRunId = nil
        jobPhase = nil
        phase = items.isEmpty ? .input : .review
        app.toasts.show(APIError.cancelledMessage)
    }

    /// Runs the analysis scheduled by `analyze` / `resumePendingJob`. The screen calls it from `.task(id: analysisRunId)`
    /// with the id captured for that task, so a task only ever works on its own run; closing the sheet cancels polling
    /// while the pending job stays saved for a later resume. A restarted task for the same run continues where it was
    /// (polling the job it already started).
    func performAnalysisRun(_ runId: UUID?) async {
        guard let runId, let run = currentRun, run.id == runId, phase == .analyzing else { return }
        var jobId = run.jobId
        if jobId == nil, let req = run.request {
            do {
                let created = try await app.api.startMealAI(req)
                jobId = created
                guard currentRun?.id == runId else { return }
                currentRun?.jobId = created
                for old in PendingJobStore.all(kind: Self.pendingKind) where old.id != created { PendingJobStore.remove(id: old.id) }
                var context = ["date": req.date, "time": req.time, "meal_type": req.meal_type, "text": req.text,
                               "photos": req.photos.joined(separator: ",")]
                if !run.extra.isEmpty { context["extra"] = run.extra }
                if let editMealId { context[Self.editContextKey] = String(editMealId) }
                PendingJobStore.save(PendingJob(id: created, kind: Self.pendingKind, createdAt: analysisStartedAt, context: context))
            } catch {
                finishAnalysis(with: error, runId: runId, jobId: nil)
                return
            }
        }
        guard let jobId else { return }
        do {
            let result = try await JobPoller(api: app.api).wait(jobId: jobId, as: MealDraft.self) { [weak self] p in
                guard self?.currentRun?.id == runId else { return }
                self?.jobPhase = p
            }
            guard currentRun?.id == runId else { return }
            PendingJobStore.remove(id: jobId)
            guard let result else { throw APIError.jobFailed(message: APIError.jobFailedMessage) }
            apply(result, extra: run.extra, fullText: run.fullText)
        } catch {
            finishAnalysis(with: error, runId: runId, jobId: jobId)
        }
    }

    private func beginRun(request: MealAIRequest?, jobId: String?, extra: String, fullText: String, startedAt: Date) {
        let id = UUID()
        currentRun = LogMealAnalysisRun(id: id, request: request, jobId: jobId, extra: extra, fullText: fullText)
        jobPhase = nil
        analysisStartedAt = startedAt
        phase = .analyzing
        analysisRunId = id
    }

    /// Done: `draft` = result minus items; items = kept library items + result items (plain re-analysis) or the result
    /// alone (follow-up). Kept library items whose `food_id` the new result also contains are dropped (no duplicates).
    private func apply(_ result: MealDraft, extra: String, fullText: String) {
        currentRun = nil
        var info = result
        info.items = []
        draft = info
        if extra.isEmpty {
            let fresh = Set(result.items.compactMap(\.food_id))
            let kept = items.filter { item in
                guard let id = item.food_id else { return false }
                return !fresh.contains(id)
            }
            items = kept + result.items
        } else {
            items = result.items
            text = fullText
        }
        jobPhase = nil
        phase = .review
    }

    /// Error: toast, then back to review when there are items, else to input.
    private func finishAnalysis(with error: Error, runId: UUID, jobId: String?) {
        // A run that is no longer current was cancelled with 取消 (already handled) or replaced by a newer one.
        guard currentRun?.id == runId else { return }
        // Task cancellation that did not come from 取消: the sheet went away (keep the pending job for a later resume)
        // or SwiftUI restarted the task (the restarted task picks the run up again).
        if error is CancellationError || Task.isCancelled { return }
        let e = APIError.from(error)
        if case .network = e {
            // Connectivity: the job may still finish on the server; keep it resumable.
        } else if let jobId {
            PendingJobStore.remove(id: jobId)
        }
        app.toasts.error(e.message)
        currentRun = nil
        jobPhase = nil
        phase = items.isEmpty ? .input : .review
    }

    // MARK: Items (ItemEditor callbacks, picker, quick foods)

    func item(id: UUID) -> DraftItem? { items.first { $0.id == id } }

    /// Applies `transform` to the current value of the item (never to a stale copy).
    func updateItem(id: UUID, _ transform: (DraftItem) -> DraftItem) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let updated = transform(items[i])
        if updated != items[i] { items[i] = updated }
    }

    func removeItem(id: UUID) { items.removeAll { $0.id == id } }

    /// Library picker result: append and switch to review (an analysis in progress keeps running; its result is merged
    /// with this item when it lands, since library items are kept).
    func appendItem(_ item: DraftItem) {
        items.append(item)
        if phase != .analyzing { phase = .review }
    }

    /// Quick-food chip result: `items = [result]`, review. A result that lands after an analysis was started (the chip
    /// request was still in flight) is appended instead, so the running analysis keeps its card and state.
    func setQuickItem(_ item: DraftItem) {
        guard phase != .analyzing else {
            appendItem(item)
            return
        }
        items = [item]
        phase = .review
    }

    /// After `POST /foods/from-item`: `saved_food_id` hides the save button (`food_id` stays nil).
    func markSaved(itemId: UUID, foodId: Int) {
        updateItem(id: itemId) { item in
            var copy = item
            copy.saved_food_id = foodId
            return copy
        }
    }

    // MARK: Merge preview (400 ms debounce; errors hide it)

    func refreshPreview() async {
        guard phase == .review, !items.isEmpty else {
            preview = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return
        }
        let req = PreviewRequest(date: date, meal: PreviewMeal(meal_type: mealType, time: time, items: items, replace_meal_id: editMealId))
        do {
            let result = try await app.api.preview(req)
            guard !Task.isCancelled else { return }
            preview = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
        }
    }

    // MARK: Save (web1 §5.5 `saveMeal`)

    /// `POST /meals` (new) or `PUT /meals/{id}` (edit), then `已保存，评分已更新` and Today for that date.
    func save() async {
        guard !isSaving else { return }
        guard !items.isEmpty else {
            app.toasts.error("至少需要一种食物")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let body = MealBody(date: date, time: time, meal_type: mealType, description: text, photos: photos.ids,
                            ai_summary: draft?.summary ?? "", ai_model: draft?.model ?? "", items: items)
        do {
            if let editMealId {
                try await app.api.updateMeal(id: editMealId, body)
            } else {
                _ = try await app.api.createMeal(body)
            }
            didSave = true
            let savedDate = date
            app.toasts.show("已保存，评分已更新")
            app.router.logMeal = nil
            app.noteDataChanged()
            app.router.showToday(date: savedDate)
        } catch {
            app.toasts.error(error)
        }
    }

    /// 取消 / 放弃: closes the sheet.
    func close() { app.router.logMeal = nil }
}

/// The analysis in progress: a new job (`request`, `jobId` filled in once created) or a resumed one (`jobId` only).
private struct LogMealAnalysisRun {
    let id: UUID
    let request: MealAIRequest?
    var jobId: String?
    let extra: String
    let fullText: String
}

/// The editable fields of a loaded meal, to detect unsaved edits.
private struct LogMealSnapshot: Equatable {
    let date: String
    let time: String
    let mealType: String
    let text: String
    let items: [DraftItem]
}
