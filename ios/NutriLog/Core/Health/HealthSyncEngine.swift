import Foundation
import HealthKit

// MARK: - One HealthKit sync run (DESIGN §B.5 "One sync run", §C.2)
// ranges → HealthKit reads → chunked `POST /health/sync` → ledger + anchors committed after each 200.
// Single-flight: a run requested while another is in progress waits for it (the façade coalesces requests).

enum HealthSyncFailure: Error, Sendable, Equatable {
    /// `HKError.errorDatabaseInaccessible`: the device is locked.
    case databaseInaccessible
    /// Any other HealthKit failure (message ready for the UI).
    case healthKit(String)
}

struct HealthSyncJob: Sendable {
    enum Scope: Sendable, Equatable {
        /// Observer / background refresh: yesterday and today.
        case recent
        /// Launch / foreground / manual / settings: from 7 days before the last uploaded day (or the whole window).
        case standard
        /// 用苹果健康数据覆盖这些日期: just these dates, with `overwrite_manual: true`.
        case overwrite([String])
    }

    let api: APIClient
    let scope: Scope
    /// Profile time zone (day keys).
    let timeZone: TimeZone
    /// Upload the whole backfill window (first run, after 重新同步全部 or a longer window).
    let fullRange: Bool
    let backfillDays: Int
    let bpTreated: Bool
    /// Local fallback for the server's `max_date` of kind `days`.
    let lastDaysMaxDate: String?
    let deviceId: String
    let deviceName: String
    let onProgress: @MainActor @Sendable (String) -> Void
}

struct HealthSyncResult: Sendable {
    var daysSent = 0
    var bodySynced = 0
    var workoutsSynced = 0
    var deletedCount = 0
    /// Dates whose day totals were read in this run.
    var coveredDates: [String] = []
    var keptManual: [HealthKeptManualDay] = []
    var duplicates: [HealthDuplicate] = []
    var rejected: [String] = []
    var timezoneMismatch = false
    /// `timezone` of the last response (the profile time zone on the server).
    var serverTimeZone: String?
    /// The server invalidated scores (`invalidated_from != null`) at least once.
    var changed = false
    var approximateSleepDates: [String] = []
    /// `GET /health/sync/state` read at the start of a standard run.
    var state: HealthSyncState?
    /// The whole backfill window was uploaded.
    var completedFullRange = false
    var daysMaxDate: String?

    var summary: String { HealthSyncText.summary(days: daysSent, body: bodySynced, workouts: workoutsSynced, deleted: deletedCount) }
}

