import Foundation
import Observation

// MARK: - HealthKit sync façade (DESIGN §B.5, §E.3.3). Owner: WP9.
// Main-actor state for the UI (`status`, `snapshot`, `progress`), the enable/disable flow, triggers (launch, foreground,
// observers, background refresh, 立即同步, settings changes) and the request queue in front of `HealthSyncEngine`.
//
// Requests coalesce: while a run is in progress, new requests only mark what is pending (recent days, a standard run or
// dates to overwrite); the running loop picks them up before it ends, and every caller returns once that loop is done.

@MainActor @Observable final class HealthSyncService {
    static weak var current: HealthSyncService?
    private(set) var status = HealthSyncStatus()
    let api: APIClient
    private weak var app: AppState?

    /// Details shown by the sync screen (kept-manual dates, duplicates, legacy sources, server counts, …). Persisted.
    private(set) var snapshot = HealthSyncSnapshot()
    /// Step shown next to the spinner while a run is in progress.
    private(set) var progress: String?
    /// `30` / `90` / `365` (`30 天` / `90 天` / `一年`).
    private(set) var backfillDays: Int = HealthSyncSettings.defaultBackfillDays
    /// `正在服用降压药`, applied to synced blood pressure.
    private(set) var bpTreated = false

    /// Throttle for foreground runs and non-urgent observer callbacks.
    static let automaticInterval: TimeInterval = 10 * 60

    private let engine = HealthSyncEngine.shared
    private let background = HealthBackground()
    @ObservationIgnored private var loop: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var pendingStandard: HealthSyncReason?
    @ObservationIgnored private var pendingRecent = false
    @ObservationIgnored private var pendingOverwrite: Set<String> = []
    /// Bumped on logout / unlink so a run that is still finishing cannot write state back.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastFinishedAt: Date?
    /// Kind of the run in progress (non-urgent observer callbacks are dropped while one runs).
    @ObservationIgnored private var runningWork: Work?

    init(api: APIClient) {
        self.api = api
        HealthSyncService.current = self
        loadPersisted()
    }

    func attach(to app: AppState) { self.app = app }

    // MARK: - Lifecycle entry points (AppDelegate / AppState)

    /// Registers the `BGAppRefreshTask` handler. Must run before launch finishes (called from `AppDelegate`).
    nonisolated static func registerBackgroundTasks() { HealthBackground.registerRefreshTask() }

    /// Starts `HKObserverQuery`s + background delivery when sync is enabled (called from `AppDelegate`).
    static func startObserversIfEnabled() { current?.resumeObservers() }

    /// After every successful bootstrap and every profile save: caches the profile time zone and runs the launch sync.
    func onSessionReady() async {
        if let tz = app?.profile?.timezone, TimeZone(identifier: tz) != nil { HealthSyncSettings.cachedTimeZone = tz }
        if app?.authConfig?.supports("health_sync") == true, !status.serverSupportsSync {
            status.serverSupportsSync = true
            if status.lastError == HealthSyncText.serverNeedsUpgrade { status.lastError = nil }
            persist()
        }
        guard status.isEnabled else { return }
        resumeObservers()
        HealthBackground.scheduleRefresh()
        Task { await self.syncNow(reason: .launch) }
    }

    /// scenePhase → `.active` while signed in: sync when the last automatic run is older than 10 minutes.
    func onForeground() async {
        guard status.isEnabled else { return }
        if let tz = app?.profile?.timezone, TimeZone(identifier: tz) != nil { HealthSyncSettings.cachedTimeZone = tz }
        if let last = HealthSyncSettings.lastAutoSyncAt, Date().timeIntervalSince(last) < Self.automaticInterval { return }
        Task { await self.syncNow(reason: .foreground) }
    }

    /// Logout / account deletion: stop observers, wipe anchors, ledger and settings (the next user is different).
    func onLogout() async {
        generation += 1
        loop?.task.cancel()
        loop = nil
        clearPending()
        background.stopObservers()
        await engine.resetAll()
        HealthSyncSettings.wipe()
        snapshot = HealthSyncSnapshot()
        status = HealthSyncStatus(isAvailable: HealthKitManager.isAvailable)
        progress = nil
        backfillDays = HealthSyncSettings.defaultBackfillDays
        bpTreated = false
        lastFinishedAt = nil
    }

