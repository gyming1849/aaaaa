import SwiftUI
import Observation
import UIKit

// MARK: - AI 查询营养信息 (web2 §5.9.3; meals §2.5, §1.14, §2.7)

/// Name / brand / note / label photos → `POST /ai/food` → poll the job → `FoodDraft`, which opens the editor prefilled.
/// While the job runs the button shows a spinner and `{elapsed}s`, and a pulsing hint explains the wait.
/// The job state lives in `FoodsLookupModel`, owned by `FoodsScreen`: closing the sheet stops polling (toast `已取消`,
/// see the screen's `onDismiss`), and a job interrupted by the app being closed resumes the next time this sheet opens
/// (within 30 minutes).
struct FoodsLookupSheet: View {
    @Environment(AppState.self) private var app
    @Bindable var lookup: FoodsLookupModel
    @State private var photos: PhotoUploadModel
    @State private var now = Date()
    /// `onAppear` also fires when the photo picker or camera cover closes; only check for a job to resume once.
    @State private var checkedResume = false
    @State private var consent: AIConsentRequest?
    let onResult: @MainActor (FoodDraft) -> Void

    init(lookup: FoodsLookupModel, api: APIClient, toasts: ToastCenter, onResult: @escaping @MainActor (FoodDraft) -> Void) {
        self.lookup = lookup
        self._photos = State(initialValue: PhotoUploadModel(api: api, onError: { [weak toasts] message in toasts?.error(message) }))
        self.onResult = onResult
    }

