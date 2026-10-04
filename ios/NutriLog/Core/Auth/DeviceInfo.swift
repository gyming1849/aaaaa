import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Device identity (auth §3.2–§3.3, DESIGN §C.2)

/// `device_name` sent on login/register/health sync, and the install id used as the HealthKit `device_id`.
/// Both are readable from any isolation domain (background sync runs off the main actor): the name is captured once on
/// the main actor at launch (`prime()`) into UserDefaults, because `UIDevice` is main-actor isolated.
enum DeviceInfo {
    static let nameKey = "nl.deviceName"
    static let installIdKey = "nl.installId"
    static let appSuffix = " · 食迹 iOS"

    /// `"{UIDevice.name} · 食迹 iOS"`, at most 60 characters (the server truncates at 60).
    static var deviceName: String {
        let base = UserDefaults.standard.string(forKey: nameKey).flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
        return compose(base)
    }

    /// Random UUID created on first use and kept across logins (it identifies this installation, not the user).
    static var installId: String {
        if let id = UserDefaults.standard.string(forKey: installIdKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: installIdKey)
        return id
    }

    /// Records the device name and creates the install id. Call once at launch on the main actor.
    @MainActor static func prime() {
        #if canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, UserDefaults.standard.string(forKey: nameKey) != name {
            UserDefaults.standard.set(name, forKey: nameKey)
        }
        #endif
        _ = installId
    }

    static func compose(_ base: String) -> String {
        let maxBase = 60 - appSuffix.count
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxBase)) + appSuffix
    }
}
