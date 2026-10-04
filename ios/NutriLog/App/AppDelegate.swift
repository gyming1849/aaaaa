import UIKit

// MARK: - App delegate (DESIGN §A.7)

/// Registers the background-refresh task and HealthKit observers before launch finishes, which `BGTaskScheduler` requires.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DeviceInfo.prime()
        HealthSyncService.registerBackgroundTasks()
        HealthSyncService.startObserversIfEnabled()
        return true
    }
}
