import Foundation
import HealthKit
import BackgroundTasks
import UIKit

// MARK: - Background sync triggers (DESIGN §A.7, §B.5 "Background")
// • One `HKObserverQuery` per type in {steps, active energy, sleep, body mass, body fat, systolic BP, workouts} plus
//   `enableBackgroundDelivery` (hourly for steps/energy/sleep, immediate for the rest). Each callback runs a sync and
//   calls HealthKit's completion handler when that sync finishes or after 20 s, whichever comes first (three missed
//   completions make HealthKit stop background delivery).
// • `BGAppRefreshTask` `com.nutrilog.ios.healthsync.refresh` as the periodic fallback (earliest +4 h, rescheduled after
//   every sync, cancelled on expiration).
// • Every sync loop holds a `UIApplication` background task (`BackgroundAssertion`); when its time runs out the loop is
//   cancelled (anchors stay uncommitted, so the next run re-reads anything that was not uploaded).

@MainActor final class HealthBackground {
    nonisolated static let refreshTaskIdentifier = "com.nutrilog.ios.healthsync.refresh"
    /// Earliest start of the next background refresh.
    nonisolated static let refreshInterval: TimeInterval = 4 * 60 * 60
    /// HealthKit's observer completion is called at the latest this long after the callback (below the ~30 s a
    /// background task gets).
    nonisolated static let observerAckCap: TimeInterval = 20

    private struct Observed {
        let type: HKSampleType
        let frequency: HKUpdateFrequency
        /// Weight, BP and workouts bypass the 10-minute observer throttle.
        let urgent: Bool
    }

    private static let observed: [Observed] = [
        Observed(type: HKQuantityType(.stepCount), frequency: .hourly, urgent: false),
        Observed(type: HKQuantityType(.activeEnergyBurned), frequency: .hourly, urgent: false),
        Observed(type: HKCategoryType(.sleepAnalysis), frequency: .hourly, urgent: false),
        Observed(type: HKQuantityType(.bodyMass), frequency: .immediate, urgent: true),
        Observed(type: HKQuantityType(.bodyFatPercentage), frequency: .immediate, urgent: true),
        Observed(type: HKQuantityType(.bloodPressureSystolic), frequency: .immediate, urgent: true),
        Observed(type: HKObjectType.workoutType(), frequency: .immediate, urgent: true),
    ]

    private let store: HKHealthStore
    private var queries: [HKObserverQuery] = []
    /// Enable/disable background delivery calls run in order (a quick off → on must end enabled).
    private var deliveryChain: Task<Void, Never>?

    init(store: HKHealthStore = HealthKitManager.store) { self.store = store }

    var isObserving: Bool { !queries.isEmpty }

    /// Idempotent. Runs at launch (before `didFinishLaunching` returns) and when sync is switched on.
    func startObservers() {
        guard queries.isEmpty, HealthKitManager.isAvailable else { return }
        for item in Self.observed {
            let urgent = item.urgent
            let query = HKObserverQuery(sampleType: item.type, predicate: nil) { _, completion, error in
                let done = UncheckedSendable(completion)
                if let error {
                    AppLog.health.notice("observer error: \(String(describing: error), privacy: .public)")
                    done.value()
                    return
                }
                Task { @MainActor in
                    // Acknowledge when the sync finishes or after `observerAckCap`, whichever is first: the loop may
                    // still be uploading unrelated queued work (a long backfill). Acknowledging early loses nothing —
                    // anchors are committed only after the server accepted the data, so the next run re-reads the rest.
                    let ack = ObserverAck(done)
                    let cap = Task { @MainActor in
                        guard (try? await Task.sleep(for: .seconds(HealthBackground.observerAckCap))) != nil else { return }
                        ack.fire()
                    }
                    await HealthSyncService.current?.observerFired(urgent: urgent)
                    cap.cancel()
                    ack.fire()
                }
            }
            store.execute(query)
            queries.append(query)
        }
        let store = self.store
        let items = Self.observed.map { ($0.type, $0.frequency) }
        enqueueDelivery {
            for (type, frequency) in items {
                do {
                    try await store.enableBackgroundDelivery(for: type, frequency: frequency)
                } catch {
                    AppLog.health.notice("enableBackgroundDelivery(\(type.identifier, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Sync switched off, unlinked or logged out.
    func stopObservers() {
        for q in queries { store.stop(q) }
        queries.removeAll()
        let store = self.store
        enqueueDelivery {
            do { try await store.disableAllBackgroundDelivery() } catch {
                AppLog.health.notice("disableAllBackgroundDelivery failed: \(String(describing: error), privacy: .public)")
            }
        }
        Self.cancelRefresh()
    }

    private func enqueueDelivery(_ operation: @escaping @Sendable () async -> Void) {
        let previous = deliveryChain
        deliveryChain = Task {
            await previous?.value
            await operation()
        }
    }

    // MARK: BGAppRefreshTask

    /// Must run before launch finishes (`AppDelegate`).
    nonisolated static func registerRefreshTask() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            let box = UncheckedSendable(task)
            let work = Task { @MainActor in
                await HealthSyncService.current?.syncNow(reason: .backgroundRefresh)
                HealthBackground.scheduleRefresh()
                box.value.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
        if !ok { AppLog.health.error("BGTaskScheduler.register failed for \(refreshTaskIdentifier, privacy: .public)") }
    }

    /// (Re)schedules the periodic refresh while sync is enabled.
    nonisolated static func scheduleRefresh() {
        guard HealthSyncSettings.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator and devices with Background App Refresh off end up here; observers still work.
            AppLog.health.notice("BGAppRefreshTask not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func cancelRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
    }
}

// MARK: - Helpers

/// Calls an `HKObserverQuery` completion handler at most once.
@MainActor final class ObserverAck {
    private var completion: UncheckedSendable<() -> Void>?

    init(_ completion: UncheckedSendable<() -> Void>) { self.completion = completion }

    func fire() {
        guard let completion else { return }
        self.completion = nil
        completion.value()
    }
}

/// Keeps the process running while a sync loop uploads after the app went to the background (or was woken in it).
/// `onExpire` runs when the system's time is up; the assertion then ends itself.
@MainActor final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, onExpire: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            onExpire()
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