actor HealthSyncEngine {
    static let shared = HealthSyncEngine()

    private let store: HKHealthStore
    private let anchors: AnchorStore
    private var running: (id: UUID, task: Task<HealthSyncResult, Error>)?

    init(store: HKHealthStore = HealthKitManager.store, anchors: AnchorStore = .shared) {
        self.store = store
        self.anchors = anchors
    }

    /// Runs `job` after any run in progress. Cancelling the caller cancels the run (anchors stay uncommitted).
    func run(_ job: HealthSyncJob) async throws -> HealthSyncResult {
        while let previous = running {
            _ = try? await previous.task.value
            if running?.id == previous.id { running = nil }
        }
        let id = UUID()
        let task = Task { try await self.perform(job) }
        running = (id, task)
        defer { if running?.id == id { running = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 重新同步全部 / unlink / logout.
    func resetAll() async { await anchors.reset() }

    /// Re-reads these streams from the start of the window on the next run (longer backfill, 降压药 changed).
    func resetAnchors(_ kinds: [HealthSyncKindsReset]) async {
        await anchors.resetAnchors(kinds.flatMap(\.kinds))
    }

    // MARK: - Run

    private struct Reads: Sendable {
        /// Dates whose day totals were read (the run's range plus the dates of new workouts outside it).
        var coveredDates: [String] = []
        var days: [SyncDay] = []
        var dayActive: [String: Double] = [:]
        var approximateSleep: [String] = []
        var samples: [HealthTagged<SyncSample>] = []
        var workouts: [HealthTagged<SyncWorkout>] = []
        var deleted: [HealthTagged<String>] = []
        var newAnchors: [HealthSampleKind: HKQueryAnchor] = [:]
    }

    private func perform(_ job: HealthSyncJob) async throws -> HealthSyncResult {
        let tz = job.timeZone
        let today = LocalDay.key(for: Date(), in: tz)
        let backfillStart = LocalDay.addDays(today, -(max(1, job.backfillDays) - 1))
        let epoch = await anchors.currentEpoch()
        var result = HealthSyncResult()

        // 1. Range
        var dates: [String]
        var isFull = false
        switch job.scope {
        case .recent:
            dates = LocalDay.range(LocalDay.addDays(today, -1), today)
        case .overwrite(let list):
            dates = Array(Set(list.filter { LocalDay.isValid($0) && $0 <= today })).sorted()
        case .standard:
            await job.onProgress("正在读取同步状态…")
            let state = try await job.api.healthSyncState()
            result.state = state
            var start = backfillStart
            let serverMax = state.devices.first { $0.device_id == job.deviceId }?.kinds["days"]?.max_date
            if !job.fullRange, let last = serverMax ?? job.lastDaysMaxDate, LocalDay.isValid(last) {
                start = max(LocalDay.addDays(min(last, today), -6), backfillStart)
            } else {
                isFull = true
            }
            dates = LocalDay.range(start, today)
        }
        try Task.checkCancellation()

        // 2–5. HealthKit reads
        let reads: Reads
        do {
            reads = try await read(job: job, dates: dates, today: today, backfillStart: backfillStart)
        } catch let error as CancellationError {
            throw error
        } catch let error as HealthSyncFailure {
            throw error
        } catch {
            AppLog.health.error("HealthKit read failed: \(String(describing: error), privacy: .public)")
            throw HealthKitManager.isDatabaseInaccessible(error) ? HealthSyncFailure.databaseInaccessible
                : HealthSyncFailure.healthKit(HealthKitManager.message(for: error))
        }
        result.coveredDates = reads.coveredDates
        result.approximateSleepDates = reads.approximateSleep

        // 6. Upload in chunks; ledger and anchors only after each 200
        let plan = HealthUploadPlan.make(days: reads.days, samples: reads.samples, workouts: reads.workouts, deleted: reads.deleted)
        var remaining = plan.batchesPerKey
        for (kind, anchor) in reads.newAnchors where (remaining[kind.anchorKey] ?? 0) == 0 {
            await anchors.commit(anchor, for: kind, epoch: epoch)
        }
        var ledger = await anchors.ledger()
        ledger.prune(today: today)
        let workoutsByUUID = Dictionary(reads.workouts.map { ($0.value.uuid, $0.value) }, uniquingKeysWith: { a, _ in a })
        let overwrite: Bool
        if case .overwrite = job.scope { overwrite = true } else { overwrite = false }

        for (index, batch) in plan.batches.enumerated() {
            try Task.checkCancellation()
            await job.onProgress(plan.batches.count > 1 ? "正在上传 \(index + 1)/\(plan.batches.count)…" : "正在上传…")
            let request = HealthSyncRequest(
                device_id: job.deviceId, device_name: job.deviceName, timezone: tz.identifier, overwrite_manual: overwrite,
                days: batch.days.isEmpty ? nil : batch.days,
                samples: batch.samples.isEmpty ? nil : batch.samples,
                workouts: batch.workouts.isEmpty ? nil : batch.workouts,
                deleted: batch.deleted.isEmpty ? nil : batch.deleted,
                cursors: nil)
            let response = try await job.api.healthSync(request)

            if !batch.days.isEmpty {
                let rejectedDates = Set(response.days?.rejected.compactMap(\.date) ?? [])
                for day in batch.days where !rejectedDates.contains(day.date) { ledger.record(day) }
                await anchors.saveLedger(ledger, epoch: epoch)
            }
            accumulate(response, batch: batch, workouts: workoutsByUUID, into: &result)
            for key in batch.keys {
                let left = (remaining[key] ?? 1) - 1
                remaining[key] = left
                if left <= 0, let kind = HealthSampleKind(rawValue: key), let anchor = reads.newAnchors[kind] {
                    await anchors.commit(anchor, for: kind, epoch: epoch)
                }
            }
        }

        result.daysMaxDate = reads.days.map(\.date).max()
        result.completedFullRange = isFull
        return result
    }

    /// Steps 2–5 (HealthKit only; no network).
    /// New workouts are read first: a workout dated outside `dates` (e.g. a Watch hike from three days ago synced late)
    /// adds its date to the day-totals read, so that day's active energy is uploaded together with the workout's
    /// `in_device` decided from it (body §8.1 uses `in_device` only when the day has `active_kcal`).
    private func read(job: HealthSyncJob, dates: [String], today: String, backfillStart: String) async throws -> Reads {
        let tz = job.timeZone
        var reads = Reads()
        let isOverwrite: Bool
        if case .overwrite = job.scope { isOverwrite = true } else { isOverwrite = false }
        let since = LocalDay.date(fromKey: backfillStart, in: tz) ?? Date().addingTimeInterval(-Double(max(1, job.backfillDays)) * 86_400)
        let maxDate = LocalDay.addDays(today, 1)

        // 4a. Workouts (anchored; the anchor is committed only after the upload, exactly as before)
        var workouts: HealthAnchoredBatch<HealthWorkoutRecord>?
        if !isOverwrite {
            await job.onProgress("正在读取体能训练…")
            let workoutAnchor = await anchors.anchor(for: .workout)
            workouts = try await HealthQueries.anchoredWorkouts(anchor: workoutAnchor, since: since, timeZone: tz, store: store)
            try Task.checkCancellation()
        }
        let workoutDates = Set((workouts?.added ?? []).filter { $0.date <= today && WorkoutMapper.map($0.facts) != nil }.map(\.date))
        let dayDates = Set(dates).union(workoutDates).sorted()
        reads.coveredDates = dayDates

        // 2. Day totals (`makeDays` emits only the listed dates, so the wider query span is harmless)
        if let first = dayDates.first, let last = dayDates.last {
            await job.onProgress("正在读取每日活动数据…")
            var readings: [HealthDayField: [String: Double]] = [:]
            for field in HealthDayField.cumulativeFields {
                readings[field] = try await HealthQueries.dailySums(field, start: first, end: last, timeZone: tz, store: store)
            }
            readings[.stand_hours] = try await HealthQueries.standHours(start: first, end: last, timeZone: tz, store: store)
            let segments = try await HealthQueries.sleepSegments(dates: dayDates, timeZone: tz, store: store)
            let nights = SleepAggregator.hoursByDay(segments, dates: dayDates, in: tz)
            readings[.sleep_hours] = nights.mapValues(\.hours)
            reads.approximateSleep = nights.filter { $0.value.approximate }.map(\.key).sorted()
            var ledger = await anchors.ledger()
            ledger.prune(today: today)
            reads.days = DayAggregator.makeDays(dates: dayDates, readings: readings, ledger: ledger)
            for day in reads.days { if let kcal = day.active_kcal { reads.dayActive[day.date] = kcal } }
        }
        guard let workouts else { return reads }   // overwrite: day totals only
        try Task.checkCancellation()

        // 3. Body samples (anchored). Their dates do not depend on day totals.
        await job.onProgress("正在读取身体数据…")
        for kind in HealthSampleKind.bodyKinds {
            let anchor = await anchors.anchor(for: kind)
            let batch = try await HealthQueries.anchoredBodySamples(kind, anchor: anchor, since: since, timeZone: tz, bpTreated: job.bpTreated, store: store)
            reads.samples += batch.added.filter { $0.date <= maxDate }.map { HealthTagged(key: kind.anchorKey, value: $0) }
            reads.deleted += batch.deleted.map { HealthTagged(key: kind.anchorKey, value: $0) }
            reads.newAnchors[kind] = batch.newAnchor
        }

        // 4b. Workouts → exercises, with the in_device rule (from the same day totals that are uploaded)
        reads.newAnchors[.workout] = workouts.newAnchor
        reads.deleted += workouts.deleted.map { HealthTagged(key: HealthSampleKind.workout.anchorKey, value: $0) }
        var tomorrowActive: [String: Double?] = [:]
        for record in workouts.added where record.date <= maxDate {
            guard let mapping = WorkoutMapper.map(record.facts) else { continue }
            var active = reads.dayActive[record.date]
            if record.date > today {
                // A workout dated tomorrow (time zone edge): its day is not uploaded, read the total just for in_device.
                if let cached = tomorrowActive[record.date] {
                    active = cached
                } else {
                    let total = try await HealthQueries.dayTotal(.active_kcal, date: record.date, timeZone: tz, store: store)
                    active = DayAggregator.normalize(total, field: .active_kcal)
                    tomorrowActive[record.date] = active
                }
            }
            let workout = SyncWorkout(
                uuid: record.uuid, date: record.date, time: record.time, start: record.start, end: record.end,
                hk_activity_type: Int(record.facts.activityType.rawValue),
                activity_key: mapping.activityKey, description: mapping.description, met: mapping.met,
                duration_min: mapping.durationMin, distance_km: record.distanceKm, avg_hr: record.avgHR,
                device_kcal: record.deviceKcal,
                in_device: WorkoutMapper.inDevice(deviceKcal: record.deviceKcal, dayActiveKcal: active),
                source_name: record.sourceName)
            reads.workouts.append(HealthTagged(key: HealthSampleKind.workout.anchorKey, value: workout))
        }
        return reads
    }

    /// Adds one response to the run's totals.
    private func accumulate(_ r: HealthSyncResponse, batch: HealthUploadBatch, workouts: [String: SyncWorkout], into result: inout HealthSyncResult) {
        if let d = r.days {
            result.daysSent += max(0, batch.days.count - d.rejected.count)
            result.keptManual += d.kept_manual.map { HealthKeptManualDay(date: $0.date, fields: $0.fields) }
            result.rejected += d.rejected.map { "\($0.date ?? "")：\($0.error)" }
        }
        if let s = r.samples {
            result.bodySynced += s.inserted + s.updated + s.unchanged
            result.rejected += s.rejected.map(\.error)
        }
        if let w = r.workouts {
            result.workoutsSynced += w.inserted + w.updated + w.unchanged
            result.rejected += w.rejected.map(\.error)
            for dup in w.possible_duplicates {
                let synced = workouts[dup.uuid]
                result.duplicates.append(HealthDuplicate(
                    uuid: dup.uuid, exercise_id: dup.exercise_id, manualDescription: dup.description,
                    date: synced?.date ?? "", workoutDescription: synced?.description ?? "",
                    durationMin: synced?.duration_min ?? 0))
            }
        }
        if let del = r.deleted { result.deletedCount += del.body + del.exercises }
        if r.timezone_mismatch { result.timezoneMismatch = true }
        result.serverTimeZone = r.timezone
        if r.invalidated_from != nil { result.changed = true }
    }
}

/// Which anchored streams a settings change must re-read.
enum HealthSyncKindsReset: Sendable {
    /// Longer backfill window: every stream.
    case all
    /// 正在服用降压药 changed: blood pressure readings carry the flag.
    case bloodPressure

    var kinds: [HealthSampleKind] {
        switch self {
        case .all: HealthSampleKind.allCases
        case .bloodPressure: [.bloodPressure]
        }
    }
}
