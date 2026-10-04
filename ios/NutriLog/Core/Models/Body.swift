import Foundation

// MARK: - Body & activity (body §2–§5)

/// `POST /body`. Booleans are real JSON booleans in requests (the server uses JS truthiness).
struct BodyInput: Encodable, Sendable { var date: String; var time: String; var weight_kg: Double?; var body_fat_pct: Double?; var waist_cm: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool; var note: String? }
/// `POST /labs`; values in mg/dL (HbA1c in %). Convert mmol/L on the client (body §3.5).
struct LabInput: Encodable, Sendable { var date: String; var total_chol: Double?; var hdl: Double?; var ldl: Double?; var non_hdl: Double?; var fasting_glucose: Double?; var hba1c: Double?; var lipid_treated: Bool; var diabetes: Bool; var note: String? }

/// The seven daily-total fields. Encoding omits nil fields: for `PUT /activity/{date}` an omitted field is cleared,
/// for `/preview` and `/activity/commit` it keeps the stored value.
struct ActivityValues: Codable, Sendable, Hashable {
    var steps: Double?; var active_kcal: Double?; var resting_kcal: Double?; var distance_km: Double?
    var exercise_min: Double?; var sleep_hours: Double?; var stand_hours: Double?
    init(steps: Double? = nil, active_kcal: Double? = nil, resting_kcal: Double? = nil, distance_km: Double? = nil, exercise_min: Double? = nil, sleep_hours: Double? = nil, stand_hours: Double? = nil) {
        self.steps = steps; self.active_kcal = active_kcal; self.resting_kcal = resting_kcal; self.distance_km = distance_km
        self.exercise_min = exercise_min; self.sleep_hours = sleep_hours; self.stand_hours = stand_hours
    }
    init(_ day: ActivityDay?) {
        self.init(steps: day?.steps, active_kcal: day?.active_kcal, resting_kcal: day?.resting_kcal, distance_km: day?.distance_km,
                  exercise_min: day?.exercise_min, sleep_hours: day?.sleep_hours, stand_hours: day?.stand_hours)
    }
}

extension ActivityValues {
    /// True when every field is nil.
    var isEmpty: Bool {
        steps == nil && active_kcal == nil && resting_kcal == nil && distance_km == nil
            && exercise_min == nil && sleep_hours == nil && stand_hours == nil
    }
}

/// `GET /activity` (both lists ordered newest first).
struct ActivityList: Decodable, Sendable { let days: [ActivityDay]; let exercises: [Exercise] }
/// `POST /exercises`. Needs `activity_key` or `met`; `avg_hr`/`device_kcal` are not accepted here.
struct ExerciseInput: Encodable, Sendable { var date: String; var time: String?; var activity_key: String?; var met: Double?; var duration_min: Double; var distance_km: Double?; var description: String?; var in_device: Bool; var source: String? }
struct ExerciseCreated: Decodable, Sendable { let id: Int; let kcal: Double }
struct InDeviceBody: Encodable, Sendable { let in_device: Bool }
struct ActivityAIRequest: Encodable, Sendable { let text: String; let date: String; let photos: [String] }
struct BodyDraft: Codable, Sendable, Hashable { var weight_kg: Double?; var body_fat_pct: Double?; var sbp: Double?; var dbp: Double? }

/// Workout in an `ActivityDraft` (body §4.4) and in `/preview` / `/activity/commit` requests.
/// `in_device` is a real boolean here (unlike the 0/1 integer on stored rows).
struct WorkoutDraft: Codable, Sendable, Hashable, Identifiable {
    var localId: UUID = UUID()
    var description: String; var activity_key: String; var met: Double; var duration_min: Double; var distance_km: Double?
    var kcal: Double?; var notes: String?; var avg_hr: Double?; var device_kcal: Double?; var in_device: Bool
    var id: UUID { localId }
    enum CodingKeys: String, CodingKey { case description, activity_key, met, duration_min, distance_km, kcal, notes, avg_hr, device_kcal, in_device }
}

extension WorkoutDraft {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        description = try c.or("description", "")
        activity_key = try c.or("activity_key", "other_moderate")
        met = try c.or("met", 4.5)
        duration_min = try c.or("duration_min", 30)
        distance_km = try c.opt("distance_km")
        kcal = try c.opt("kcal")
        notes = try c.opt("notes")
        avg_hr = try c.opt("avg_hr")
        device_kcal = try c.opt("device_kcal")
        in_device = try c.flexBool("in_device", or: false)
    }
}

/// Result of AI job kind `activity` (body §4.4). Commit with `date` from the draft (it may differ when `date_from_image`).
struct ActivityDraft: Codable, Sendable {
    var date: String; var date_from_image: Bool; var activity: ActivityValues; var body: BodyDraft; var workouts: [WorkoutDraft]
    var notes: String; var provider: String; var model: String
}

extension ActivityDraft {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        date = try c.req("date")
        date_from_image = try c.flexBool("date_from_image", or: false)
        activity = try c.or("activity", ActivityValues())
        body = try c.or("body", BodyDraft(weight_kg: nil, body_fat_pct: nil, sbp: nil, dbp: nil))
        workouts = try c.or("workouts", [])
        notes = try c.or("notes", "")
        provider = try c.or("provider", "")
        model = try c.or("model", "")
    }
}

/// `body` of `POST /activity/commit`. `time` defaults to 22:00 on the server; `waist_cm` is not supported there.
struct CommitBody: Encodable, Sendable { var weight_kg: Double?; var body_fat_pct: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool; var time: String? }
/// `POST /activity/commit` (body §4.6). `source` is `"ai"` or `"manual"`.
struct ActivityCommitRequest: Encodable, Sendable { let date: String; let source: String; let activity: ActivityValues; let body: CommitBody; let workouts: [WorkoutDraft] }
struct ActivityCommitResponse: Decodable, Sendable { let ok: Bool; let date: String; let workouts: Int }
