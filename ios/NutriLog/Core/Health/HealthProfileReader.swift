import Foundation
import HealthKit

// MARK: - Onboarding prefill from HealthKit (DESIGN §D row 47, body §12.1 "profile prefill")
// Sex, birth date, height and the latest weight. Every value is optional: iOS never says which reads were denied,
// and characteristics may simply be unset.

struct HealthProfileSnapshot: Sendable, Equatable {
    /// `male` / `female` (other values are left for the user to choose).
    var sex: String?
    /// `YYYY-MM-DD`.
    var birthDate: String?
    /// cm, 0.1 precision.
    var heightCm: Double?
    /// kg, 0.1 precision.
    var weightKg: Double?

    var isEmpty: Bool { sex == nil && birthDate == nil && heightCm == nil && weightKg == nil }

    /// Chinese names of the fields found, e.g. `性别、出生日期、身高、体重`.
    var foundFields: [String] {
        var out: [String] = []
        if sex != nil { out.append("性别") }
        if birthDate != nil { out.append("出生日期") }
        if heightCm != nil { out.append("身高") }
        if weightKg != nil { out.append("体重") }
        return out
    }
}

enum HealthProfileReader {
    /// Asks for read access (first time only) and reads the four values.
    static func read(store: HKHealthStore = HealthKitManager.store) async throws -> HealthProfileSnapshot {
        try await HealthKitManager.requestProfileAuthorization()
        var snap = HealthProfileSnapshot()

        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .male: snap.sex = "male"
            case .female: snap.sex = "female"
            default: break
            }
        }
        if let c = try? store.dateOfBirthComponents(), let y = c.year, let m = c.month, let d = c.day {
            let date = formatDate(y, m, d)
            if LocalDay.isValid(date) { snap.birthDate = date }
        }
        if let h = try await latest(.height, store: store) {
            let cm = HealthRound.value(h.doubleValue(for: HealthTypes.cm), decimals: 1)
            if (80...250).contains(cm) { snap.heightCm = cm }   // PUT /profile accepts 80–250 cm
        }
        if let w = try await latest(.bodyMass, store: store) {
            let kg = HealthTypes.kgValue(w)
            if (20...350).contains(kg) { snap.weightKg = kg }   // PUT /profile accepts 20–350 kg
        }
        return snap
    }

    /// Most recent sample of a quantity type, or nil.
    private static func latest(_ id: HKQuantityTypeIdentifier, store: HKHealthStore) async throws -> HKQuantity? {
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id))],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                                                 limit: 1)
        do {
            return try await descriptor.result(for: store).first?.quantity
        } catch {
            if HealthKitManager.isDatabaseInaccessible(error) { throw error }
            AppLog.health.notice("prefill read \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func formatDate(_ y: Int, _ m: Int, _ d: Int) -> String {
        let ys = String(y)
        let pad: (Int) -> String = { $0 < 10 ? "0\($0)" : String($0) }
        return String(repeating: "0", count: max(0, 4 - ys.count)) + ys + "-" + pad(m) + "-" + pad(d)
    }
}
