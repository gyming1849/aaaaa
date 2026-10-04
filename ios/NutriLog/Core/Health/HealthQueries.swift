import Foundation
import HealthKit

// MARK: - HealthKit reads (DESIGN §B.5 steps 2–5, body §12.1–§12.4)
// Every function is a nonisolated static async function: HealthKit query results (not all Sendable) are converted into
// Sendable values before they leave, so the `HealthSyncEngine` actor only ever sees plain data.
// Day keys always use the profile time zone, never the device's (body §12.3).

/// New and deleted objects of one anchored query plus the anchor to commit once the server accepted them.
struct HealthAnchoredBatch<Value: Sendable>: Sendable {
    let added: [Value]
    /// UUID strings of `deletedObjects`.
    let deleted: [String]
    let newAnchor: HKQueryAnchor
}

/// One `HKWorkout`, reduced to what `SyncWorkout` needs (in_device is decided later from the day's active energy).
struct HealthWorkoutRecord: Sendable, Equatable {
    let uuid: String
    let date: String
    let time: String
    let start: String
    let end: String
    let facts: WorkoutFacts
    /// km, 0.01 precision (≤ 1000).
    let distanceKm: Double?
    /// beats/min, rounded (30…230).
    let avgHR: Double?
    /// Active energy recorded with the workout, kcal 0.1 (≤ 10000).
    let deviceKcal: Double?
    let sourceName: String?
}

enum HealthQueries {
    /// `[start 00:00, end + 1 00:00)` in `timeZone`.
    static func dayInterval(start: String, end: String, timeZone: TimeZone) -> DateInterval? {
        guard let from = LocalDay.date(fromKey: start, in: timeZone),
              let to = LocalDay.date(fromKey: LocalDay.addDays(end, 1), in: timeZone), to > from else { return nil }
        return DateInterval(start: from, end: to)
    }

    // MARK: Day totals

