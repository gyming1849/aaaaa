import Foundation

// MARK: - AI jobs (meals §2.7, rep §7.2, DESIGN §B.4)

enum JobPhase: Sendable, Equatable { case queued, running }

/// Polls `GET ai/jobs/{id}` every 1.5 s until the job is `done` or `error`.
/// Cancelling the calling task stops polling (the server job keeps running; screens toast `已取消`).
struct JobPoller: Sendable {
    let api: APIClient
    var interval: Duration = .milliseconds(1500)
    /// Consecutive network failures tolerated while polling (a long AI job should survive a brief connectivity blip).
    /// HTTP errors such as 404 `任务不存在` are never retried.
    var maxConsecutiveNetworkErrors = 3

    /// Polls until done. Returns `result` (may be nil for summary jobs). Throws APIError.jobFailed / CancellationError.
    func wait<T: Decodable & Sendable>(jobId: String, as type: T.Type, onPhase: @escaping @MainActor @Sendable (JobPhase) -> Void = { _ in }) async throws -> T? {
        var networkErrors = 0
        while true {
            try Task.checkCancellation()
            let j: Job<T>
            do {
                j = try await api.job(id: jobId, as: T.self)
                networkErrors = 0
            } catch let error as APIError {
                guard case .network = error, networkErrors < maxConsecutiveNetworkErrors else { throw error }
                networkErrors += 1
                AppLog.net.notice("job poll network error \(networkErrors, privacy: .public)/\(maxConsecutiveNetworkErrors, privacy: .public); retrying")
                try await Task.sleep(for: interval)
                continue
            }
            switch j.status {
            case .done: return j.result
            case .error: throw APIError.jobFailed(message: Self.nonEmpty(j.error) ?? APIError.jobFailedMessage)
            case .queued: await onPhase(.queued)
            case .running: await onPhase(.running)
            }
            try await Task.sleep(for: interval)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Pending jobs (resume after relaunch, web2 §1.6)

/// An AI job a screen started and is waiting for. `kind` is the server job kind (`meal`, `food`, `activity`, `summary`);
/// `context` holds what the screen needs to resume (e.g. `date`, `time`, `meal_type`, `text`, `photos` joined by `,`).
struct PendingJob: Codable, Sendable, Identifiable, Hashable { let id: String; let kind: String; let createdAt: Date; let context: [String: String] }

/// `UserDefaults` key `nl.pendingJobs` (§A.9). Jobs older than 7 days are dropped (the server purges them too).
enum PendingJobStore {
    static let defaultsKey = "nl.pendingJobs"
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static func save(_ job: PendingJob) {
        var jobs = load().filter { $0.id != job.id }
        jobs.append(job)
        store(jobs)
    }

    static func remove(id: String) {
        let jobs = load()
        let kept = jobs.filter { $0.id != id }
        if kept.count != jobs.count { store(kept) }
    }

    /// Pending jobs of one kind, newest first.
    static func all(kind: String) -> [PendingJob] {
        load().filter { $0.kind == kind }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The newest pending job of `kind` younger than `maxAge` seconds (LogMeal resumes `meal` jobs under 30 minutes).
    static func latest(kind: String, maxAge: TimeInterval) -> PendingJob? {
        all(kind: kind).first { Date().timeIntervalSince($0.createdAt) < maxAge }
    }

    /// Wipes every pending job (logout).
    static func removeAll() { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    private static func load() -> [PendingJob] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let jobs = try? JSONDecoder().decode([PendingJob].self, from: data) else { return [] }
        let now = Date()
        return jobs.filter { now.timeIntervalSince($0.createdAt) < maxAge }
    }

    private static func store(_ jobs: [PendingJob]) {
        if jobs.isEmpty { UserDefaults.standard.removeObject(forKey: defaultsKey); return }
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
