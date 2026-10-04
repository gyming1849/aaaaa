import Foundation
import HealthKit

// MARK: - HealthKit anchors and the sent-days ledger (DESIGN §A.9, §B.5)
// Files under `Application Support/NutriLog/health/` (excluded from backups):
//   anchors.json    { "<kind>": <NSKeyedArchiver data of HKQueryAnchor> }
//   sent-days.json  SentDaysLedger
// An anchor is committed only after the server answered 200 for every batch holding that stream's objects.
// `reset()` and `resetAnchors(_:)` bump the epoch, so a sync that is still running cannot write stale state back.

actor AnchorStore {
    static let shared = AnchorStore()

    private var epoch = 0
    private var anchors: [String: Data]?
    private var cachedLedger: SentDaysLedger?

    init() {}

    /// Captured by a run at its start and passed back to every write.
    func currentEpoch() -> Int { epoch }

    // MARK: Anchors

    func anchor(for kind: HealthSampleKind) -> HKQueryAnchor? {
        guard let data = loadAnchors()[kind.anchorKey] else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            AppLog.health.error("anchor \(kind.anchorKey, privacy: .public) unreadable, starting over")
            return nil
        }
    }

    func commit(_ anchor: HKQueryAnchor, for kind: HealthSampleKind, epoch: Int) {
        guard epoch == self.epoch else { return }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        var all = loadAnchors()
        all[kind.anchorKey] = data
        anchors = all
        write(all, to: "anchors.json")
    }

    /// Forgets the anchors of `kinds` (their samples are read and re-sent from the start of the backfill window).
    /// Bumps the epoch too: a run that started before the reset must not commit anchors read with the old ones.
    func resetAnchors(_ kinds: [HealthSampleKind]) {
        epoch += 1
        var all = loadAnchors()
        for k in kinds { all[k.anchorKey] = nil }
        anchors = all
        write(all, to: "anchors.json")
    }

    // MARK: Ledger

    func ledger() -> SentDaysLedger {
        if let cachedLedger { return cachedLedger }
        let loaded: SentDaysLedger = read("sent-days.json") ?? SentDaysLedger()
        cachedLedger = loaded
        return loaded
    }

    func saveLedger(_ ledger: SentDaysLedger, epoch: Int) {
        guard epoch == self.epoch else { return }
        cachedLedger = ledger
        write(ledger, to: "sent-days.json")
    }

    // MARK: Reset

    /// 重新同步全部 / logout / unlink: removes every anchor and the ledger.
    func reset() {
        epoch += 1
        anchors = [:]
        cachedLedger = SentDaysLedger()
        if let dir = directory { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Files

    private var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return base.appendingPathComponent("NutriLog", isDirectory: true).appendingPathComponent("health", isDirectory: true)
    }

    private func loadAnchors() -> [String: Data] {
        if let anchors { return anchors }
        let loaded: [String: Data] = read("anchors.json") ?? [:]
        anchors = loaded
        return loaded
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        guard let dir = directory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Anchors only make sense for the HealthKit store that issued them: keep them out of iCloud / Finder backups
            // (a restored device must start over). Set after every create, because `reset()` deletes the directory.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = dir
            try? excluded.setResourceValues(values)
            try JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: [.atomic])
        } catch {
            AppLog.health.error("cannot write \(name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
