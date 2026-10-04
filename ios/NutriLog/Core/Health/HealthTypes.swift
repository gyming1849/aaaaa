import Foundation
import HealthKit

// MARK: - HealthKit type ↔ server field table, units and rounding (body §12.1–§12.2, DESIGN §B.5)

/// Sample streams read with anchored queries. The raw value is both the anchor key and (for samples) the server `type`.
enum HealthSampleKind: String, CaseIterable, Sendable {
    case bodyMass = "body_mass"
    case bodyFat = "body_fat"
    case waist
    case bloodPressure = "blood_pressure"
    case workout

    static let bodyKinds: [HealthSampleKind] = [.bodyMass, .bodyFat, .waist, .bloodPressure]

    var anchorKey: String { rawValue }

    var syncType: SyncSampleType? {
        switch self {
        case .bodyMass: .body_mass
        case .bodyFat: .body_fat
        case .waist: .waist
        case .bloodPressure: .blood_pressure
        case .workout: nil
        }
    }

    /// The HealthKit type queried for this stream.
    var sampleType: HKSampleType {
        switch self {
        case .bodyMass: HKQuantityType(.bodyMass)
        case .bodyFat: HKQuantityType(.bodyFatPercentage)
        case .waist: HKQuantityType(.waistCircumference)
        case .bloodPressure: HKCorrelationType(.bloodPressure)
        case .workout: HKObjectType.workoutType()
        }
    }
}

extension HealthDayField {
    /// Cumulative quantity type read with a daily statistics collection (stand hours and sleep are category samples).
    var cumulativeType: HKQuantityType? {
        switch self {
        case .steps: HKQuantityType(.stepCount)
        case .active_kcal: HKQuantityType(.activeEnergyBurned)
        case .resting_kcal: HKQuantityType(.basalEnergyBurned)
        case .distance_km: HKQuantityType(.distanceWalkingRunning)
        case .exercise_min: HKQuantityType(.appleExerciseTime)
        case .stand_hours, .sleep_hours: nil
        }
    }

    /// Unit sent to the server.
    var unit: HKUnit? {
        switch self {
        case .steps: .count()
        case .active_kcal, .resting_kcal: .kilocalorie()
        case .distance_km: HealthTypes.km
        case .exercise_min: .minute()
        case .stand_hours, .sleep_hours: nil
        }
    }

    /// Fields read with `HKStatisticsCollectionQueryDescriptor(.cumulativeSum)`.
    static let cumulativeFields: [HealthDayField] = [.steps, .active_kcal, .resting_kcal, .distance_km, .exercise_min]
}

enum HealthTypes {
    static let km = HKUnit.meterUnit(with: .kilo)
    static let cm = HKUnit.meterUnit(with: .centi)
    static let kg = HKUnit.gramUnit(with: .kilo)
    static let mmHg = HKUnit.millimeterOfMercury()
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    /// `HKMetadataKeyAverageMETs` unit, kcal/(hr·kg) (built, not parsed: a bad unit string raises an ObjC exception).
    static let mets = HKUnit.kilocalorie().unitDivided(by: HKUnit.hour().unitMultiplied(by: .gramUnit(with: .kilo)))

    /// `q` in `unit`, or nil when the units are incompatible (`doubleValue(for:)` would raise an ObjC exception).
    /// Used for metadata written by third-party apps, whose units HealthKit does not enforce.
    static func value(_ q: HKQuantity, in unit: HKUnit) -> Double? {
        q.is(compatibleWith: unit) ? q.doubleValue(for: unit) : nil
    }

    /// Read-only set requested for sync (DESIGN §B.5 "Read set"); nothing is ever written (`toShare: []`). Only what the
    /// sync engine reads: sex, birth date and height are requested by the prefill alone (`profileReadTypes`).
    static let syncReadTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming),
        HKQuantityType(.appleExerciseTime), HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage),
        HKQuantityType(.waistCircumference), HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic),
        HKQuantityType(.heartRate),
        HKCategoryType(.sleepAnalysis), HKCategoryType(.appleStandHour),
        HKObjectType.workoutType(),
    ]

    /// Onboarding prefill (sex, birth date, height, latest weight), requested when 从“健康”App 读取 is tapped.
    static let profileReadTypes: Set<HKObjectType> = [
        HKCharacteristicType(.biologicalSex), HKCharacteristicType(.dateOfBirth),
        HKQuantityType(.height), HKQuantityType(.bodyMass),
    ]

    /// Rows of `读取的数据` on the sync screen.
    static let readList: [(name: String, symbol: String)] = [
        ("步数", "figure.walk"),
        ("活动能量、静息能量", "flame"),
        ("步行+跑步距离", "point.topleft.down.to.point.bottomright.curvepath"),
        ("锻炼分钟、站立小时", "figure.stand"),
        ("睡眠", "bed.double"),
        ("体重、体脂率、腰围", "scalemass"),
        ("血压", "heart"),
        ("体能训练（时长、距离、平均心率、消耗）", "figure.run"),
    ]

    /// Values in the units and precision of body §12.2.
    static func kgValue(_ q: HKQuantity) -> Double { HealthRound.value(q.doubleValue(for: kg), decimals: 1) }
    static func percentValue(_ q: HKQuantity) -> Double { HealthRound.value(q.doubleValue(for: .percent()) * 100, decimals: 1) }
    static func cmValue(_ q: HKQuantity) -> Double { HealthRound.value(q.doubleValue(for: cm), decimals: 1) }
    static func mmHgValue(_ q: HKQuantity) -> Double { HealthRound.value(q.doubleValue(for: mmHg), decimals: 0) }
}
