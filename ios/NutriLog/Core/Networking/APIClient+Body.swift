import Foundation

// MARK: - Body, labs, activity, exercises, AI activity, preview, HealthKit sync (body §3–§4, DESIGN §C.2–§C.4)

extension APIClient {
    /// `GET body?start&end` (body §3.1), newest first. Omitted bounds → all rows.
    func bodyMetrics(start: String?, end: String?) async throws -> [BodyMetric] {
        try await send(.get, "body", query: Self.items(["start": start, "end": end]))
    }

    /// `POST body` (body §3.2) → new row id.
    func addBodyMetric(_ body: BodyInput) async throws -> Int {
        let res: IdResponse = try await send(.post, "body", body: AnyEncodable(body))
        return res.id
    }

    /// `DELETE body/{id}` (body §3.3).
    func deleteBodyMetric(id: Int) async throws { try await sendNoContent(.delete, "body/\(id)") }

    /// `GET labs` (body §3.4), newest first, no date filter.
    func labs() async throws -> [LabResult] { try await send(.get, "labs") }

    /// `POST labs` (body §3.5). Values in mg/dL (convert mmol/L on the client) → new row id.
    func addLab(_ lab: LabInput) async throws -> Int {
        let res: IdResponse = try await send(.post, "labs", body: AnyEncodable(lab))
        return res.id
    }

    /// `DELETE labs/{id}` (body §3.6).
    func deleteLab(id: Int) async throws { try await sendNoContent(.delete, "labs/\(id)") }

    /// `GET activity?start&end` (body §3.7): days and workouts, newest first.
    func activity(start: String?, end: String?) async throws -> ActivityList {
        try await send(.get, "activity", query: Self.items(["start": start, "end": end]))
    }

    /// `PUT activity/{date}` (body §3.8): replaces every field; a nil value is omitted and therefore cleared.
    func putActivity(date: String, _ values: ActivityValues) async throws {
        try await sendNoContent(.put, "activity/\(date)", body: AnyEncodable(values))
    }

    /// `POST exercises` (body §3.9) → `{id, kcal}`.
    func addExercise(_ input: ExerciseInput) async throws -> ExerciseCreated {
        try await send(.post, "exercises", body: AnyEncodable(input))
    }

    /// `PATCH exercises/{id} {in_device}` (body §3.10).
    func setExerciseInDevice(id: Int, inDevice: Bool) async throws {
        try await sendNoContent(.patch, "exercises/\(id)", body: AnyEncodable(InDeviceBody(in_device: inDevice)))
    }

    /// `DELETE exercises/{id}` (body §3.11).
    func deleteExercise(id: Int) async throws { try await sendNoContent(.delete, "exercises/\(id)") }

    /// `POST ai/activity` (body §4.2) → job id; the result is an `ActivityDraft`.
    func startActivityAI(_ req: ActivityAIRequest) async throws -> String {
        let res: JobCreated = try await send(.post, "ai/activity", body: AnyEncodable(req))
        return res.job_id
    }

    /// `POST preview` (body §4.5 / meals §2.8): before/after scoring of unsaved changes, no writes.
    func preview(_ req: PreviewRequest) async throws -> DayPreview {
        try await send(.post, "preview", body: AnyEncodable(req))
    }

    /// `POST activity/commit` (body §4.6).
    func commitActivity(_ req: ActivityCommitRequest) async throws -> ActivityCommitResponse {
        try await send(.post, "activity/commit", body: AnyEncodable(req))
    }

    /// `POST health/sync` (§C.2), 120 s timeout. `.unsupportedByServer` before WP-S is deployed.
    func healthSync(_ req: HealthSyncRequest) async throws -> HealthSyncResponse {
        try await send(.post, "health/sync", body: AnyEncodable(req))
    }

    /// `GET health/sync/state` (§C.3).
    func healthSyncState() async throws -> HealthSyncState { try await send(.get, "health/sync/state") }

    /// `POST health/sync/unlink` (§C.4).
    func healthSyncUnlink(_ req: HealthUnlinkRequest) async throws -> HealthUnlinkResponse {
        try await send(.post, "health/sync/unlink", body: AnyEncodable(req))
    }
}
