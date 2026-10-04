import Foundation

// MARK: - Photo bytes (meals §2.2: authenticated GET, owner only)

/// In-memory LRU cache of uploaded photo bytes (~50 MB). Fetches `GET api/v1/uploads/{id}` with the Bearer header,
/// coalesces concurrent requests for the same id and remembers 404s so missing photos are not refetched.
/// Wiped on logout (`AppState`), because ids are per user.
actor PhotoCache {
    static let shared = PhotoCache()

    private let capacity: Int
    private var entries: [String: Data] = [:]
    private var order: [String] = []                       // least recently used first
    private var totalBytes = 0
    private var missing: Set<String> = []
    private var inflight: [String: Task<Data, Error>] = [:]
    private var generation = 0

    init(capacityBytes: Int = 50 * 1024 * 1024) { capacity = capacityBytes }

    func data(for photoId: String, api: APIClient) async throws -> Data {
        if let hit = entries[photoId] { touch(photoId); return hit }
        if missing.contains(photoId) { throw APIError.http(status: 404, message: "不存在") }
        if let running = inflight[photoId] { return try await running.value }

        let task = Task { try await api.photoData(id: photoId) }
        inflight[photoId] = task
        let startedIn = generation
        do {
            let data = try await task.value
            inflight[photoId] = nil
            if startedIn == generation { insert(data, for: photoId) }
            return data
        } catch {
            inflight[photoId] = nil
            if startedIn == generation, case APIError.http(404, _) = error { missing.insert(photoId) }
            throw error
        }
    }

    /// Seeds the cache with bytes we already have (freshly uploaded JPEGs), so thumbnails need no round trip.
    func store(_ data: Data, for photoId: String) {
        missing.remove(photoId)
        insert(data, for: photoId)
    }

    func clear() {
        generation += 1
        for task in inflight.values { task.cancel() }
        inflight = [:]
        entries = [:]; order = []; totalBytes = 0; missing = []
    }

    // MARK: LRU

    private func touch(_ id: String) {
        if let i = order.firstIndex(of: id) { order.remove(at: i) }
        order.append(id)
    }

    private func insert(_ data: Data, for id: String) {
        guard data.count <= capacity else { return }
        if let old = entries[id] { totalBytes -= old.count }
        entries[id] = data
        totalBytes += data.count
        touch(id)
        while totalBytes > capacity, let oldest = order.first {
            order.removeFirst()
            if let d = entries.removeValue(forKey: oldest) { totalBytes -= d.count }
        }
    }
}
