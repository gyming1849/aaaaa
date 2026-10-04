import Foundation

/// Small JSON documents under `Application Support/NutriLog/cache/` (§A.9): `meta.json` (standards meta, reused while
/// its `version` matches) and `me.json` (last `Me`; gives background sync the profile time zone).
/// Files use the default data protection (readable after first unlock). Wiped on logout via `removeAll()`.
enum DiskCache {
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let dir = directory else { return nil }
        return load(key, as: type, in: dir)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let dir = directory else { return }
        save(value, key: key, in: dir)
    }

    static func remove(_ key: String) {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: fileURL(key, in: dir))
    }

    static func removeAll() {
        guard let dir = directory else { return }
        removeAll(in: dir)
    }

    /// `Application Support/NutriLog/cache`, or nil if Application Support is unavailable.
    static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return base.appendingPathComponent("NutriLog", isDirectory: true).appendingPathComponent("cache", isDirectory: true)
    }

    // MARK: Directory-explicit variants (used by the above and by logic tests)

    static func load<T: Decodable>(_ key: String, as type: T.Type, in dir: URL) -> T? {
        let url = fileURL(key, in: dir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A stale or incompatible file is useless: drop it so the next save starts clean.
            AppLog.app.error("DiskCache: discarding unreadable \(key, privacy: .public).json: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, key: String, in dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL(key, in: dir), options: [.atomic])
        } catch {
            AppLog.app.error("DiskCache: cannot write \(key, privacy: .public).json: \(String(describing: error), privacy: .public)")
        }
    }

    static func removeAll(in dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `<dir>/<key>.json`, with any character outside `[A-Za-z0-9._-]` replaced by `_`.
    static func fileURL(_ key: String, in dir: URL) -> URL {
        let safe = String(key.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return Character(scalar)
            default: return "_"
            }
        })
        let name = safe.isEmpty || safe.hasPrefix(".") ? "_" + safe : safe
        return dir.appendingPathComponent(name + ".json", isDirectory: false)
    }
}
