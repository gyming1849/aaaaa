import Foundation

// MARK: - HealthKit sync (DESIGN §C.2–§C.4, new endpoints)

/// One day of HealthKit totals. A nil field is omitted (= unchanged); list a field in `clear` to null it on the server.
struct SyncDay: Codable, Sendable, Hashable {
    let date: String
    var steps: Double?; var active_kcal: Double?; var resting_kcal: Double?; var distance_km: Double?
    var exercise_min: Double?; var stand_hours: Double?; var sleep_hours: Double?
    var clear: [String]?
}
enum SyncSampleType: String, Codable, Sendable { case body_mass, body_fat, waist, blood_pressure }
struct SyncSample: Codable, Sendable, Hashable {
    let uuid: String; let type: SyncSampleType; let date: String; let time: String; var start: String?
    var value: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool?; var source_name: String?
}
struct SyncWorkout: Codable, Sendable, Hashable {
    let uuid: String; let date: String; let time: String; var start: String?; var end: String?; var hk_activity_type: Int?
    let activity_key: String; let description: String; var met: Double?; let duration_min: Double; var distance_km: Double?
    var avg_hr: Double?; var device_kcal: Double?; let in_device: Bool; var source_name: String?
}
/// `POST /health/sync`. Every section is optional; nil sections are omitted from the JSON.
struct HealthSyncRequest: Encodable, Sendable {
    let device_id: String; let device_name: String; let timezone: String; let overwrite_manual: Bool
    var days: [SyncDay]?; var samples: [SyncSample]?; var workouts: [SyncWorkout]?; var deleted: [String]?; var cursors: [String: String]?
}
/// Rejected item: `date` for days, `uuid` for samples/workouts.
struct SyncRejected: Decodable, Sendable, Hashable { let date: String?; let uuid: String?; let error: String }
struct KeptManual: Decodable, Sendable, Hashable { let date: String; let fields: [String] }
struct PossibleDuplicate: Decodable, Sendable, Hashable { let uuid: String; let exercise_id: Int; let description: String }
struct SyncDaysResult: Decodable, Sendable { let upserted: Int; let unchanged: Int; let kept_manual: [KeptManual]; let rejected: [SyncRejected] }
struct SyncSamplesResult: Decodable, Sendable { let inserted: Int; let updated: Int; let unchanged: Int; let skipped_tombstoned: Int; let rejected: [SyncRejected] }
struct SyncWorkoutsResult: Decodable, Sendable { let inserted: Int; let updated: Int; let unchanged: Int; let skipped_tombstoned: Int; let rejected: [SyncRejected]; let possible_duplicates: [PossibleDuplicate] }
struct SyncDeletedResult: Decodable, Sendable { let body: Int; let exercises: Int; let not_found: Int }
/// Sections absent from the request are absent from the response; `invalidated_from` is always present (maybe null).
struct HealthSyncResponse: Decodable, Sendable {
    let ok: Bool; let timezone: String; let server_today: String; let timezone_mismatch: Bool
    let days: SyncDaysResult?; let samples: SyncSamplesResult?; let workouts: SyncWorkoutsResult?; let deleted: SyncDeletedResult?
    let invalidated_from: String?
}
/// `last_synced_at` is SQLite UTC.
struct SyncKindState: Decodable, Sendable { let last_synced_at: String; let min_date: String?; let max_date: String?; let cursor: String? }
/// `kinds` keys: `days`, `samples`, `workouts`.
struct SyncDeviceState: Decodable, Sendable, Identifiable { let device_id: String; let device_name: String?; let kinds: [String: SyncKindState]; var id: String { device_id } }
struct SyncCounts: Decodable, Sendable { let days: Int; let body: Int; let workouts: Int }
struct LegacySources: Decodable, Sendable { let apple_shortcut_days: Int; let apple_export_days: Int }
/// `GET /health/sync/state` (§C.3).
struct HealthSyncState: Decodable, Sendable { let timezone: String; let server_today: String; let devices: [SyncDeviceState]; let counts: SyncCounts; let legacy_sources: LegacySources }
struct HealthUnlinkRequest: Encodable, Sendable { let device_id: String; let delete_data: Bool }
struct HealthUnlinkCounts: Decodable, Sendable { let body: Int; let exercises: Int; let days: Int }
struct HealthUnlinkResponse: Decodable, Sendable { let ok: Bool; let deleted: HealthUnlinkCounts }
/// UI-facing status published by HealthSyncService (WP9) and read by Body/More screens.
struct HealthSyncStatus: Sendable, Equatable {
    var isAvailable: Bool = false; var isEnabled: Bool = false; var isSyncing: Bool = false
    var lastSyncAt: Date? = nil; var lastSummary: String? = nil; var lastError: String? = nil
    var keptManualDates: [String] = []; var serverSupportsSync: Bool = true
}
enum HealthSyncReason: String, Sendable { case launch, foreground, observer, backgroundRefresh, manual, settingsChanged }