    var body: some View {
        SheetScaffold(title: "AI 查询营养信息", primary: startAction) {
            Text(verbatim: "输入产品名称让 \(modelName) 联网查找官方营养成分表；或者上传包装、配料表、营养成分表照片，直接读取标签数值（更准确）。")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                FoodsTextField(label: "名称", text: $lookup.name, prompt: "如：螺蛳粉", autofocus: !lookup.isBusy)
                FoodsTextField(label: "品牌", text: $lookup.brand, prompt: "如：李子柒")
            }
            FoodsTextField(label: "补充说明（可选）", text: $lookup.note, prompt: "如：原味 335g 袋装；我一般只喝一半汤")
            VStack(alignment: .leading, spacing: 6) {
                FoodsFieldLabel("照片（可选）")
                // The job was started with these photos; keep the set (and the `正在读取标签…` hint) fixed while it runs.
                PhotoUploadStrip(model: photos, addLabel: "添加照片")
                    .disabled(lookup.isBusy)
            }
            if lookup.isBusy {
                Text(verbatim: busyHint)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .nlPulse()
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .interactiveDismissDisabled(lookup.isBusy)
        .aiConsentPrompt($consent)
        .onAppear(perform: resumeIfPending)
        .onChange(of: lookup.isBusy) { _, busy in
            // Lower the keyboard so the progress hint under the photos is visible (the web button takes focus on click).
            if busy { FoodsKeyboard.dismiss() }
        }
        // Refresh `{elapsed}s` every 0.5 s while the job runs (web interval).
        .task(id: lookup.isBusy) {
            while lookup.isBusy, !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// `me.ai.model ?? "Claude"`.
    private var modelName: String {
        guard let model = app.me?.ai.model, !model.isEmpty else { return "Claude" }
        return model
    }

    private var elapsed: Int { JobProgressView.elapsed(since: lookup.startedAt, now: now) }

    /// `正在读取标签…` with photos, else `正在联网查找营养成分表…`, then ` 一般需要 30–120 秒`.
    private var busyHint: String {
        JobProgressView.foodHint(hasPhotos: !photos.photos.isEmpty)(elapsed)
    }

    /// `开始` (Sparkles); disabled while busy or when the name is blank and there are no photos. Busy: spinner + `{elapsed}s`.
    private var startAction: SheetAction {
        if lookup.isBusy {
            return SheetAction(title: "\(elapsed)s", isBusy: true) {}
        }
        let canStart = lookup.canStart(photoCount: photos.photos.count) && !photos.isUploading
        return SheetAction(title: "开始", icon: "sparkles", isEnabled: canStart) {
            app.withAIConsent($consent) { lookup.start(app: app, photoIds: photos.ids, onResult: onResult) }
        }
    }

    private func resumeIfPending() {
        guard !checkedResume else { return }
        checkedResume = true
        guard !lookup.isBusy, let job = FoodsLookupModel.pendingJob() else { return }
        let ids = (job.context["photos"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if !ids.isEmpty { photos.restore(ids: ids) }
        lookup.resume(app: app, job: job, onResult: onResult)
    }
}

// MARK: - Lookup job state

/// One AI food lookup at a time. The job id is saved as a `PendingJob` (kind `food`, context name/brand/note/photos)
/// until it finishes, fails or is cancelled.
@MainActor @Observable final class FoodsLookupModel {
    var name = ""
    var brand = ""
    var note = ""
    private(set) var isBusy = false
    private(set) var phase: JobPhase?
    private(set) var startedAt = Date()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var jobId: String?
    @ObservationIgnored private var onResult: (@MainActor (FoodDraft) -> Void)?

    static let pendingKind = "food"
    /// Pending lookups older than this are not resumed.
    static let resumeWindow: TimeInterval = 30 * 60

    init() {}

    /// The newest unfinished lookup younger than 30 minutes, if any. Older ones are dropped (they are never resumed).
    static func pendingJob() -> PendingJob? {
        for stale in PendingJobStore.all(kind: pendingKind) where Date().timeIntervalSince(stale.createdAt) >= resumeWindow {
            PendingJobStore.remove(id: stale.id)
        }
        return PendingJobStore.latest(kind: pendingKind, maxAge: resumeWindow)
    }

    /// Web: disabled when `!name.trim() && !photos.length`.
    func canStart(photoCount: Int) -> Bool {
        !isBusy && (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoCount > 0)
    }

    /// A fresh form for a new lookup (the web mounts a new modal each time).
    func resetFields() {
        guard !isBusy else { return }
        name = ""
        brand = ""
        note = ""
    }

    func start(app: AppState, photoIds: [String], onResult: @escaping @MainActor (FoodDraft) -> Void) {
        guard canStart(photoCount: photoIds.count) else { return }
        let request = FoodAIRequest(name: name, brand: brand, note: note, photos: photoIds)
        let context = ["name": name, "brand": brand, "note": note, "photos": photoIds.joined(separator: ",")]
        begin(startedAt: Date(), onResult: onResult)
        task = Task { [weak self] in
            await self?.run(app: app, request: request, context: context, resumeJobId: nil)
        }
    }

    /// Continues polling a saved job (fields restored from its context, elapsed time counted from its creation).
    func resume(app: AppState, job: PendingJob, onResult: @escaping @MainActor (FoodDraft) -> Void) {
        guard !isBusy else { return }
        name = job.context["name"] ?? ""
        brand = job.context["brand"] ?? ""
        note = job.context["note"] ?? ""
        begin(startedAt: job.createdAt, onResult: onResult)
        let request = FoodAIRequest(name: name, brand: brand, note: note, photos: [])
        task = Task { [weak self] in
            await self?.run(app: app, request: request, context: job.context, resumeJobId: job.id)
        }
    }

    /// Stops polling (the sheet was closed). The server job keeps running; `run` shows the toast `已取消`.
    func cancel() {
        task?.cancel()
    }

    private func begin(startedAt: Date, onResult: @escaping @MainActor (FoodDraft) -> Void) {
        self.onResult = onResult
        self.startedAt = startedAt
        phase = nil
        jobId = nil
        isBusy = true
    }

    private func run(app: AppState, request: FoodAIRequest, context: [String: String], resumeJobId: String?) async {
        do {
            let id: String
            if let resumeJobId {
                id = resumeJobId
            } else {
                id = try await app.api.startFoodAI(request)
                for old in PendingJobStore.all(kind: Self.pendingKind) { PendingJobStore.remove(id: old.id) }
                PendingJobStore.save(PendingJob(id: id, kind: Self.pendingKind, createdAt: startedAt, context: context))
            }
            jobId = id
            let draft = try await JobPoller(api: app.api).wait(jobId: id, as: FoodDraft.self) { [weak self] p in
                self?.phase = p
            }
            PendingJobStore.remove(id: id)
            let deliver = onResult
            finish()
            guard let draft else {
                app.toasts.error(APIError.jobFailedMessage)
                return
            }
            deliver?(draft)
        } catch is CancellationError {
            if let jobId { PendingJobStore.remove(id: jobId) }
            finish()
            app.toasts.show(APIError.cancelledMessage)
        } catch {
            let apiError = APIError.from(error)
            // A connectivity failure keeps the job for a later resume; anything else (job error, 404 …) ends it.
            if let jobId {
                if case .network = apiError {} else { PendingJobStore.remove(id: jobId) }
            }
            finish()
            // An expired session is reported by AppState itself.
            if case .unauthorized = apiError { return }
            app.toasts.error(apiError)
        }
    }

    private func finish() {
        task = nil
        jobId = nil
        onResult = nil
        phase = nil
        isBusy = false
    }
}
