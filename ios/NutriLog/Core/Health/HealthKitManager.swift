import Foundation
import HealthKit

// MARK: - HealthKit availability, authorization and the shared store (DESIGN §B.5)

enum HealthKitManager {
    /// One store for the whole app (`HKHealthStore` is Sendable).
    static let store = HKHealthStore()

    /// False on devices without HealthKit (iPad without Health, some managed devices).
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// The read-only set requested for sync (DESIGN §B.5 "Read set").
    static var readTypes: Set<HKObjectType> { HealthTypes.syncReadTypes }

    /// Read-only authorization for sync. iOS shows the sheet only for types not asked before and never reveals denials.
    static func requestSyncAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Read-only authorization for the onboarding prefill.
    static func requestProfileAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: HealthTypes.profileReadTypes)
    }

    /// The protected store is unreadable while the device is locked.
    static func isDatabaseInaccessible(_ error: Error) -> Bool {
        if let e = error as? HKError { return e.code == .errorDatabaseInaccessible }
        let ns = error as NSError
        return ns.domain == HKErrorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    /// `HKError.errorNoData`: a statistics query matched no samples. It means "no data" (nil), never a failed sync.
    static func isNoData(_ error: Error) -> Bool {
        if let e = error as? HKError { return e.code == .errorNoData }
        let ns = error as NSError
        return ns.domain == HKErrorDomain && ns.code == HKError.Code.errorNoData.rawValue
    }

    /// Readable message for a HealthKit failure.
    static func message(for error: Error) -> String {
        if isDatabaseInaccessible(error) { return HealthSyncText.deviceLocked }
        if let e = error as? HKError {
            switch e.code {
            case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorRequiredAuthorizationDenied:
                return "没有读取健康数据的权限。" + HealthSyncText.permissionHint
            case .errorHealthDataUnavailable, .errorHealthDataRestricted:
                return HealthSyncText.unavailable
            default: break
            }
        }
        return "读取健康数据失败：\(error.localizedDescription)"
    }
}