    /// Runs (or joins) a sync. Observer and background-refresh runs read yesterday and today; every other reason reads
    /// from a week before the last uploaded day. Only a background refresh propagates cancellation (task expiration).
    func syncNow(reason: HealthSyncReason) async {
        guard status.isAvailable, status.isEnabled else { return }
        switch reason {
        case .observer, .backgroundRefresh: pendingRecent = true
        case .launch, .foreground, .manual, .settingsChanged:
            if pendingStandard == nil || !Self.isAutomatic(reason) { pendingStandard = reason }
        }
        await drain(propagateCancellation: reason == .backgroundRefresh)
    }

    /// `HKObserverQuery` callback (HealthBackground). Weight, BP and workouts bypass the 10-minute throttle.
    /// While a long run (standard / overwrite, e.g. a backfill) is in progress, an urgent callback only queues the recent
    /// days: the loop picks them up before it ends, and HealthKit's completion is not held up by the long run.
    func observerFired(urgent: Bool) async {
        guard status.isEnabled else { return }
        if !urgent {
            if runningWork != nil { return }
            if let last = lastFinishedAt ?? HealthSyncSettings.lastAutoSyncAt,
               Date().timeIntervalSince(last) < Self.automaticInterval { return }
        } else {
            switch runningWork {
            case .standard?, .overwrite?:
                pendingRecent = true
                return
            case .recent?, nil:
                break
            }
        }
        await syncNow(reason: .observer)
    }

    /// Cancels the running loop (background time expired). Anchors stay uncommitted; the next trigger starts a fresh loop.
    func cancelBackgroundWork() { loop?.task.cancel() }

    // MARK: - Screen actions

    /// `同步苹果健康数据` on: server support check → HealthKit authorization → observers → initial sync (not awaited).
    func enable() async {
        guard status.isAvailable else { app?.toasts.error(HealthSyncText.unavailable); return }
        guard !status.isEnabled else { return }
        do {
            applyState(try await api.healthSyncState())
            status.serverSupportsSync = true
            if status.lastError == HealthSyncText.serverNeedsUpgrade { status.lastError = nil }
        } catch {
            let e = APIError.from(error)
            switch e {
            case .unsupportedByServer:
                status.serverSupportsSync = false
                status.lastError = HealthSyncText.serverNeedsUpgrade
                persist()
                app?.toasts.error(HealthSyncText.serverNeedsUpgrade)
            case .unauthorized: break
            default: app?.toasts.error(e.message)
            }
            return
        }
        do {
            try await HealthKitManager.requestSyncAuthorization()
        } catch {
            app?.toasts.error(HealthKitManager.message(for: error))
            return
        }
        if let tz = app?.profile?.timezone, TimeZone(identifier: tz) != nil { HealthSyncSettings.cachedTimeZone = tz }
        HealthSyncSettings.isEnabled = true
        status.isEnabled = true
        status.lastError = nil
        persist()
        background.startObservers()
        HealthBackground.scheduleRefresh()
        // The initial backfill runs in the background of this screen (spinner + progress in the status section),
        // so the toggle stays usable while it uploads.
        Task { await self.syncNow(reason: .settingsChanged) }
    }

    /// `同步苹果健康数据` off: stops observers and background refresh; anchors are kept, so turning it back on resumes.
    func disable() {
        HealthSyncSettings.isEnabled = false
        status.isEnabled = false
        clearPending()
        loop?.task.cancel()
        background.stopObservers()
        persist()
    }

    /// Backfill Seg. A longer window re-reads everything from its start.
    func setBackfillDays(_ days: Int) async {
        guard HealthSyncSettings.backfillOptions.contains(days), days != backfillDays else { return }
        let longer = days > backfillDays
        backfillDays = days
        HealthSyncSettings.backfillDays = days
        guard longer else {
            if status.isEnabled { await syncNow(reason: .settingsChanged) }
            return
        }
        await waitForIdle()
        HealthSyncSettings.initialBackfillDone = false
        await engine.resetAnchors([.all])
        if status.isEnabled { await syncNow(reason: .settingsChanged) }
    }

