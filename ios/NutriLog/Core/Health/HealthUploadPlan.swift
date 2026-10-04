import Foundation

// MARK: - Chunking for `POST /health/sync` (DESIGN §B.5 step 6, server limits §C.2)
// Order: days, then samples, then workouts, then deletions. Each batch remembers which anchor keys it carries objects
// for, so an anchor is committed only once every batch holding its new or deleted objects got a 200.
// Foundation only, so the logic tests can run it on macOS.

/// A value tagged with the anchor key (`HealthSampleKind.rawValue`) whose anchored query produced it.
struct HealthTagged<Value: Sendable>: Sendable {
    let key: String
    let value: Value
}

struct HealthUploadLimits: Sendable, Equatable {
    /// Days per request (server max 400; 90 keeps bodies small).
    var days = 90
    /// Samples + workouts per request.
    var objects = 800
    /// Workouts per request (server max 500).
    var workouts = 500
    /// Deleted UUIDs per request (server max 2000).
    var deleted = 2000
}

struct HealthUploadBatch: Sendable {
    var days: [SyncDay] = []
    var samples: [SyncSample] = []
    var workouts: [SyncWorkout] = []
    var deleted: [String] = []
    /// Anchor keys with objects (added or deleted) in this batch.
    var keys: Set<String> = []

    var isEmpty: Bool { days.isEmpty && samples.isEmpty && workouts.isEmpty && deleted.isEmpty }
    var objectCount: Int { samples.count + workouts.count }
}

struct HealthUploadPlan: Sendable {
    let batches: [HealthUploadBatch]
    /// Number of batches that carry objects of each anchor key.
    let batchesPerKey: [String: Int]

    static func make(days: [SyncDay],
                     samples: [HealthTagged<SyncSample>],
                     workouts: [HealthTagged<SyncWorkout>],
                     deleted: [HealthTagged<String>],
                     limits: HealthUploadLimits = HealthUploadLimits()) -> HealthUploadPlan {
        var batches: [HealthUploadBatch] = []

        // 1. Days
        let sortedDays = days.sorted { $0.date < $1.date }
        var start = 0
        while start < sortedDays.count {
            let end = min(start + max(1, limits.days), sortedDays.count)
            batches.append(HealthUploadBatch(days: Array(sortedDays[start..<end])))
            start = end
        }

        // 2. Samples then workouts, ≤ `objects` per batch and ≤ `workouts` workouts per batch
        var current = HealthUploadBatch()
        func flush() {
            if !current.isEmpty { batches.append(current) }
            current = HealthUploadBatch()
        }
        for s in samples {
            if current.objectCount >= limits.objects { flush() }
            current.samples.append(s.value)
            current.keys.insert(s.key)
        }
        for w in workouts {
            if current.objectCount >= limits.objects || current.workouts.count >= limits.workouts { flush() }
            current.workouts.append(w.value)
            current.keys.insert(w.key)
        }
        flush()

        // 3. Deletions
        for d in deleted {
            if current.deleted.count >= limits.deleted { flush() }
            current.deleted.append(d.value)
            current.keys.insert(d.key)
        }
        flush()

        var perKey: [String: Int] = [:]
        for b in batches { for k in b.keys { perKey[k, default: 0] += 1 } }
        return HealthUploadPlan(batches: batches, batchesPerKey: perKey)
    }
}