    /// Daily cumulative sums (`HKStatisticsCollectionQueryDescriptor`, `.cumulativeSum`) keyed by profile-time-zone day.
    /// HealthKit merges iPhone + Watch by source priority; raw samples are never summed. A day without samples is absent
    /// (→ nil, never 0).
    /// HealthKit steps its intervals with the device calendar, so one-day buckets anchored at profile midnight stay on
    /// profile midnights only while the offset between the two zones is constant over the range. When it is not (a DST
    /// change in one zone only, e.g. profile Europe/London on a phone set to Asia/Shanghai), hourly buckets anchored at a
    /// profile midnight are added up by profile-zone day instead (hour edges line up with every profile midnight, also for
    /// 30/45-minute offsets).
    static func dailySums(_ field: HealthDayField, start: String, end: String, timeZone: TimeZone, store: HKHealthStore) async throws -> [String: Double] {
        guard let type = field.cumulativeType, let unit = field.unit,
              let span = dayInterval(start: start, end: end, timeZone: timeZone) else { return [:] }
        let aligned = HealthSyncText.zonesStayAligned(start: start, end: end, timeZone: timeZone, device: .current)
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: []))
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: predicate, options: .cumulativeSum, anchorDate: span.start,
                                                               intervalComponents: aligned ? DateComponents(day: 1) : DateComponents(hour: 1))
        let collection: HKStatisticsCollection
        do {
            collection = try await descriptor.result(for: store)
        } catch let error where HealthKitManager.isNoData(error) {
            return [:]
        }
        var out: [String: Double] = [:]
        for stat in collection.statistics() {
            guard let sum = stat.sumQuantity() else { continue }
            let key: String
            if aligned {
                // Daily buckets start at profile midnights; the midpoint picks the day robustly.
                let mid = stat.startDate.addingTimeInterval(stat.endDate.timeIntervalSince(stat.startDate) / 2)
                key = LocalDay.key(for: mid, in: timeZone)
            } else {
                key = LocalDay.key(for: stat.startDate, in: timeZone)
            }
            guard key >= start, key <= end else { continue }
            out[key, default: 0] += sum.doubleValue(for: unit)
        }
        return out
    }


    /// The day's total of one cumulative field (`HKStatisticsQueryDescriptor`), nil without samples.
    static func dayTotal(_ field: HealthDayField, date: String, timeZone: TimeZone, store: HKHealthStore) async throws -> Double? {
        guard let type = field.cumulativeType, let unit = field.unit,
              let span = dayInterval(start: date, end: date, timeZone: timeZone) else { return nil }
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: []))
        do {
            let stats = try await HKStatisticsQueryDescriptor(predicate: predicate, options: .cumulativeSum).result(for: store)
            return stats?.sumQuantity()?.doubleValue(for: unit)
        } catch let error where HealthKitManager.isNoData(error) {
            // A workout on a day without active-energy samples (e.g. a third-party app's workout).
            return nil
        }
    }

    /// Stand hours per day: `appleStandHour` samples whose value is `.stood`, one per clock hour.
    static func standHours(start: String, end: String, timeZone: TimeZone, store: HKHealthStore) async throws -> [String: Double] {
        guard let span = dayInterval(start: start, end: end, timeZone: timeZone) else { return [:] }
        let predicate = HKSamplePredicate.categorySample(type: HKCategoryType(.appleStandHour),
                                                         predicate: HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: .strictStartDate))
        let samples = try await HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: []).result(for: store)
        var hours: [String: Set<Int>] = [:]
        for s in samples where s.value == HKCategoryValueAppleStandHour.stood.rawValue {
            let key = LocalDay.key(for: s.startDate, in: timeZone)
            hours[key, default: []].insert(Int((s.startDate.timeIntervalSince1970 / 3600).rounded(.down)))
        }
        return hours.mapValues { Double(min($0.count, 24)) }
    }

    /// Sleep samples overlapping every night window of `dates` (see `SleepAggregator`).
    static func sleepSegments(dates: [String], timeZone: TimeZone, store: HKHealthStore) async throws -> [SleepSegment] {
        guard let span = SleepAggregator.querySpan(dates: dates, in: timeZone) else { return [] }
        let predicate = HKSamplePredicate.categorySample(type: HKCategoryType(.sleepAnalysis),
                                                         predicate: HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: []))
        let samples = try await HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: []).result(for: store)
        return samples.map { SleepSegment(start: $0.startDate, end: $0.endDate, value: $0.value, isWatch: isWatch($0)) }
    }

    // MARK: Anchored samples

    /// Weight, body fat, waist or blood pressure added/deleted since `anchor`, limited to samples starting at `since`.
    static func anchoredBodySamples(_ kind: HealthSampleKind, anchor: HKQueryAnchor?, since: Date, timeZone: TimeZone,
                                    bpTreated: Bool, store: HKHealthStore) async throws -> HealthAnchoredBatch<SyncSample> {
        let datePredicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let quantityType: HKQuantityType
        switch kind {
        case .bloodPressure:
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.correlation(type: HKCorrelationType(.bloodPressure), predicate: datePredicate)], anchor: anchor)
            let result = try await descriptor.result(for: store)
            return HealthAnchoredBatch(added: result.addedSamples.compactMap { bloodPressure($0, timeZone: timeZone, bpTreated: bpTreated) },
                                       deleted: result.deletedObjects.map { $0.uuid.uuidString },
                                       newAnchor: result.newAnchor)
        case .bodyMass: quantityType = HKQuantityType(.bodyMass)
        case .bodyFat: quantityType = HKQuantityType(.bodyFatPercentage)
        case .waist: quantityType = HKQuantityType(.waistCircumference)
        case .workout:
            throw HealthSyncFailure.healthKit("unsupported sample kind")
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: quantityType, predicate: datePredicate)], anchor: anchor)
        let result = try await descriptor.result(for: store)
        return HealthAnchoredBatch(added: result.addedSamples.compactMap { quantity($0, kind: kind, timeZone: timeZone) },
                                   deleted: result.deletedObjects.map { $0.uuid.uuidString },
                                   newAnchor: result.newAnchor)
    }

    /// Workouts added/deleted since `anchor`, limited to workouts starting at `since`.
    static func anchoredWorkouts(anchor: HKQueryAnchor?, since: Date, timeZone: TimeZone, store: HKHealthStore) async throws -> HealthAnchoredBatch<HealthWorkoutRecord> {
        let datePredicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout(datePredicate)], anchor: anchor)
        let result = try await descriptor.result(for: store)
        return HealthAnchoredBatch(added: result.addedSamples.compactMap { workout($0, timeZone: timeZone) },
                                   deleted: result.deletedObjects.map { $0.uuid.uuidString },
                                   newAnchor: result.newAnchor)
    }

    // MARK: Conversions

    /// Samples written by this app itself are never synced back (echo filter, body §12.1).
    static func isEcho(_ s: HKObject) -> Bool {
        guard let own = Bundle.main.bundleIdentifier else { return false }
        return s.sourceRevision.source.bundleIdentifier == own
    }

    static func isWatch(_ s: HKObject) -> Bool { s.sourceRevision.productType?.hasPrefix("Watch") ?? false }

    private static func sourceName(_ s: HKObject) -> String? { HealthSyncText.truncate(s.sourceRevision.source.name, max: 60) }

    private static func quantity(_ s: HKQuantitySample, kind: HealthSampleKind, timeZone: TimeZone) -> SyncSample? {
        guard !isEcho(s), let type = kind.syncType else { return nil }
        let value: Double
        switch kind {
        case .bodyMass: value = HealthTypes.kgValue(s.quantity)
        case .bodyFat: value = HealthTypes.percentValue(s.quantity)
        case .waist: value = HealthTypes.cmValue(s.quantity)
        case .bloodPressure, .workout: return nil
        }
        guard value.isFinite else { return nil }
        return SyncSample(uuid: s.uuid.uuidString, type: type, date: LocalDay.key(for: s.startDate, in: timeZone),
                          time: LocalDay.hhmm(s.startDate, in: timeZone), start: HealthSyncText.isoTimestamp(s.startDate, in: timeZone),
                          value: value, source_name: sourceName(s))
    }

    /// One reading per correlation; both systolic and diastolic are required (body §13.9).
    private static func bloodPressure(_ c: HKCorrelation, timeZone: TimeZone, bpTreated: Bool) -> SyncSample? {
        guard !isEcho(c),
              let sys = c.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample,
              let dia = c.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample else { return nil }
        let sbp = HealthTypes.mmHgValue(sys.quantity), dbp = HealthTypes.mmHgValue(dia.quantity)
        guard sbp.isFinite, dbp.isFinite else { return nil }
        return SyncSample(uuid: c.uuid.uuidString, type: .blood_pressure, date: LocalDay.key(for: c.startDate, in: timeZone),
                          time: LocalDay.hhmm(c.startDate, in: timeZone), start: HealthSyncText.isoTimestamp(c.startDate, in: timeZone),
                          sbp: sbp, dbp: dbp, bp_treated: bpTreated, source_name: sourceName(c))
    }

    private static func workout(_ w: HKWorkout, timeZone: TimeZone) -> HealthWorkoutRecord? {
        guard !isEcho(w) else { return nil }
        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        let distance = distanceTypes.lazy
            .compactMap { w.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: HealthTypes.km) }
            .first { $0 > 0 }
            .map { HealthRound.value($0, decimals: 2) }
        let hrValue = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HealthTypes.bpm)
        let hr = hrValue.map { HealthRound.value($0, decimals: 0) }
        let kcalValue = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let kcal = kcalValue.map { HealthRound.value($0, decimals: 1) }
        let metadata = w.metadata ?? [:]
        let mets = (metadata[HKMetadataKeyAverageMETs] as? HKQuantity).flatMap { HealthTypes.value($0, in: HealthTypes.mets) }
        let indoor = (metadata[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue ?? false
        let swim = (metadata[HKMetadataKeySwimmingLocationType] as? NSNumber).flatMap { HKWorkoutSwimmingLocationType(rawValue: $0.intValue) }
        let facts = WorkoutFacts(activityType: w.workoutActivityType, durationSeconds: w.duration, distanceKm: distance,
                                 indoor: indoor, swimmingLocation: swim, averageMETs: mets)
        return HealthWorkoutRecord(
            uuid: w.uuid.uuidString,
            date: LocalDay.key(for: w.startDate, in: timeZone),
            time: LocalDay.hhmm(w.startDate, in: timeZone),
            start: HealthSyncText.isoTimestamp(w.startDate, in: timeZone),
            end: HealthSyncText.isoTimestamp(w.endDate, in: timeZone),
            facts: facts,
            distanceKm: distance.flatMap { $0 <= 1000 ? $0 : nil },
            avgHR: hr.flatMap { (30...230).contains($0) ? $0 : nil },
            deviceKcal: kcal.flatMap { (0...10_000).contains($0) ? $0 : nil },
            sourceName: sourceName(w))
    }
}