    /// `正在服用降压药`: re-sends the synced blood pressure readings with the new flag.
    func setBPTreated(_ on: Bool) async {
        guard on != bpTreated else { return }
        bpTreated = on
        HealthSyncSettings.bpTreated = on
        await waitForIdle()
        await engine.resetAnchors([.bloodPressure])
        if status.isEnabled { await syncNow(reason: .settingsChanged) }
    }

    /// `用苹果健康数据覆盖这些日期`: re-syncs the kept-manual dates with `overwrite_manual: true`.
    func overwriteKeptManual() async {
        guard status.isEnabled else { return }
        let dates = snapshot.keptManual.map(\.date)
        guard !dates.isEmpty else { return }
        pendingOverwrite.formUnion(dates)
        await drain(propagateCancellation: false)
    }

    /// `重新同步全部`: forgets anchors and the ledger and uploads the whole window again (idempotent server side).
    func resyncAll() async {
        guard status.isEnabled else { return }
        await waitForIdle()
        await engine.resetAll()
        HealthSyncSettings.initialBackfillDone = false
        HealthSyncSettings.lastDaysMaxDate = nil
        await syncNow(reason: .manual)
    }

    /// `断开并删除已同步的数据`: stops syncing, then `POST /health/sync/unlink {delete_data: true}` removes every
    /// HealthKit row of the user on the server. On failure the previous state is restored and the error rethrown.
    func unlinkAndDeleteData() async throws -> HealthUnlinkCounts {
        let wasEnabled = status.isEnabled
        disable()
        await waitForIdle()
        do {
            let res = try await api.healthSyncUnlink(HealthUnlinkRequest(device_id: DeviceInfo.installId, delete_data: true))
            generation += 1
            await engine.resetAll()
            HealthSyncSettings.initialBackfillDone = false
            HealthSyncSettings.lastDaysMaxDate = nil
            HealthSyncSettings.lastAutoSyncAt = nil
            snapshot = HealthSyncSnapshot()
            status = HealthSyncStatus(isAvailable: status.isAvailable, isEnabled: false)
            lastFinishedAt = nil
            persist()
            app?.noteDataChanged()
            return res.deleted
        } catch {
            if wasEnabled {
                HealthSyncSettings.isEnabled = true
                status.isEnabled = true
                background.startObservers()
                HealthBackground.scheduleRefresh()
                persist()
            }
            if APIError.from(error) == .unsupportedByServer {
                status.serverSupportsSync = false
                persist()
            }
            throw error
        }
    }

    /// `删除手动记录` for a possible duplicate (`DELETE /exercises/{id}`); an already deleted row just disappears.
    func deleteManualDuplicate(_ item: HealthDuplicate) async throws {
        do {
            try await api.deleteExercise(id: item.exercise_id)
        } catch let e as APIError {
            guard e.status == 404 else { throw e }
        }
        snapshot.duplicates.removeAll { $0.exercise_id == item.exercise_id }
        persist()
        app?.noteDataChanged()
    }

    /// Keeps both rows and hides the hint.
    func dismissDuplicate(_ item: HealthDuplicate) {
        snapshot.duplicates.removeAll { $0.id == item.id }
        persist()
    }

    /// `GET /health/sync/state` for the screen (legacy sources, server counts, server support).
    func refreshServerState() async {
        guard status.isAvailable else { return }
        do {
            applyState(try await api.healthSyncState())
            status.serverSupportsSync = true
            if status.lastError == HealthSyncText.serverNeedsUpgrade { status.lastError = nil }
            persist()
        } catch {
            if APIError.from(error) == .unsupportedByServer {
                status.serverSupportsSync = false
                persist()
            }
        }
    }

    // MARK: - Queue

    private static func isAutomatic(_ reason: HealthSyncReason) -> Bool {
        switch reason {
        case .launch, .foreground, .observer, .backgroundRefresh: true
        case .manual, .settingsChanged: false
        }
    }

    private func clearPending() {
        pendingStandard = nil
        pendingRecent = false
        pendingOverwrite = []
    }

    private enum Work {
        case overwrite([String])
        case standard(HealthSyncReason)
        case recent
    }

    private func takeNext() -> Work? {
        if !pendingOverwrite.isEmpty {
            let dates = pendingOverwrite.sorted()
            pendingOverwrite = []
            return .overwrite(dates)
        }
        if let reason = pendingStandard {
            pendingStandard = nil
            pendingRecent = false          // a standard run covers yesterday and today
            return .standard(reason)
        }
        if pendingRecent {
            pendingRecent = false
            return .recent
        }
        return nil
    }

