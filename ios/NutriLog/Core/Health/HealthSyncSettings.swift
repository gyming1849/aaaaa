import Foundation

// MARK: - Persisted HealthKit sync settings and last status (UserDefaults `nl.health.*`, DESIGN §A.9)
// Readable from any isolation domain: background syncs (observer / BGAppRefreshTask) run before any UI exists and take
// the profile time zone from here. Everything is wiped on logout.

/// A date whose day totals the server kept because the user edited them (`kept_manual`).
struct HealthKeptManualDay: Codable, Sendable, Hashable, Identifiable {
    let date: String
    let fields: [String]
    var id: String { date }
}

/// A synced workout the server thinks duplicates a manual / AI exercise (`possible_duplicates`).
struct HealthDuplicate: Codable, Sendable, Hashable, Identifiable {
    /// HealthKit workout UUID.
    let uuid: String
    /// The manual / AI exercise row (`DELETE /exercises/{id}` removes it).
    let exercise_id: Int
    /// Description of the manual row.
    let manualDescription: String
    /// Date and description of the synced workout (from the uploaded payload).
    let date: String
    let workoutDescription: String
    let durationMin: Double
    var id: String { "\(uuid)#\(exercise_id)" }
}

/// `counts` of `GET /health/sync/state`.
struct HealthServerCounts: Codable, Sendable, Hashable {
    let days: Int
    let body: Int
    let workouts: Int
}

/// Everything the sync screen shows besides `HealthSyncStatus`; persisted between launches.
struct HealthSyncSnapshot: Codable, Sendable, Equatable {
    var lastSyncAt: Date?
    var lastSummary: String?
    var lastError: String?
    var keptManual: [HealthKeptManualDay] = []
    var duplicates: [HealthDuplicate] = []
    var legacyShortcutDays = 0
    var legacyExportDays = 0
    var serverCounts: HealthServerCounts?
    var timezoneMismatch = false
    /// Dates whose sleep is `inBed` time only (no asleep data).
    var approximateSleepDates: [String] = []
    /// Server messages for items it rejected in the last run.
    var rejected: [String] = []
    var serverSupportsSync = true
}

enum HealthSyncSettings {
    static let prefix = "nl.health."
    static let backfillOptions = [30, 90, 365]
    static let defaultBackfillDays = 90

    private static let enabledKey = prefix + "enabled"
    private static let backfillKey = prefix + "backfillDays"
    private static let bpTreatedKey = prefix + "bpTreated"
    private static let timeZoneKey = prefix + "timezone"
    private static let initialDoneKey = prefix + "initialBackfillDone"
    private static let maxDateKey = prefix + "daysMaxDate"
    private static let lastAutoKey = prefix + "lastAutoSyncAt"
    private static let snapshotKey = prefix + "snapshot"

    private static var defaults: UserDefaults { .standard }

    /// `同步苹果健康数据` toggle.
    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Backfill window in days: 30 / 90 / 365 (`30 天` / `90 天` / `一年`), default 90.
    static var backfillDays: Int {
        get {
            let v = defaults.integer(forKey: backfillKey)
            return backfillOptions.contains(v) ? v : defaultBackfillDays
        }
        set { defaults.set(backfillOptions.contains(newValue) ? newValue : defaultBackfillDays, forKey: backfillKey) }
    }

    /// `正在服用降压药`, applied to synced blood pressure readings.
    static var bpTreated: Bool {
        get { defaults.bool(forKey: bpTreatedKey) }
        set { defaults.set(newValue, forKey: bpTreatedKey) }
    }

    /// Profile time zone cached at `onSessionReady()` (background launches have no `me`).
    static var cachedTimeZone: String? {
        get { defaults.string(forKey: timeZoneKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: timeZoneKey) }
    }

    /// The full backfill range has been uploaded once (reset by 重新同步全部, a longer backfill and logout).
    static var initialBackfillDone: Bool {
        get { defaults.bool(forKey: initialDoneKey) }
        set { defaults.set(newValue, forKey: initialDoneKey) }
    }

    /// Latest day date this install uploaded (fallback when `/health/sync/state` is unreachable).
    static var lastDaysMaxDate: String? {
        get { defaults.string(forKey: maxDateKey) }
        set { defaults.set(newValue, forKey: maxDateKey) }
    }

    /// Start of the last automatic (launch / foreground / observer / background) run, for throttling.
    static var lastAutoSyncAt: Date? {
        get { defaults.object(forKey: lastAutoKey) as? Date }
        set { defaults.set(newValue, forKey: lastAutoKey) }
    }

    static func loadSnapshot() -> HealthSyncSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(HealthSyncSnapshot.self, from: data) else { return HealthSyncSnapshot() }
        return snap
    }

    static func saveSnapshot(_ snapshot: HealthSyncSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Any `nl.health.*` key is stored (a signed-in session left state behind; used to spot a restored backup).
    static var hasState: Bool { defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(prefix) } }

    /// Removes every `nl.health.*` key (logout: the next user is different).
    static func wipe() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
