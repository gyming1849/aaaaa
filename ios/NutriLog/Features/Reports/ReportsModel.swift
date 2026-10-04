import SwiftUI
import Observation

// MARK: - Period kinds and ranges (web2 §5.2.1, rep §6.1, §7.1)

/// 周报 / 月报 as on the web, plus `custom` for stored reports (rep §8) whose range is neither a Monday-based week
/// nor a whole calendar month.
enum ReportsPeriodKind: String, Hashable, Sendable, CaseIterable {
    case week, month, custom

    /// Segment / history label.
    var zh: String {
        switch self {
        case .week: "周报"
        case .month: "月报"
        case .custom: "自定义"
        }
    }

    /// Total tile label (`本周总分` / `本月总分`).
    var totalLabel: String {
        switch self {
        case .week: "本周总分"
        case .month: "本月总分"
        case .custom: "本期总分"
        }
    }
}

/// The report period shown by `ReportsScreen`. Dates are `YYYY-MM-DD` calendar days (LocalDay, UTC arithmetic).
struct ReportsRange: Hashable, Sendable {
    let kind: ReportsPeriodKind
    let start: String
    let end: String

    /// `start = weekStart(anchor)`, `end = start + 6`.
    static func week(anchor: String) -> ReportsRange {
        let start = LocalDay.weekStart(anchor)
        return ReportsRange(kind: .week, start: start, end: LocalDay.addDays(start, 6))
    }

    /// `start = monthStart(anchor)`, `end = monthEnd(anchor)`.
    static func month(anchor: String) -> ReportsRange {
        ReportsRange(kind: .month, start: LocalDay.monthStart(anchor), end: LocalDay.monthEnd(anchor))
    }

    /// Default 周报 = **last** week's Monday … Sunday (web `addDays(weekStart(today), -7)`).
    static func defaultWeek(today: String) -> ReportsRange { week(anchor: LocalDay.addDays(LocalDay.weekStart(today), -7)) }

    /// Default 月报 = the **current** month (the web's intentional asymmetry, web2 §7 item 8).
    static func defaultMonth(today: String) -> ReportsRange { month(anchor: today) }

    /// The range for an explicit `start`/`end`: a Monday-based 7-day span is a week, a whole calendar month is a month,
    /// anything else stays custom.
    static func detect(start: String, end: String) -> ReportsRange {
        if LocalDay.isValid(start), LocalDay.isValid(end) {
            if start == LocalDay.monthStart(start), end == LocalDay.monthEnd(start) { return month(anchor: start) }
            if start == LocalDay.weekStart(start), LocalDay.diffDays(start, end) == 6 { return week(anchor: start) }
        }
        return ReportsRange(kind: .custom, start: start, end: end)
    }

    /// `ReportsScreen(start:end:kind:)`: week/month are normalised from `start` like the web's anchor.
    static func make(start: String, end: String, kind: ReportsPeriodKind) -> ReportsRange {
        switch kind {
        case .week: week(anchor: start)
        case .month: month(anchor: start)
        case .custom: detect(start: start, end: end)
        }
    }

    /// Number of calendar days in the range (≥ 1).
    var dayCount: Int { max(1, LocalDay.diffDays(start, end) + 1) }

    /// 上一期 / 下一期: weeks move ±7 days, months ±1 calendar month from `start` (UTC month arithmetic), custom ranges by
    /// their own length.
    func shifted(_ direction: Int) -> ReportsRange {
        switch kind {
        case .week: ReportsRange.week(anchor: LocalDay.addDays(start, direction * 7))
        case .month: ReportsRange.month(anchor: LocalDay.addMonths(start, direction))
        case .custom:
            ReportsRange(kind: .custom, start: LocalDay.addDays(start, direction * dayCount), end: LocalDay.addDays(end, direction * dayCount))
        }
    }

    /// 下一期 is disabled when `end >= today`.
    func canGoNext(today: String) -> Bool { end < today }

    /// Week `2026-09-21 ~ 09-27`; month `2026 年 9 月`; custom `2026-08-03 ~ 09-01` (full end date across years).
    var label: String {
        switch kind {
        case .week:
            return "\(start) ~ \(end.dropFirst(5))"
        case .month:
            let month = LocalDay.parts(start)?.month ?? Int(start.dropFirst(5).prefix(2)) ?? 0
            return "\(start.prefix(4)) 年 \(month) 月"
        case .custom:
            return start.prefix(4) == end.prefix(4) ? "\(start) ~ \(end.dropFirst(5))" : "\(start) ~ \(end)"
        }
    }
}

// MARK: - Reports view model

/// State for one `ReportsScreen`: the selected period, the loaded `PeriodScore`, and the AI 点评 job.
///
/// The summary job is persisted as a `PendingJob` (kind `summary`, context `start`/`end`) before polling, so leaving the
/// screen, switching periods or relaunching the app never loses it: whenever a period is shown, a pending job for exactly
/// that period is adopted and polling resumes (the server keeps jobs for 7 days).
@MainActor @Observable final class ReportsModel {
    /// The user's choice; `nil` = the default 周报 for the current `app.today`.
    var range: ReportsRange?

    private(set) var data: PeriodScore?
    /// Period of `data` (the server's echo may differ only by clamping, which never happens for weeks and months).
    private(set) var loadedRange: ReportsRange?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Period whose `POST /period/summary` is in flight.
    private(set) var startingRange: ReportsRange?
    /// Job being polled for `jobRange` (drives the screen's `.task(id:)`).
    private(set) var activeJobId: String?
    private(set) var jobRange: ReportsRange?
    private(set) var jobPhase: JobPhase?
    private(set) var jobStartedAt: Date?
    @ObservationIgnored private var jobWasResumed = false