    private func drain(propagateCancellation: Bool) async {
        // A cancelled loop (sync switched off, background task expired) ends without taking new work. Let it finish and
        // start a fresh one, so work queued meanwhile (e.g. a quick off → on) is not stranded until the next trigger.
        while let current = loop, current.task.isCancelled {
            await current.task.value
            if loop?.id == current.id { loop = nil }
        }
        let task: Task<Void, Never>
        if let current = loop {
            task = current.task
        } else {
            let id = UUID()
            let gen = generation
            task = Task { [weak self] in await self?.runLoop(id: id, generation: gen) }
            loop = (id, task)
        }
        if propagateCancellation {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        } else {
            await task.value
        }
    }

    private func runLoop(id: UUID, generation gen: Int) async {
        // Keep uploading for a while after the app goes to the background; when the time is up, cancel this loop
        // (`drain` starts a fresh one for work queued meanwhile).
        let assertion = BackgroundAssertion("HealthSync") { [weak self] in
            if let self, self.loop?.id == id { self.cancelBackgroundWork() }
        }
        defer { assertion.end() }
        while gen == generation, !Task.isCancelled, let work = takeNext() {
            runningWork = work
            defer { runningWork = nil }
            switch work {
            case .overwrite(let dates): await perform(.overwrite(dates), reason: .manual, generation: gen)
            case .standard(let reason): await perform(.standard, reason: reason, generation: gen)
            case .recent: await perform(.recent, reason: .observer, generation: gen)
            }
        }
        if loop?.id == id { loop = nil }
    }

    /// Lets the current loop finish (settings changes that reset anchors must not race a run committing them).
    private func waitForIdle() async {
        while let current = loop {
            await current.task.value
            if loop?.id == current.id { loop = nil }
        }
    }

    // MARK: - One run

    private func perform(_ scope: HealthSyncJob.Scope, reason: HealthSyncReason, generation gen: Int) async {
        guard status.isAvailable, status.isEnabled else { return }
        if Self.isAutomatic(reason), !status.serverSupportsSync { return }
        guard let tzId = app?.profile?.timezone ?? HealthSyncSettings.cachedTimeZone, let tz = TimeZone(identifier: tzId) else {
            AppLog.health.notice("sync skipped: no profile time zone yet")
            return
        }
        guard await api.currentToken() != nil, gen == generation else { return }
        if Self.isAutomatic(reason) { HealthSyncSettings.lastAutoSyncAt = Date() }

        status.isSyncing = true
        progress = "正在同步…"
        let job = HealthSyncJob(
            api: api, scope: scope, timeZone: tz,
            fullRange: !HealthSyncSettings.initialBackfillDone,
            backfillDays: backfillDays, bpTreated: bpTreated,
            lastDaysMaxDate: HealthSyncSettings.lastDaysMaxDate,
            deviceId: DeviceInfo.installId, deviceName: DeviceInfo.deviceName,
            onProgress: { [weak self] text in
                guard let self, self.generation == gen else { return }
                self.progress = text
            })
        AppLog.health.info("sync start (\(reason.rawValue, privacy: .public))")
        var lockedOut = false
        do {
            let result = try await engine.run(job)
            guard gen == generation else { return }
            apply(result, timeZone: tz)
            AppLog.health.info("sync done: \(result.summary, privacy: .public)")
        } catch {
            guard gen == generation else { return }
            handle(error)
            lockedOut = (error as? HealthSyncFailure) == .databaseInaccessible
        }
        status.isSyncing = false
        progress = nil
        if lockedOut {
            // `解锁后会自动同步`: a run deferred by the lock must not count for the 10-minute throttle, so the next
            // foreground (after unlocking) or observer callback syncs right away.
            lastFinishedAt = nil
            HealthSyncSettings.lastAutoSyncAt = nil
        } else {
            lastFinishedAt = Date()
        }
        persist()
        HealthBackground.scheduleRefresh()
    }

