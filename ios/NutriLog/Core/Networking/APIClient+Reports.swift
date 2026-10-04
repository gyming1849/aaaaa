import Foundation

// MARK: - Day, trends, period, reports, standards (rep §2–§11)

extension APIClient {
    /// `GET day/{date}?user=` (rep §2). `user` = another member's username (case-insensitive), nil for own data.
    func day(_ date: String, user: String?) async throws -> DayResponse {
        try await send(.get, "day/\(date)", query: Self.items(["user": user]))
    }

    /// `GET trends?start&end&user` (rep §10), 120 s timeout. Up to ~3 MB; decoded inside this actor.
    func trends(start: String, end: String, user: String?) async throws -> TrendsResponse {
        try await send(.get, "trends", query: Self.items(["start": start, "end": end, "user": user]))
    }

    /// `GET period?start&end&user` (rep §6), 120 s timeout. The server clamps the span to 401 days.
    func period(start: String, end: String, user: String?) async throws -> PeriodScore {
        try await send(.get, "period", query: Self.items(["start": start, "end": end, "user": user]))
    }

    /// `POST period/summary {start, end}` (rep §7.1) → job id; the result is `WeeklySummary?`. Own data only.
    func startPeriodSummary(start: String, end: String) async throws -> String {
        let res: JobCreated = try await send(.post, "period/summary", body: AnyEncodable(PeriodSummaryRequest(start: start, end: end)))
        return res.job_id
    }

    /// `GET reports` (rep §8): up to 60 stored reports, newest first.
    func reports() async throws -> [ReportListItem] { try await send(.get, "reports") }

    /// `GET standards/meta` (rep §9.0). Cached by `AppState.ensureMeta`.
    func standardsMeta() async throws -> Meta { try await send(.get, "standards/meta") }

    /// `GET standards/dri` (rep §9.4).
    func standardsDri() async throws -> DriTables { try await send(.get, "standards/dri") }
}