    @ObservationIgnored private var shownRange: ReportsRange?
    @ObservationIgnored private var loadGeneration = 0

    static let jobKind = "summary"

    init(range: ReportsRange? = nil) {
        self.range = range
    }

    /// The period on screen.
    func effectiveRange(today: String) -> ReportsRange { range ?? .defaultWeek(today: today) }

    /// True while the AI summary for `range` is being requested or generated.
    func isGenerating(for range: ReportsRange) -> Bool {
        startingRange == range || (activeJobId != nil && jobRange == range)
    }

    /// `data` belongs to `range` (otherwise it is the previous period, shown dimmed while the new one loads).
    func isCurrent(_ range: ReportsRange) -> Bool { loadedRange == range }

    // MARK: Period selection

    /// Seg 周报 / 月报: like the web, choosing a kind always resets to its default period (even when re-selected).
    func selectKind(_ kind: ReportsPeriodKind, today: String) {
        switch kind {
        case .week: range = .defaultWeek(today: today)
        case .month: range = .defaultMonth(today: today)
        case .custom: break
        }
    }

    func shift(_ direction: Int, today: String) {
        let current = effectiveRange(today: today)
        if direction > 0, !current.canGoNext(today: today) { return }
        range = current.shifted(direction)
    }

    /// Called whenever the shown period may have changed or the screen comes back (load trigger, pull-to-refresh,
    /// return to the foreground): keeps the job already polled for this period, otherwise adopts the period's pending
    /// AI job (saved by this or an earlier session), otherwise clears the job state.
    func show(_ range: ReportsRange) {
        shownRange = range
        if activeJobId != nil, jobRange == range { return }
        if let job = Self.pendingJob(for: range) {
            activeJobId = job.id
            jobRange = range
            jobStartedAt = job.createdAt
            jobPhase = nil
            jobWasResumed = true
        } else {
            clearJob()
        }
    }

    // MARK: Loading

    /// `GET /period?start&end` (own data). Keeps the previous data visible while loading.
    func load(app: AppState, range: ReportsRange) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let result = try await app.api.period(start: range.start, end: range.end, user: nil)
            guard generation == loadGeneration else { return }
            data = result
            loadedRange = range
            error = nil
        } catch {
            guard generation == loadGeneration, !(error is CancellationError), !Task.isCancelled else { return }
            self.error = APIError.from(error).message
        }
    }

    // MARK: AI 点评 (rep §7, web2 §5.2.5)

    /// `POST /period/summary {start, end}` → job id → persisted → polled by the screen's `.task(id: activeJobId)`.
    func generate(app: AppState, range: ReportsRange) async {
        guard startingRange == nil, !isGenerating(for: range) else { return }
        startingRange = range
        defer { startingRange = nil }
        do {
            let jobId = try await app.api.startPeriodSummary(start: range.start, end: range.end)
            let job = PendingJob(id: jobId, kind: Self.jobKind, createdAt: Date(), context: ["start": range.start, "end": range.end])
            PendingJobStore.save(job)
            // If the user moved to another period meanwhile, the job stays pending and is adopted when they come back.
            if shownRange == range {
                activeJobId = jobId
                jobRange = range
                jobStartedAt = job.createdAt
                jobPhase = nil
                jobWasResumed = false
            }
        } catch {
            Self.report(error, app: app)
        }
    }

    /// Polls the active job until it ends, then re-fetches `/period` (the stored summary appears in `aiSummary`).
    /// A `done` job with a `null` result (mock provider / no logged days) is not an error. Cancellation (screen left,
    /// period changed, app suspended) and connectivity loss keep the pending job, so polling resumes on the next visit,
    /// pull-to-refresh or return to the foreground (rep §7.2: the job id stays valid).
    func pollActiveJob(app: AppState) async {
        guard let jobId = activeJobId, let range = jobRange else { return }
        let resumed = jobWasResumed
        do {
            // The result itself is not shown (the summary is read back from `/period`), so accept any JSON there.
            _ = try await JobPoller(api: app.api).wait(jobId: jobId, as: ReportsIgnoredJobResult.self) { [weak self] phase in
                guard let self, self.activeJobId == jobId else { return }
                self.jobPhase = phase
            }
            PendingJobStore.remove(id: jobId)
            await load(app: app, range: range)
            finishJob(jobId)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            let e = APIError.from(error)
            finishJob(jobId)
            if case .network = e {
                app.toasts.error(e.message)
                return
            }
            PendingJobStore.remove(id: jobId)
            // A resumed job the server no longer knows (purged after a restart) is simply forgotten.
            if resumed, e.status == 404 { return }
            Self.report(e, app: app)
        }
    }

    /// Error toast, except for an expired session (AppState already says `登录已失效，请重新登录`).
    private static func report(_ error: Error, app: AppState) {
        if case .unauthorized = APIError.from(error) { return }
        app.toasts.error(error)
    }

    private func finishJob(_ jobId: String) {
        guard activeJobId == jobId else { return }
        clearJob()
    }

    private func clearJob() {
        activeJobId = nil
        jobRange = nil
        jobPhase = nil
        jobStartedAt = nil
        jobWasResumed = false
    }

    private static func pendingJob(for range: ReportsRange) -> PendingJob? {
        PendingJobStore.all(kind: jobKind).first { $0.context["start"] == range.start && $0.context["end"] == range.end }
    }
}

/// Placeholder for the summary job's `result` (`WeeklySummary` or `null`): decoding always succeeds, because Reports
/// re-reads the stored summary from `GET /period` instead.
struct ReportsIgnoredJobResult: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