    private func apply(_ result: HealthSyncResult, timeZone tz: TimeZone) {
        let now = Date()
        let today = LocalDay.key(for: now, in: tz)
        let oldest = LocalDay.addDays(today, -(backfillDays - 1))
        let covered = Set(result.coveredDates)

        status.lastSyncAt = now
        status.lastSummary = result.summary
        status.lastError = nil
        status.serverSupportsSync = true

        var kept: [String: HealthKeptManualDay] = [:]
        for k in snapshot.keptManual where !covered.contains(k.date) && k.date >= oldest { kept[k.date] = k }
        for k in result.keptManual where k.date >= oldest { kept[k.date] = k }
        snapshot.keptManual = kept.values.sorted { $0.date > $1.date }
        status.keptManualDates = snapshot.keptManual.map(\.date)

        let approx = Set(snapshot.approximateSleepDates).subtracting(covered).union(result.approximateSleepDates)
        snapshot.approximateSleepDates = approx.filter { $0 >= oldest }.sorted(by: >)

        for d in result.duplicates where !snapshot.duplicates.contains(where: { $0.id == d.id }) {
            snapshot.duplicates.append(d)
        }
        var seen = Set<String>()
        snapshot.rejected = result.rejected.filter { seen.insert($0).inserted }.prefix(20).map { $0 }
        snapshot.timezoneMismatch = result.timezoneMismatch
        // Background runs (no `me` loaded) key days with the cached zone; follow the server's profile zone when it was
        // changed elsewhere, so the next run uses the right day keys.
        if result.timezoneMismatch, app?.profile == nil, let serverTz = result.serverTimeZone, TimeZone(identifier: serverTz) != nil {
            HealthSyncSettings.cachedTimeZone = serverTz
        }
        if let state = result.state { applyState(state) }

        if result.completedFullRange { HealthSyncSettings.initialBackfillDone = true }
        if let m = result.daysMaxDate, m > (HealthSyncSettings.lastDaysMaxDate ?? "") { HealthSyncSettings.lastDaysMaxDate = m }
        if result.changed {
            app?.noteDataChanged()
            Task { await self.refreshServerState() }
        }
    }

    private func applyState(_ state: HealthSyncState) {
        snapshot.legacyShortcutDays = state.legacy_sources.apple_shortcut_days
        snapshot.legacyExportDays = state.legacy_sources.apple_export_days
        snapshot.serverCounts = HealthServerCounts(days: state.counts.days, body: state.counts.body, workouts: state.counts.workouts)
        // The server's profile time zone is authoritative (it may have been changed on the web).
        if app?.profile == nil, TimeZone(identifier: state.timezone) != nil { HealthSyncSettings.cachedTimeZone = state.timezone }
    }

    private func handle(_ error: Error) {
        switch error {
        case HealthSyncFailure.databaseInaccessible:
            status.lastError = HealthSyncText.deviceLocked
        case HealthSyncFailure.healthKit(let message):
            status.lastError = message
        case is CancellationError:
            break
        default:
            let e = APIError.from(error)
            switch e {
            case .unsupportedByServer:
                status.serverSupportsSync = false
                status.lastError = HealthSyncText.serverNeedsUpgrade
            case .unauthorized:
                break
            default:
                status.lastError = e.message
            }
        }
        if let message = status.lastError { AppLog.health.notice("sync failed: \(message, privacy: .public)") }
    }

    // MARK: - Persistence

    private func loadPersisted() {
        let snap = HealthSyncSettings.loadSnapshot()
        snapshot = snap
        backfillDays = HealthSyncSettings.backfillDays
        bpTreated = HealthSyncSettings.bpTreated
        let available = HealthKitManager.isAvailable
        status = HealthSyncStatus(
            isAvailable: available,
            isEnabled: available && HealthSyncSettings.isEnabled,
            isSyncing: false,
            lastSyncAt: snap.lastSyncAt,
            lastSummary: snap.lastSummary,
            lastError: snap.lastError,
            keptManualDates: snap.keptManual.map(\.date),
            serverSupportsSync: snap.serverSupportsSync)
    }

    private func persist() {
        snapshot.lastSyncAt = status.lastSyncAt
        snapshot.lastSummary = status.lastSummary
        snapshot.lastError = status.lastError
        snapshot.serverSupportsSync = status.serverSupportsSync
        HealthSyncSettings.saveSnapshot(snapshot)
    }

    private func resumeObservers() {
        guard status.isAvailable, status.isEnabled else { return }
        background.startObservers()
    }
}
