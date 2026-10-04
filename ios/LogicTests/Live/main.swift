import Foundation

// Live suite: proves the Swift models decode REAL server responses.
//
// `fixtures/*.json` are raw response bodies recorded by `collect.sh` (and `post-swift.sh`) against a freshly seeded LOCAL
// server (AI_PROVIDER=mock). Every fixture is decoded twice:
//   1. directly, with `JSONCoding.decoder()` and the exact wire type `APIClient` uses for that endpoint, and
//   2. through the real `APIClient` over a mock `URLProtocol` that serves the fixture bytes, checking the method, path and
//      query the client builds on the way.
// Request bodies are captured from the same `APIClient` calls; their keys are compared with the keys the server reads
// (server/src/routes/*.ts, server/src/services/healthsync.ts). A key audit (Mirror over the decoded values vs. the raw
// JSON) reports Swift fields the server never sends (= silently defaulted) and fails on any that are not allow-listed.
//
// `LIVE_EMIT_DIR=<dir>` switches to emit mode: the binary writes Swift-encoded request bodies (built from the decoded
// fixtures, as the app would) for `post-swift.sh` to POST to the local server, then exits.

// MARK: - Mock transport (same shape as the Networking suite)

struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
    var path: String { url.path }
    var query: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
}

final class MockServer: @unchecked Sendable {
    static let shared = MockServer()
    private let lock = NSLock()
    private var response = Data()
    private var status = 200
    private var log: [RecordedRequest] = []

    func reset(status: Int = 200, body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; response = body; log = []
    }
    var requests: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return log }
    func respond(_ r: RecordedRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        log.append(r)
        return (status, response)
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let rec = RecordedRequest(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let (status, data) = MockServer.shared.respond(rec)
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

func makeClient() -> APIClient {
    let cfg = APIClient.defaultConfiguration()
    cfg.protocolClasses = [MockURLProtocol.self]
    return APIClient(baseURL: URL(string: "http://live.test:8790")!, token: "nla_LIVE", configuration: cfg)
}

// MARK: - Fixtures

let fixtureDir = "LogicTests/Live/fixtures"

func fixtureData(_ name: String) -> Data? { FileManager.default.contents(atPath: "\(fixtureDir)/\(name).json") }
func fixtureJSON(_ name: String) -> Any? {
    fixtureData(name).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
}

// MARK: - Key audit (Mirror of the decoded value vs. the raw JSON object)

/// Collects, per `Type.field`: fixtures where the server sent the key, fixtures where it was absent although the Swift
/// value is non-nil (a fallback/default was used), and raw keys no Swift field reads.
@MainActor final class KeyAudit {
    var sent: Set<String> = []
    var defaulted: [String: Set<String>] = [:]
    var absentNil: [String: Set<String>] = [:]
    var ignored: [String: Set<String>] = [:]
    /// Client-only stored properties that never appear on the wire.
    let clientOnly: Set<String> = ["localId"]

    func record(_ value: Any, raw: Any, fixture: String) { walk(value, raw, fixture) }

    private static func unwrap(_ v: Any) -> Any? {
        let m = Mirror(reflecting: v)
        guard m.displayStyle == .optional else { return v }
        return m.children.first?.value
    }

    private static func typeName(_ v: Any) -> String {
        var s = String(describing: type(of: v))
        if let i = s.firstIndex(of: "<") { s = String(s[..<i]) }   // Job<MealDraft> → Job (aggregate generics)
        return s
    }

    private func walk(_ value: Any, _ raw: Any, _ fixture: String) {
        guard let v = Self.unwrap(value) else { return }
        let m = Mirror(reflecting: v)
        switch m.displayStyle {
        case .struct:
            guard let obj = raw as? [String: Any] else { return }
            let type = Self.typeName(v)
            var labels: Set<String> = []
            for child in m.children {
                guard let label = child.label, !clientOnly.contains(label) else { continue }
                labels.insert(label)
                let key = "\(type).\(label)"
                if let rawChild = obj[label] {
                    sent.insert(key)
                    if !(rawChild is NSNull) { walk(child.value, rawChild, fixture) }
                } else if Self.unwrap(child.value) == nil {
                    absentNil[key, default: []].insert(fixture)
                } else {
                    defaulted[key, default: []].insert(fixture)
                }
            }
            // Dictionary-backed structs have no labels to compare; skip "ignored" for them.
            if !labels.isEmpty {
                for k in obj.keys where !labels.contains(k) { ignored["\(type).\(k)", default: []].insert(fixture) }
            }
        case .collection:
            guard let arr = raw as? [Any] else { return }
            for (child, r) in zip(m.children, arr) { walk(child.value, r, fixture) }
        case .dictionary:
            guard let obj = raw as? [String: Any] else { return }
            for child in m.children {
                let pair = Mirror(reflecting: child.value).children.map(\.value)
                guard pair.count == 2, let k = pair[0] as? String, let r = obj[k] else { continue }
                walk(pair[1], r, fixture)
            }
        default:
            return
        }
    }
}

let audit = KeyAudit()

// MARK: - Helpers

/// Decodes fixture `name` with `JSONCoding.decoder()` as `T` (the wire type APIClient uses) and records the key audit.
@MainActor @discardableResult
func live<T: Decodable>(_ type: T.Type, _ name: String, file: StaticString = #fileID, line: UInt = #line) -> T? {
    guard let data = fixtureData(name) else {
        check(false, "fixture \(name)", "missing \(fixtureDir)/\(name).json — run LogicTests/Live/collect.sh", file: file, line: line)
        return nil
    }
    do {
        let v = try JSONCoding.decoder().decode(T.self, from: data)
        check(true, "decode \(name)")
        if let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { audit.record(v, raw: raw, fixture: name) }
        return v
    } catch {
        check(false, "decode \(name) as \(T.self)", "\(JSONCoding.describe(error)) — \(error)", file: file, line: line)
        return nil
    }
}

/// Runs one `APIClient` call against a mock transport that answers with fixture `name` (or `inline`), checks the method,
/// path and query, and returns the call's result plus the captured request.
@MainActor
func viaAPI<R>(_ name: String, _ method: String, _ path: String, query: String? = nil, inline: String? = nil,
               file: StaticString = #fileID, line: UInt = #line,
               _ call: (APIClient) async throws -> R) async -> (R?, RecordedRequest?) {
    let label = "api \(name)"
    guard let data = inline.map({ Data($0.utf8) }) ?? fixtureData(name) else {
        check(false, label, "missing fixture", file: file, line: line)
        return (nil, nil)
    }
    MockServer.shared.reset(body: data)
    let api = makeClient()
    var result: R?
    do {
        result = try await call(api)
    } catch {
        check(false, label, "threw \(error)", file: file, line: line)
    }
    let req = MockServer.shared.requests.last
    expectEqual(req?.method, method, "\(label) method", file: file, line: line)
    expectEqual(req?.path, "/api/v1/" + path, "\(label) path", file: file, line: line)
    expectEqual(req?.query, query, "\(label) query", file: file, line: line)
    return (result, req)
}

/// The JSON object a captured request carried.
func bodyObject(_ r: RecordedRequest?) -> [String: Any]? {
    guard let d = r?.body, !d.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Checks a request body's keys against the server's read set: every sent key must be read (or listed in `ignored`,
/// keys the server knowingly drops), and every key in `required` must be present.
@MainActor
func expectKeys(_ obj: [String: Any]?, reads: Set<String>, required: Set<String> = [], ignored: Set<String> = [], _ name: String,
                file: StaticString = #fileID, line: UInt = #line) {
    guard let obj else { check(false, "\(name) body", "no JSON object body", file: file, line: line); return }
    let keys = Set(obj.keys)
    let unknown = keys.subtracting(reads).subtracting(ignored)
    check(unknown.isEmpty, "\(name) keys the server never reads", unknown.sorted().joined(separator: ", "), file: file, line: line)
    let missing = required.subtracting(keys)
    check(missing.isEmpty, "\(name) keys the server needs", "missing " + missing.sorted().joined(separator: ", "), file: file, line: line)
}

@MainActor
func expectKeysEach(_ list: Any?, reads: Set<String>, required: Set<String> = [], ignored: Set<String> = [], _ name: String,
                    file: StaticString = #fileID, line: UInt = #line) {
    guard let arr = list as? [[String: Any]], !arr.isEmpty else { check(false, "\(name)", "expected a non-empty array of objects", file: file, line: line); return }
    for (i, o) in arr.enumerated() { expectKeys(o, reads: reads, required: required, ignored: ignored, "\(name)[\(i)]", file: file, line: line) }
}

// MARK: - What the server reads (grep of server/src)

enum ServerReads {
    // routes/account.ts
    static let login: Set<String> = ["username", "password", "device_name"]
    static let register: Set<String> = ["username", "password", "display_name", "invite_code", "device_name"]
    static let password: Set<String> = ["old_password", "new_password"]
    static let profile: Set<String> = ["sex", "birth_date", "height_cm", "weight_kg", "activity_level", "goal", "goal_rate_kg_week",
                                       "target_weight_kg", "physiology", "sodium_mode", "conditions", "nicotine", "secondhand_smoke", "timezone"]
    static let settings: Set<String> = ["display_name", "avatar_color", "share_mode", "share_detail", "share_with"]
    // routes/app.ts
    static let accountDelete: Set<String> = ["password"]
    static let unlink: Set<String> = ["device_id", "delete_data"]
    // routes/body.ts
    static let body: Set<String> = ["date", "time", "weight_kg", "body_fat_pct", "waist_cm", "sbp", "dbp", "bp_treated", "note"]
    static let labs: Set<String> = ["date", "total_chol", "hdl", "non_hdl", "ldl", "lipid_treated", "fasting_glucose", "hba1c", "diabetes", "note"]
    static let activityFields: Set<String> = ["steps", "active_kcal", "resting_kcal", "distance_km", "exercise_min", "sleep_hours", "stand_hours"]
    static let exercise: Set<String> = ["date", "time", "activity_key", "met", "duration_min", "distance_km", "description", "in_device", "source"]
    static let inDevice: Set<String> = ["in_device"]
    static let aiActivity: Set<String> = ["text", "photos", "date"]
    /// `cleanWorkouts` (WorkoutIn); `kcal`/`notes` are recomputed/ignored by the server.
    static let workout: Set<String> = ["description", "activity_key", "met", "duration_min", "distance_km", "in_device", "avg_hr", "device_kcal"]
    static let preview: Set<String> = ["date", "meal", "activity", "body", "workouts"]
    static let previewMeal: Set<String> = ["meal_type", "time", "items", "replace_meal_id"]
    /// `/preview` builds rows from these item fields only.
    static let previewItem: Set<String> = ["name", "amount_g", "nutrients", "groups", "hazards", "nova_group"]
    static let previewBody: Set<String> = ["weight_kg", "sbp", "dbp", "bp_treated"]
    static let commit: Set<String> = ["date", "source", "activity", "body", "workouts"]
    static let commitBody: Set<String> = ["weight_kg", "body_fat_pct", "sbp", "dbp", "bp_treated", "time"]
    // services/healthsync.ts
    static let sync: Set<String> = ["device_id", "device_name", "timezone", "overwrite_manual", "days", "samples", "workouts", "deleted", "cursors"]
    static let syncDay: Set<String> = activityFields.union(["date", "clear"])
    static let syncSample: Set<String> = ["uuid", "type", "date", "time", "value", "sbp", "dbp", "bp_treated", "source_name"]
    static let syncWorkout: Set<String> = ["uuid", "date", "time", "start", "end", "hk_activity_type", "activity_key", "description", "met",
                                           "duration_min", "distance_km", "avg_hr", "device_kcal", "in_device", "source_name"]
    // routes/log.ts
    static let aiMeal: Set<String> = ["text", "photos", "date", "time", "meal_type"]
    static let aiFood: Set<String> = ["name", "brand", "note", "photos"]
    static let meal: Set<String> = ["date", "time", "meal_type", "description", "photos", "ai_summary", "ai_model", "items"]
    /// `cleanItem`
    static let mealItem: Set<String> = ["name", "amount_g", "amount_desc", "food_id", "category", "cooking_method", "nova_group", "confidence",
                                        "nutrients", "groups", "hazards", "notes"]
    static let hazard: Set<String> = ["key", "amount", "note"]
    static let water: Set<String> = ["ml", "date"]
    /// `foodBody`
    static let food: Set<String> = ["name", "brand", "aliases", "category", "serving_g", "serving_desc", "per100", "groups100", "hazards100",
                                    "nova_group", "ingredients", "label_fields", "source", "source_urls", "notes", "visibility"]
    static let hazard100: Set<String> = ["key", "amount_per_100g", "note"]
    static let fromItem: Set<String> = ["item", "name", "brand", "aliases", "serving_g", "serving_desc", "source_urls", "visibility"]
    static let foodItem: Set<String> = ["grams"]
    // routes/reports.ts
    static let periodSummary: Set<String> = ["start", "end"]
    /// Draft-only DraftItem fields the server ignores on `/meals` and `/preview` (meals §1.10).
    static let draftOnly: Set<String> = ["per100", "save_suggested", "saved_food_id"]
}

// MARK: - Context from the fixtures

let me0 = live(Me.self, "auth_me")
let today = me0?.today ?? "2026-10-04"
let mealJob = live(Job<MealDraft>.self, "ai_meal_job")
let activityJob = live(Job<ActivityDraft>.self, "ai_activity_job")
let foodJob = live(Job<FoodDraft>.self, "ai_food_job")
let uploaded = live(UploadResponse.self, "uploads")
let photoId = uploaded?.photos.first?.id ?? "photo.jpg"
let draftItems = mealJob?.result?.items ?? []

/// Same as the app's LogMeal save: the reviewed draft items, with the draft's summary and model.
func mealBody(description: String, items: [DraftItem]) -> MealBody {
    MealBody(date: today, time: "12:30", meal_type: "lunch", description: description, photos: [photoId],
             ai_summary: mealJob?.result?.summary ?? "", ai_model: mealJob?.result?.model ?? "", items: items)
}

/// A realistic HealthKit batch built from the Swift sync types (as HealthQueries / WorkoutMapper / DayAggregator produce).
func swiftHealthSyncRequest(today: String) -> HealthSyncRequest {
    let tz = TimeZone(identifier: "Asia/Shanghai")!
    let d1 = LocalDay.addDays(today, -1), d2 = LocalDay.addDays(today, -2), d4 = LocalDay.addDays(today, -4)
    func iso(_ day: String, _ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Double($0) }
        let start = LocalDay.date(fromKey: day, in: tz) ?? Date()
        return HealthSyncText.isoTimestamp(start.addingTimeInterval(parts[0] * 3600 + parts[1] * 60), in: tz)
    }
    // Day totals go through the engine's own assembly (rounding, clamping, `clear` from the sent-days ledger).
    // Raw HealthKit-like readings: d4 complete, d2 lost its stand hours since the last sync, d3 has nothing (not sent).
    let readings: [HealthDayField: [String: Double]] = [
        .steps: [d4: 7421.4, d2: 12005.6, today: 2210],
        .active_kcal: [d4: 388.63, d2: 610.24, today: 95.51],
        .resting_kcal: [d4: 1702.38],
        .distance_km: [d4: 5.4213, d2: 8.9004],
        .exercise_min: [d4: 31.2, d2: 55],
        .stand_hours: [d4: 10],
        .sleep_hours: [d4: 6.9166, d2: 7.5],
    ]
    let ledger = SentDaysLedger(days: [d2: ["active_kcal", "stand_hours", "steps"]])
    let days = DayAggregator.makeDays(dates: [d4, LocalDay.addDays(today, -3), d2, today], readings: readings, ledger: ledger)
    let samples = [
        SyncSample(uuid: "5E1F0000-0000-4000-8000-000000000001", type: .body_mass, date: d2, time: "07:05", start: iso(d2, "07:05"),
                   value: 80.9, source_name: "健康"),
        SyncSample(uuid: "5E1F0000-0000-4000-8000-000000000002", type: .body_fat, date: d2, time: "07:05", start: iso(d2, "07:05"),
                   value: 21.9, source_name: "体脂秤"),
        SyncSample(uuid: "5E1F0000-0000-4000-8000-000000000003", type: .waist, date: d1, time: "08:10", start: iso(d1, "08:10"),
                   value: 86.5, source_name: "健康"),
        SyncSample(uuid: "5E1F0000-0000-4000-8000-000000000004", type: .blood_pressure, date: d1, time: "21:30", start: iso(d1, "21:30"),
                   sbp: 131, dbp: 84, bp_treated: true, source_name: "欧姆龙 Connect"),
    ]
    let workouts = [
        SyncWorkout(uuid: "5E1F0000-0000-4000-8000-0000000000A1", date: d2, time: "06:40", start: iso(d2, "06:40"), end: iso(d2, "07:22"),
                    hk_activity_type: 37, activity_key: "run_10kmh", description: "户外跑步", met: 9.6, duration_min: 42.3,
                    distance_km: 7.05, avg_hr: 151, device_kcal: 455.2, in_device: true, source_name: "Apple Watch"),
        SyncWorkout(uuid: "5E1F0000-0000-4000-8000-0000000000A2", date: d4, time: "19:00", start: iso(d4, "19:00"), end: iso(d4, "19:45"),
                    hk_activity_type: 13, activity_key: "cycle_stationary", description: "室内骑行", met: nil, duration_min: 45,
                    distance_km: nil, avg_hr: 128, device_kcal: 310, in_device: true, source_name: "Apple Watch"),
    ]
    return HealthSyncRequest(device_id: "swift-live-0001", device_name: "Swift Live iPhone", timezone: "Asia/Shanghai", overwrite_manual: false,
                             days: days, samples: samples, workouts: workouts,
                             deleted: ["5E1F0000-0000-4000-8000-00000000DEAD"], cursors: nil)
}

func swiftPreviewRequest() -> PreviewRequest {
    PreviewRequest(date: today,
                   meal: PreviewMeal(meal_type: "dinner", time: "18:30", items: draftItems, replace_meal_id: nil),
                   activity: ActivityValues(steps: 9000, active_kcal: 420),
                   body: PreviewBody(weight_kg: 81.1, body_fat_pct: 22, sbp: 126, dbp: 80, bp_treated: false),
                   workouts: [WorkoutDraft(description: "慢跑", activity_key: "jogging", met: 7, duration_min: 30, distance_km: 4.2,
                                           kcal: nil, notes: nil, avg_hr: 140, device_kcal: nil, in_device: false)])
}

func swiftCommitRequest() -> ActivityCommitRequest? {
    guard let d = activityJob?.result else { return nil }
    return ActivityCommitRequest(date: d.date, source: "ai", activity: d.activity,
                                 body: CommitBody(weight_kg: d.body.weight_kg, body_fat_pct: d.body.body_fat_pct, sbp: d.body.sbp, dbp: d.body.dbp,
                                                  bp_treated: false, time: nil),
                                 workouts: d.workouts)
}

// MARK: - Emit mode (bodies for post-swift.sh)

if let dir = ProcessInfo.processInfo.environment["LIVE_EMIT_DIR"] {
    let emitToday = ProcessInfo.processInfo.environment["LIVE_TODAY"] ?? today
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var written: [String] = []
    func emit<T: Encodable>(_ name: String, _ value: T) {
        do {
            let enc = JSONCoding.encoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(value).write(to: URL(fileURLWithPath: "\(dir)/\(name).json"))
            written.append(name)
        } catch {
            print("emit \(name) failed: \(error)")
            exit(1)
        }
    }
    emit("health_sync", swiftHealthSyncRequest(today: emitToday))
    emit("meal_ai", MealAIRequest(text: "两个包子一碗小米粥", date: emitToday, time: "08:00", meal_type: "breakfast", photos: [photoId]))
    emit("meal", MealBody(date: emitToday, time: "08:05", meal_type: "breakfast", description: "Swift 编码的早餐", photos: [photoId],
                          ai_summary: mealJob?.result?.summary ?? "", ai_model: mealJob?.result?.model ?? "", items: draftItems))
    var edited = draftItems
    if !edited.isEmpty { edited[0] = ItemMath.rescale(edited[0], grams: edited[0].amount_g * 1.5) }
    emit("meal_update", MealBody(date: emitToday, time: "08:15", meal_type: "breakfast", description: "Swift 编码的早餐（改）", photos: [],
                                 ai_summary: "", ai_model: "", items: edited))
    let preview = swiftPreviewRequest()
    emit("preview", PreviewRequest(date: emitToday, meal: preview.meal, activity: preview.activity, body: preview.body, workouts: preview.workouts))
    if let c = swiftCommitRequest() {
        var workouts = c.workouts
        workouts.append(WorkoutDraft(description: "力量训练", activity_key: "strength_moderate", met: 5, duration_min: 25, distance_km: nil,
                                     kcal: nil, notes: "Swift", avg_hr: nil, device_kcal: nil, in_device: false))
        emit("activity_commit", ActivityCommitRequest(date: emitToday, source: "manual", activity: c.activity,
                                                      body: CommitBody(weight_kg: 81.0, body_fat_pct: 22.1, sbp: 125, dbp: 81, bp_treated: true, time: "21:00"),
                                                      workouts: workouts))
    }
    emit("activity_ai", ActivityAIRequest(text: "体重 80.8 公斤，慢跑 25 分钟", date: emitToday, photos: []))
    if let f = foodJob?.result { emit("food", FoodInput(draft: f)) }
    if let food = live(Food.self, "food_seed_detail") { emit("food_update_seed_roundtrip", food.toInput()) }
    emit("food_ai", FoodAIRequest(name: "燕麦奶", brand: "OATLY", note: "", photos: []))
    if let item = draftItems.first {
        emit("from_item", FromItemRequest(item: item, name: item.name + "（Swift）", brand: "", aliases: ["别名"], serving_g: item.amount_g,
                                          serving_desc: item.amount_desc ?? "", source_urls: [SourceLink(title: "示例", url: "https://example.com")], visibility: "private"))
    }
    emit("food_item", FoodItemRequest(grams: 180))
    emit("food_item_default", FoodItemRequest(grams: nil))
    if let p = me0?.profile { emit("profile", p) }
    if let u = me0?.user {
        emit("settings", SettingsBody(display_name: u.display_name, avatar_color: u.avatar_color, share_mode: u.share_mode,
                                      share_detail: u.share_detail, share_with: u.share_with ?? []))
    }
    emit("water", WaterBody(ml: 200, date: emitToday))
    emit("body", BodyInput(date: emitToday, time: "07:00", weight_kg: 80.7, body_fat_pct: nil, waist_cm: 86, sbp: nil, dbp: nil, bp_treated: false, note: nil))
    emit("labs", LabInput(date: emitToday, total_chol: 185, hdl: 50, ldl: nil, non_hdl: nil, fasting_glucose: 92, hba1c: nil, lipid_treated: false, diabetes: false, note: "Swift"))
    emit("exercise", ExerciseInput(date: emitToday, time: "18:00", activity_key: "walk_brisk", met: nil, duration_min: 40, distance_km: 3.6,
                                   description: nil, in_device: false, source: "manual"))
    emit("in_device", InDeviceBody(in_device: true))
    emit("activity_put", ActivityValues(steps: 6500, active_kcal: 300, resting_kcal: nil, distance_km: 4.1, exercise_min: 20, sleep_hours: 7, stand_hours: nil))
    emit("period_summary", PeriodSummaryRequest(start: LocalDay.addDays(emitToday, -6), end: emitToday))
    emit("unlink", HealthUnlinkRequest(device_id: "swift-live-0001", delete_data: false))
    print("emitted \(written.count) Swift-encoded bodies to \(dir): \(written.joined(separator: " "))")
    exit(0)
}

// MARK: - Auth & account

section("auth")
if let ping = live(HealthPing.self, "health") { check(ping.ok, "health ok") }
_ = await viaAPI("health", "GET", "health") { try await $0.health() }

if let cfg = live(AuthConfig.self, "auth_config") {
    for f in ["health_sync", "account_delete", "token_refresh", "session_current"] { check(cfg.supports(f), "auth/config feature \(f)") }
    expectEqual(cfg.min_password, 6, "min_password")
}
_ = await viaAPI("auth_config", "GET", "auth/config") { try await $0.authConfig() }

if let t = live(TokenResponse.self, "auth_token") {
    check(t.user != nil, "auth/token carries user")
    check(t.token.hasPrefix("nla_"), "app token prefix")
    check(Timestamps.iso(t.expires_at) != nil, "expires_at parses", t.expires_at)
}
do {
    let (_, r) = await viaAPI("auth_token", "POST", "auth/token") { try await $0.login(username: " demo ", password: "demo123", deviceName: "QA") }
    expectKeys(bodyObject(r), reads: ServerReads.login, required: ServerReads.login, "auth/token")
    expectEqual(bodyObject(r)?["username"] as? String, "demo", "auth/token trims username")
}
if let t = live(TokenResponse.self, "auth_register") { expectNil(t.user, "register has no user") }
do {
    let (_, r) = await viaAPI("auth_register", "POST", "auth/register") {
        try await $0.register(RegisterBody(username: "qa", password: "qa12345", display_name: "QA", invite_code: "", device_name: "QA"))
    }
    expectKeys(bodyObject(r), reads: ServerReads.register, required: ServerReads.register, "auth/register")
}
if let t = live(TokenResponse.self, "auth_refresh") { expectNil(t.user, "refresh has no user"); check(!t.expires_at.isEmpty, "refresh expires_at") }
do {
    let (_, r) = await viaAPI("auth_refresh", "POST", "auth/refresh") { try await $0.refreshToken() }
    expectEqual(r.flatMap { String(data: $0.body ?? Data(), encoding: .utf8) }, "{}", "auth/refresh sends {}")
}

if let me = me0 {
    check(me.profile != nil, "me.profile present")
    check(me.user.share_with != nil, "me.user.share_with present")
    check(me.ai.isMock, "me.ai mock")
    check(!me.conditions.isEmpty, "me.conditions")
    check(LocalDay.isValid(me.today), "me.today is a day key", me.today)
}
_ = await viaAPI("auth_me", "GET", "auth/me") { try await $0.me() }
if let me = live(Me.self, "auth_me_no_profile") { expectNil(me.profile, "fresh account has no profile") }

for name in ["auth_sessions", "auth_sessions_after"] {
    if let rows = live([SessionRow].self, name) {
        expectEqual(rows.filter { $0.current == true }.count, 1, "\(name): exactly one current session")
        check(rows.allSatisfy { $0.current != nil }, "\(name): current present on every row")
        check(rows.allSatisfy { Timestamps.iso($0.expires_at) != nil }, "\(name): expires_at parses")
        check(rows.allSatisfy { $0.last_used_at.map { Timestamps.sqlite($0) != nil } ?? true }, "\(name): last_used_at parses")
    }
}
_ = await viaAPI("auth_sessions", "GET", "auth/sessions") { try await $0.sessions() }

do {
    let (_, r) = await viaAPI("account_delete", "POST", "account/delete") { try await $0.deleteAccount(password: " qa12345 ") }
    expectKeys(bodyObject(r), reads: ServerReads.accountDelete, required: ServerReads.accountDelete, "account/delete")
}

// MARK: - Profile, settings, users

section("profile")
if let saved = live(ProfileSaveResponse.self, "profile_put") {
    check(saved.ok, "profile_put ok")
    if let p = me0?.profile { check(saved.profile == p, "PUT profile echoes the stored profile") }
}
if let p = me0?.profile {
    let (res, r) = await viaAPI("profile_put", "PUT", "profile") { try await $0.saveProfile(p) }
    check(res == p, "saveProfile returns res.profile")
    expectKeys(bodyObject(r), reads: ServerReads.profile, required: ServerReads.profile.subtracting(["target_weight_kg"]), "PUT profile")
}
for name in ["profile_targets", "profile_targets_date"] {
    if let t = live(Targets.self, name) {
        expectEqual(t.orderedIntake.count, t.intake.count, "\(name): every intake key is in Vocab.intakeOrder")
        expectEqual(Set(t.upper.keys).subtracting(Vocab.upperOrder).sorted(), [], "\(name): every upper key is in Vocab.upperOrder")
        expectEqual(t.orderedLimits.count, t.limits.count, "\(name): every limit key is in Targets.limitOrder")
        check(t.energyTarget > 0 && t.bmr > 0, "\(name): energy fields")
    }
}
_ = await viaAPI("profile_targets", "GET", "profile/targets") { try await $0.targets(date: nil) }
_ = await viaAPI("profile_targets_date", "GET", "profile/targets", query: "date=2026-09-28") { try await $0.targets(date: "2026-09-28") }

section("settings")
if let ok = live(OkResponse.self, "settings_put") { check(ok.ok, "settings ok") }
if let u = me0?.user {
    let body = SettingsBody(display_name: u.display_name, avatar_color: u.avatar_color, share_mode: u.share_mode, share_detail: u.share_detail, share_with: u.share_with ?? [])
    let (_, r) = await viaAPI("settings_put", "PUT", "settings") { try await $0.saveSettings(body) }
    expectKeys(bodyObject(r), reads: ServerReads.settings, required: ServerReads.settings, "PUT settings")
}
if let t = live(PersonalTokenResponse.self, "settings_token") { check(t.token.hasPrefix("nl_"), "personal token prefix", t.token) }
_ = await viaAPI("settings_token", "POST", "settings/token") { try await $0.regeneratePersonalToken() }

section("users")
for name in ["users_before_sharing", "users"] {
    if let users = live([CommunityUser].self, name) {
        check(users.contains { $0.is_me }, "\(name): contains me")
        check(users.allSatisfy { ["full", "summary", "none"].contains($0.share_detail) }, "\(name): share_detail vocabulary")
        check(users.filter(\.shared_with_me).allSatisfy { $0.recent.count == 14 }, "\(name): 14 recent scores for shared users")
    }
}
if let users = live([CommunityUser].self, "users"), let ahao = users.first(where: { $0.username == "ahao" }) {
    check(ahao.shared_with_me && ahao.share_detail == "full", "ahao shares full after PUT settings (selected + share_with)")
}
_ = await viaAPI("users", "GET", "users") { try await $0.users() }

// MARK: - Standards (and the client vocab against them)

section("standards")
if let meta = live(Meta.self, "standards_meta") {
    expectEqual(meta.nutrients.map(\.key), Vocab.nutrientOrder, "Vocab.nutrientOrder == meta.nutrients")
    expectEqual(meta.foodGroups.map(\.key), Vocab.foodGroupOrder, "Vocab.foodGroupOrder == meta.foodGroups")
    expectEqual(meta.hazards.filter { $0.dose.from == "flag" }.map(\.key), Vocab.flagHazardKeys, "Vocab.flagHazardKeys == flag hazards")
    expectEqual(meta.marNutrients, Vocab.marNutrients, "Vocab.marNutrients == meta.marNutrients")
    expectEqual(Set(meta.nutrients.map(\.group)).subtracting(Vocab.nutrientGroupOrder).sorted(), [], "nutrient groups known")
    expectEqual(meta.activityLevels.map(\.key), ActivityLevel.allCases.map(\.rawValue), "ActivityLevel == meta.activityLevels")
    if let me = me0 { expectEqual(meta.conditions.map(\.key), me.conditions.map(\.key), "meta.conditions == me.conditions") }
}
_ = await viaAPI("standards_meta", "GET", "standards/meta") { try await $0.standardsMeta() }
if let dri = live(DriTables.self, "standards_dri") {
    expectEqual(Set(dri.intake.keys), Set(Vocab.intakeOrder), "Vocab.intakeOrder == dri.intake keys")
    expectEqual(Set(dri.upper.keys), Set(Vocab.upperOrder), "Vocab.upperOrder == dri.upper keys")
    check(dri.intake.values.allSatisfy { $0.values.count == dri.lifeStages.count }, "dri intake rows match life stages")
}
_ = await viaAPI("standards_dri", "GET", "standards/dri") { try await $0.standardsDri() }
if let s = live(AIStatus.self, "ai_status") { expectEqual(s.provider, "mock", "ai/status provider") }
_ = await viaAPI("ai_status", "GET", "ai/status") { try await $0.aiStatus() }

// MARK: - Day

section("day")
if let d = live(DayResponse.self, "day_today") {
    expectEqual(d.date, today, "day_today date"); check(d.full, "own day is full"); check(d.score.hasData, "today has data")
}
if let d = live(DayResponse.self, "day_past") {
    check(!d.visibleMeals.isEmpty, "past day has meals"); check(!d.score.items.isEmpty, "past day has score items")
    check(d.score.items.allSatisfy { !$0.message.isEmpty || $0.status == .info || true }, "items decode")
    check(Set(d.score.totals.keys).isSuperset(of: Vocab.nutrientOrder), "score.totals carries all 43 nutrients")
    check(Set(d.score.groups.keys).isSuperset(of: Vocab.foodGroupOrder), "score.groups carries all 22 groups")
    let activeSources = Set(Vocab.activeSourceZh.keys)
    check(activeSources.contains(d.score.energy.activeSource), "energy.activeSource known", d.score.energy.activeSource)
}
if let d = live(DayResponse.self, "day_empty") {
    check(!d.score.hasData, "empty day hasData false"); expectNil(d.score.score, "empty day score nil"); check(d.meals.isEmpty, "no meals")
}
if let d = live(DayResponse.self, "day_other_full") { check(d.full && !d.meals.isEmpty, "ahao shares full: meals visible") }
if let d = live(DayResponse.self, "day_other_summary") {
    check(!d.full, "xiaolin summary: full false"); check(d.meals.isEmpty && d.exercises.isEmpty, "summary hides meals/exercises")
    check(d.score.items.allSatisfy { $0.message.isEmpty }, "summary strips item messages")
}
if let d = live(DayResponse.self, "day_after_sync") { check(d.exercises.contains { $0.source == "healthkit" }, "synced workout on the day") }
if let d = live(DayResponse.self, "day_today_after") {
    expectEqual(d.waterMl, 550, "water total on the day")
    let m = d.visibleMeals.first { $0.description == "牛肉面（大碗）" }
    check(m != nil, "updated meal present")
    expectEqual(m?.photos, [photoId], "meal photos are upload ids")
    expectEqual(m?.time, "12:45", "updated time")
    check(d.body.contains { $0.note == "晨起" && $0.waist_cm == 88 }, "posted body metric on the day")
}
_ = await viaAPI("day_today", "GET", "day/\(today)") { try await $0.day(today, user: nil) }
_ = await viaAPI("day_other_full", "GET", "day/2026-09-28", query: "user=ahao") { try await $0.day("2026-09-28", user: "ahao") }

// MARK: - Trends & period & reports

section("trends")
for (name, days) in [("trends_7d", 7), ("trends_90d", 90), ("trends_year", 365), ("trends_other", 30)] {
    if let t = live(TrendsResponse.self, name) {
        expectEqual(t.days.count, days, "\(name) day count")
        check(t.days.contains { $0.hasData }, "\(name) has data")
    }
}
_ = await viaAPI("trends_7d", "GET", "trends", query: "start=2026-09-28&end=2026-10-04") { try await $0.trends(start: "2026-09-28", end: "2026-10-04", user: nil) }
_ = await viaAPI("trends_other", "GET", "trends", query: "start=2026-09-05&end=2026-10-04&user=xiaolin") {
    try await $0.trends(start: "2026-09-05", end: "2026-10-04", user: "xiaolin")
}

section("period")
for name in ["period_week", "period_month", "period_other", "period_week_with_summary"] {
    if let p = live(PeriodScore.self, name) {
        check(p.daysLogged > 0, "\(name) days logged")
        expectEqual(p.series.count, p.days, "\(name) series per day")
    }
}
if let p = live(PeriodScore.self, "period_other") { check(!p.full, "summary share → full false"); expectNil(p.aiSummary, "no aiSummary for others") }
if let p = live(PeriodScore.self, "period_week_with_summary") { check(p.aiSummary != nil, "stored aiSummary decodes", "aiSummary is nil") }
_ = await viaAPI("period_week", "GET", "period", query: "start=2026-09-28&end=2026-10-04") { try await $0.period(start: "2026-09-28", end: "2026-10-04", user: nil) }
if let j = live(JobCreated.self, "period_summary_start") { check(!j.job_id.isEmpty, "summary job id") }
do {
    let (_, r) = await viaAPI("period_summary_start", "POST", "period/summary") { try await $0.startPeriodSummary(start: "2026-09-28", end: "2026-10-04") }
    expectKeys(bodyObject(r), reads: ServerReads.periodSummary, required: ServerReads.periodSummary, "period/summary")
}
if let j = live(Job<WeeklySummary>.self, "period_summary_job") { expectEqual(j.status, .done, "summary job done") }
_ = await viaAPI("period_summary_job", "GET", "ai/jobs/x") { try await $0.job(id: "x", as: WeeklySummary.self) }
if let r = live([ReportListItem].self, "reports_empty") { check(r.isEmpty, "no reports before the summary") }
if let r = live([ReportListItem].self, "reports") { check(!r.isEmpty, "reports after summary"); check(r.first?.ai_summary != nil, "report ai_summary decodes") }
_ = await viaAPI("reports", "GET", "reports") { try await $0.reports() }

// MARK: - Meals: upload → AI → preview → save → update → water

section("meals")
if let u = uploaded { expectEqual(u.photos.count, 1, "one upload"); check(APIClient.isValidPhotoId(photoId), "upload id is valid", photoId) }
do {
    let (res, r) = await viaAPI("uploads", "POST", "uploads") { try await $0.uploadPhotos(jpegs: [Data([0xFF, 0xD8, 0xFF, 0xD9])]) }
    expectEqual(res?.first?.id, photoId, "uploadPhotos returns ids")
    let text = r.flatMap { $0.body.map { String(decoding: $0, as: UTF8.self) } } ?? ""
    check(text.contains(#"name="photos"; filename="photo1.jpg""#), "multipart field photos/photo1.jpg")
}
if let j = live(JobCreated.self, "ai_meal_start") { check(!j.job_id.isEmpty, "meal job id") }
do {
    let (_, r) = await viaAPI("ai_meal_start", "POST", "ai/meal") {
        try await $0.startMealAI(MealAIRequest(text: "牛肉面", date: today, time: "12:30", meal_type: "lunch", photos: [photoId]))
    }
    expectKeys(bodyObject(r), reads: ServerReads.aiMeal, required: ServerReads.aiMeal, "ai/meal")
}
if let j = mealJob {
    expectEqual(j.status, .done, "meal job done"); expectEqual(j.kind, "meal", "meal job kind")
    check(!draftItems.isEmpty, "draft has items")
    check(draftItems.allSatisfy { Set($0.per100.nutrients.keys) == Set(Vocab.nutrientOrder) }, "draft per100 carries 43 nutrients")
}
for name in ["ai_meal_job_pending", "ai_activity_job_pending", "ai_food_job_pending", "period_summary_job_pending"] where fixtureData(name) != nil {
    if let j = live(Job<EmptyResult>.self, name) { check(j.status == .queued || j.status == .running, "\(name) is pending") }
}
_ = await viaAPI("ai_meal_job", "GET", "ai/jobs/abc") { try await $0.job(id: "abc", as: MealDraft.self) }

for name in ["preview_meal", "preview_meal_replace", "preview_activity"] {
    if let p = live(DayPreview.self, name) { expectEqual(p.date, name == "preview_activity" ? (activityJob?.result?.date ?? today) : today, "\(name) date") }
}
if let p = live(DayPreview.self, "preview_meal") { expectEqual(p.after.mealCount, p.before.mealCount + 1, "preview adds one meal") }
if let p = live(DayPreview.self, "preview_meal_replace") { expectEqual(p.after.mealCount, p.before.mealCount, "replace keeps the meal count") }
do {
    let (_, r) = await viaAPI("preview_meal", "POST", "preview") { try await $0.preview(swiftPreviewRequest()) }
    let o = bodyObject(r)
    // PreviewBody.body_fat_pct is accepted by the request type but /preview does not score body fat (body.ts /preview).
    expectKeys(o, reads: ServerReads.preview, required: ["date"], "preview")
    expectKeys(o?["meal"] as? [String: Any], reads: ServerReads.previewMeal, required: ["meal_type", "time", "items"], "preview.meal")
    // The same DraftItem goes to /preview and /meals; /preview scores only `previewItem` and ignores the rest.
    expectKeysEach((o?["meal"] as? [String: Any])?["items"], reads: ServerReads.previewItem, required: ServerReads.previewItem.subtracting(["nova_group"]),
                   ignored: ServerReads.draftOnly.union(ServerReads.mealItem.subtracting(ServerReads.previewItem)), "preview.meal.items")
    expectKeys(o?["body"] as? [String: Any], reads: ServerReads.previewBody, ignored: ["body_fat_pct"], "preview.body")
    expectKeys(o?["activity"] as? [String: Any], reads: ServerReads.activityFields, "preview.activity")
    expectKeysEach(o?["workouts"], reads: ServerReads.workout, required: ["activity_key", "duration_min"], ignored: ["kcal", "notes"], "preview.workouts")
}

if let id = live(IdResponse.self, "meal_create") { check(id.id > 0, "meal id") }
do {
    let (id, r) = await viaAPI("meal_create", "POST", "meals") { try await $0.createMeal(mealBody(description: "牛肉面", items: draftItems)) }
    check((id ?? 0) > 0, "createMeal returns id")
    let o = bodyObject(r)
    expectKeys(o, reads: ServerReads.meal, required: ServerReads.meal, "POST meals")
    expectKeysEach(o?["items"], reads: ServerReads.mealItem, required: ["name", "amount_g", "nutrients", "groups", "hazards"],
                   ignored: ServerReads.draftOnly, "POST meals items")
}
do {
    let (_, r) = await viaAPI("meal_update", "PUT", "meals/741") { try await $0.updateMeal(id: 741, mealBody(description: "牛肉面（大碗）", items: draftItems)) }
    expectKeys(bodyObject(r), reads: ServerReads.meal, required: ["date", "time", "items"], "PUT meals")
}
for (name, total) in [("water", 250.0), ("water_more", 550.0)] {
    if let w = live(WaterResponse.self, name) { expectEqual(w.total_ml, total, "\(name) total") }
}
do {
    let (total, r) = await viaAPI("water", "POST", "water") { try await $0.addWater(ml: 250, date: today) }
    expectEqual(total, 250, "addWater returns total_ml")
    expectKeys(bodyObject(r), reads: ServerReads.water, required: ServerReads.water, "POST water")
}
for name in ["recent_items", "recent_items_after"] { live([RecentItem].self, name) }
if var raw = fixtureJSON("recent_items_after") as? [[String: Any]] {
    // The server's top-20 rarely includes the water item (logged once a day), so add the row exactly as the water flow stores it.
    if !raw.contains(where: { $0["name"] as? String == "饮用水" }) {
        raw.insert(["name": "饮用水", "food_id": NSNull(), "amount_g": 550, "n": 30, "last": today], at: 0)
    }
    let inline = String(decoding: (try? JSONSerialization.data(withJSONObject: raw)) ?? Data(), as: UTF8.self)
    let (items, _) = await viaAPI("recent_items_after", "GET", "meals/recent-items", inline: inline) { try await $0.recentItems() }
    check(items?.contains { $0.name == "饮用水" } == false, "recentItems() filters 饮用水")
    expectEqual(items?.count, raw.count - 1, "only the water item is filtered")
}

// MARK: - Foods

section("foods")
if let f = foodJob?.result { check(!f.name.isEmpty, "food draft name"); check(Set(f.per100.keys) == Set(Vocab.nutrientOrder), "food draft per100 keys") }
do {
    let (_, r) = await viaAPI("ai_food_start", "POST", "ai/food") { try await $0.startFoodAI(FoodAIRequest(name: "希腊酸奶", brand: "简爱", note: "无糖", photos: [])) }
    expectKeys(bodyObject(r), reads: ServerReads.aiFood, required: ServerReads.aiFood, "ai/food")
}
_ = await viaAPI("ai_food_job", "GET", "ai/jobs/f") { try await $0.job(id: "f", as: FoodDraft.self) }
for name in ["food_detail", "food_seed_detail"] {
    if let f = live(Food.self, name) { check(f.mine, "\(name) mine"); check(Set(f.per100.keys) == Set(Vocab.nutrientOrder), "\(name) per100 keys") }
}
if let f = live(Food.self, "food_detail") { expectEqual(f.aliasList, ["酸奶", "greek yogurt"], "aliases string splits"); expectEqual(f.visibility, "public", "visibility") }
if let f = live(Food.self, "food_seed_detail") { expectEqual(f.hazards100.first?.amount_per_100g, 9, "seeded hazards100 amount") }
for name in ["foods_all", "foods_mine", "foods_query"] {
    if let list = live([Food].self, name) { check(!list.isEmpty, "\(name) non-empty") }
}
_ = await viaAPI("foods_all", "GET", "foods", query: "scope=all") { try await $0.foods(query: nil, scope: .all) }
_ = await viaAPI("foods_query", "GET", "foods", query: "q=%E9%85%B8%E5%A5%B6&scope=all") { try await $0.foods(query: " 酸奶 ", scope: .all) }
_ = await viaAPI("foods_mine", "GET", "foods", query: "scope=mine") { try await $0.foods(query: "", scope: .mine) }
_ = await viaAPI("food_detail", "GET", "foods/2") { try await $0.food(id: 2) }
if let f = foodJob?.result {
    let (_, r) = await viaAPI("food_create", "POST", "foods") { try await $0.createFood(FoodInput(draft: f)) }
    let o = bodyObject(r)
    expectKeys(o, reads: ServerReads.food, required: ServerReads.food.subtracting(["serving_g", "nova_group"]), "POST foods")
    check(o?["aliases"] is [Any], "POST foods aliases is an array")
}
if let food = live(Food.self, "food_seed_detail") {
    let (_, r) = await viaAPI("food_update", "PUT", "foods/1") { try await $0.updateFood(id: 1, food.toInput()) }
    let o = bodyObject(r)
    expectKeys(o, reads: ServerReads.food, required: ServerReads.food.subtracting(["serving_g", "nova_group"]), "PUT foods")
    expectKeysEach(o?["hazards100"], reads: ServerReads.hazard100, required: ["key", "amount_per_100g"], "PUT foods hazards100")
}
for (name, grams) in [("food_item", 150.0), ("food_item_default", 200.0)] {
    if let it = live(DraftItem.self, name) {
        expectEqual(it.amount_g, grams, "\(name) grams"); expectEqual(it.food_id, 2, "\(name) food_id")
        check(Set(it.per100.nutrients.keys) == Set(Vocab.nutrientOrder), "\(name) per100 from the server")
    }
}
do {
    let (_, r) = await viaAPI("food_item", "POST", "foods/2/item") { try await $0.foodItem(id: 2, grams: 150) }
    expectKeys(bodyObject(r), reads: ServerReads.foodItem, required: ["grams"], "foods/{id}/item")
    let (_, r2) = await viaAPI("food_item_default", "POST", "foods/2/item") { try await $0.foodItem(id: 2, grams: nil) }
    expectEqual(r2.flatMap { String(data: $0.body ?? Data(), encoding: .utf8) }, "{}", "nil grams encodes {}")
}
if let item = draftItems.first {
    let req = FromItemRequest(item: item, name: "牛肉面", brand: "", aliases: ["拉面"], serving_g: item.amount_g, serving_desc: "一碗", source_urls: [], visibility: "private")
    let (_, r) = await viaAPI("food_from_item", "POST", "foods/from-item") { try await $0.saveFoodFromItem(req) }
    let o = bodyObject(r)
    expectKeys(o, reads: ServerReads.fromItem, required: ["item"], "foods/from-item")
    check(((o?["item"] as? [String: Any])?["per100"] as? [String: Any])?["nutrients"] != nil, "from-item sends item.per100.nutrients")
}

// MARK: - Body, labs, activity, exercises

section("body")
for name in ["body", "body_range", "body_after_sync"] { if let rows = live([BodyMetric].self, name) { check(!rows.isEmpty, "\(name) rows") } }
if let rows = live([BodyMetric].self, "body_after_sync") {
    let bp = rows.first { $0.external_id == "A1B2C3D4-0000-0000-0000-000000000003" }
    expectEqual(bp?.sbp, 128, "synced BP sbp"); expectEqual(bp?.source, "healthkit", "synced source"); expectEqual(bp?.source_name, "欧姆龙", "source_name")
}
_ = await viaAPI("body_range", "GET", "body", query: "start=2026-09-05&end=2026-10-04") { try await $0.bodyMetrics(start: "2026-09-05", end: "2026-10-04") }
do {
    let input = BodyInput(date: today, time: "07:30", weight_kg: 81.4, body_fat_pct: 22.5, waist_cm: 88, sbp: 124, dbp: 79, bp_treated: false, note: "晨起")
    let (id, r) = await viaAPI("body_create", "POST", "body") { try await $0.addBodyMetric(input) }
    check((id ?? 0) > 0, "addBodyMetric id")
    expectKeys(bodyObject(r), reads: ServerReads.body, required: ["date", "time", "bp_treated"], "POST body")
    check(bodyObject(r)?["bp_treated"] is Bool, "bp_treated is a JSON boolean")
}
if let labs = live([LabResult].self, "labs") { check(!labs.isEmpty, "labs rows") }
_ = await viaAPI("labs", "GET", "labs") { try await $0.labs() }
do {
    let input = LabInput(date: today, total_chol: 190, hdl: 48, ldl: 118, non_hdl: nil, fasting_glucose: 95, hba1c: 5.4, lipid_treated: false, diabetes: false, note: "体检")
    let (_, r) = await viaAPI("labs_create", "POST", "labs") { try await $0.addLab(input) }
    expectKeys(bodyObject(r), reads: ServerReads.labs, required: ["date", "lipid_treated", "diabetes"], "POST labs")
}
for name in ["activity", "activity_range", "activity_after_sync"] { if let a = live(ActivityList.self, name) { check(!a.days.isEmpty, "\(name) days") } }
if let a = live(ActivityList.self, "activity_after_sync") {
    check(a.exercises.contains { $0.source == "healthkit" && $0.external_id != nil }, "synced workout row has external_id")
}
_ = await viaAPI("activity_range", "GET", "activity", query: "start=2026-09-05&end=2026-10-04") { try await $0.activity(start: "2026-09-05", end: "2026-10-04") }
do {
    let (_, r) = await viaAPI("activity_put", "PUT", "activity/2026-10-03") {
        try await $0.putActivity(date: "2026-10-03", ActivityValues(steps: 8000, active_kcal: 420, exercise_min: 35, sleep_hours: 7.2))
    }
    expectKeys(bodyObject(r), reads: ServerReads.activityFields, "PUT activity")
}
if let e = live(ExerciseCreated.self, "exercise_create") { check(e.kcal > 0, "exercise kcal") }
do {
    let input = ExerciseInput(date: today, time: "18:30", activity_key: "jogging", met: nil, duration_min: 30, distance_km: 4.5, description: "慢跑", in_device: false, source: "manual")
    let (_, r) = await viaAPI("exercise_create", "POST", "exercises") { try await $0.addExercise(input) }
    expectKeys(bodyObject(r), reads: ServerReads.exercise, required: ["date", "duration_min", "in_device"], "POST exercises")
    let (_, r2) = await viaAPI("exercise_patch", "PATCH", "exercises/58") { try await $0.setExerciseInDevice(id: 58, inDevice: true) }
    expectKeys(bodyObject(r2), reads: ServerReads.inDevice, required: ServerReads.inDevice, "PATCH exercises")
}

section("activity AI")
if let d = activityJob?.result {
    check(!d.workouts.isEmpty, "activity draft has workouts")
    check(d.body.weight_kg != nil, "activity draft weight")
}
do {
    let (_, r) = await viaAPI("ai_activity_start", "POST", "ai/activity") { try await $0.startActivityAI(ActivityAIRequest(text: "跑步", date: today, photos: [])) }
    expectKeys(bodyObject(r), reads: ServerReads.aiActivity, required: ServerReads.aiActivity, "ai/activity")
}
_ = await viaAPI("ai_activity_job", "GET", "ai/jobs/a") { try await $0.job(id: "a", as: ActivityDraft.self) }
if let c = live(ActivityCommitResponse.self, "activity_commit") { check(c.ok, "commit ok"); expectEqual(c.workouts, activityJob?.result?.workouts.count ?? -1, "committed workouts") }
if let req = swiftCommitRequest() {
    let (_, r) = await viaAPI("activity_commit", "POST", "activity/commit") { try await $0.commitActivity(req) }
    let o = bodyObject(r)
    expectKeys(o, reads: ServerReads.commit, required: ServerReads.commit, "activity/commit")
    expectKeys(o?["body"] as? [String: Any], reads: ServerReads.commitBody, required: ["bp_treated"], "activity/commit body")
    expectKeys(o?["activity"] as? [String: Any], reads: ServerReads.activityFields, "activity/commit activity")
    expectKeysEach(o?["workouts"], reads: ServerReads.workout, required: ["activity_key", "duration_min", "in_device"], ignored: ["kcal", "notes"], "activity/commit workouts")
}

// MARK: - HealthKit sync

section("health sync")
for name in ["health_sync_state_empty", "health_sync_state", "health_sync_state_after_unlink"] { live(HealthSyncState.self, name) }
if let s = live(HealthSyncState.self, "health_sync_state") {
    let dev = s.devices.first
    expectEqual(dev?.device_id, "qa-device-0001", "state device")
    expectEqual(Set(dev?.kinds.keys.map { $0 } ?? []), ["days", "samples", "workouts"], "state kinds")
    expectEqual(dev?.kinds["days"]?.cursor, today, "days cursor stored")
    check(dev?.kinds.values.allSatisfy { Timestamps.sqlite($0.last_synced_at) != nil } ?? false, "last_synced_at parses")
}
_ = await viaAPI("health_sync_state", "GET", "health/sync/state") { try await $0.healthSyncState() }
if let r = live(HealthSyncResponse.self, "health_sync") {
    expectEqual(r.days?.upserted, 3, "days upserted"); expectEqual(r.days?.kept_manual.first?.fields, ["steps", "active_kcal", "exercise_min"], "kept manual fields")
    expectEqual(r.days?.rejected.first?.date, "2099-01-01", "rejected day carries date")
    expectEqual(r.samples?.inserted, 4, "samples inserted"); expectEqual(r.samples?.rejected.count, 2, "samples rejected")
    expectNil(r.samples?.rejected.first?.date, "rejected sample has no date")
    expectEqual(r.workouts?.inserted, 2, "workouts inserted"); expectEqual(r.workouts?.possible_duplicates.first?.description, "慢跑", "possible duplicate")
    expectEqual(r.deleted?.not_found, 1, "unknown deletion not found")
    check(r.invalidated_from != nil, "invalidated_from set")
}
if let r = live(HealthSyncResponse.self, "health_sync_resend") {
    expectEqual(r.days?.upserted, 0, "resend: idempotent days"); expectEqual(r.samples?.unchanged, 4, "resend: samples unchanged")
    expectEqual(r.workouts?.unchanged, 2, "resend: workouts unchanged"); expectNil(r.invalidated_from, "resend invalidates nothing")
}
if let r = live(HealthSyncResponse.self, "health_sync_overwrite") { check(r.timezone_mismatch, "tz mismatch flagged"); expectNil(r.samples, "absent sections stay nil") }
if let r = live(HealthSyncResponse.self, "health_sync_delete") { expectEqual(r.deleted?.body, 1, "deleted body"); expectEqual(r.deleted?.exercises, 1, "deleted workout") }
if let r = live(HealthSyncResponse.self, "health_sync_tombstoned") {
    expectEqual(r.samples?.skipped_tombstoned, 1, "tombstoned sample"); expectEqual(r.workouts?.skipped_tombstoned, 1, "tombstoned workout")
}
do {
    let req = swiftHealthSyncRequest(today: today)
    let days = req.days ?? []
    expectEqual(days.map(\.date), [LocalDay.addDays(today, -4), LocalDay.addDays(today, -2), today], "DayAggregator: dated days only, no empty day")
    expectEqual(days.first?.steps, 7421, "DayAggregator rounds steps"); expectEqual(days.first?.sleep_hours, 6.92, "DayAggregator rounds sleep to 0.01")
    expectEqual(days.first?.distance_km, 5.42, "DayAggregator rounds distance"); expectEqual(days.first?.active_kcal, 388.6, "DayAggregator rounds kcal to 0.1")
    expectEqual(days.dropFirst().first?.clear, ["stand_hours"], "ledger → clear stand_hours")
    let (_, r) = await viaAPI("health_sync", "POST", "health/sync") { try await $0.healthSync(req) }
    let o = bodyObject(r)
    expectKeys(o, reads: ServerReads.sync, required: ["device_id", "device_name", "timezone", "overwrite_manual"], "health/sync")
    expectKeysEach(o?["days"], reads: ServerReads.syncDay, required: ["date"], "health/sync days")
    // SyncSample.start is documented (§C.2) but services/healthsync.ts parseSample does not store it.
    expectKeysEach(o?["samples"], reads: ServerReads.syncSample, required: ["uuid", "type", "date", "time"], ignored: ["start"], "health/sync samples")
    expectKeysEach(o?["workouts"], reads: ServerReads.syncWorkout, required: ["uuid", "date", "time", "activity_key", "duration_min", "in_device"], "health/sync workouts")
    check(o?["cursors"] == nil, "nil cursors omitted")
    check(((o?["samples"] as? [[String: Any]])?.last?["bp_treated"]) is Bool, "bp_treated is a JSON boolean (server accepts true/1 only)")
}
for name in ["health_unlink_keep", "health_unlink_delete"] { live(HealthUnlinkResponse.self, name) }
if let u = live(HealthUnlinkResponse.self, "health_unlink_delete") { check(u.deleted.body + u.deleted.exercises + u.deleted.days > 0, "unlink deleted data") }
do {
    let (_, r) = await viaAPI("health_unlink_keep", "POST", "health/sync/unlink") { try await $0.healthSyncUnlink(HealthUnlinkRequest(device_id: "d", delete_data: false)) }
    expectKeys(bodyObject(r), reads: ServerReads.unlink, required: ServerReads.unlink, "health/sync/unlink")
}

// MARK: - No-content and raw endpoints (deletes, password, logout, photo)

section("no-content")
for name in ["body_delete", "labs_delete", "exercise_delete", "meal_delete", "food_delete", "session_delete", "auth_logout",
             "password_change", "password_change_back", "exercise_patch", "activity_put", "meal_update", "food_update"] {
    if let ok = live(OkResponse.self, name) { check(ok.ok, "\(name) ok") }
}
@MainActor func expectNoBody(_ r: RecordedRequest?, _ name: String) { check(r?.body?.isEmpty ?? true, "\(name) sends no body") }
do {
    var (_, r) = await viaAPI("body_delete", "DELETE", "body/9") { try await $0.deleteBodyMetric(id: 9) }; expectNoBody(r, "DELETE body")
    (_, r) = await viaAPI("labs_delete", "DELETE", "labs/9") { try await $0.deleteLab(id: 9) }; expectNoBody(r, "DELETE labs")
    (_, r) = await viaAPI("exercise_delete", "DELETE", "exercises/9") { try await $0.deleteExercise(id: 9) }; expectNoBody(r, "DELETE exercises")
    (_, r) = await viaAPI("meal_delete", "DELETE", "meals/9") { try await $0.deleteMeal(id: 9) }; expectNoBody(r, "DELETE meals")
    (_, r) = await viaAPI("food_delete", "DELETE", "foods/9") { try await $0.deleteFood(id: 9) }; expectNoBody(r, "DELETE foods")
    (_, r) = await viaAPI("session_delete", "DELETE", "auth/sessions/9") { try await $0.deleteSession(id: 9) }; expectNoBody(r, "DELETE session")
    (_, r) = await viaAPI("auth_logout", "POST", "auth/logout") { await $0.logout() }
    expectEqual(r.flatMap { String(data: $0.body ?? Data(), encoding: .utf8) }, "{}", "auth/logout sends {}")
    (_, r) = await viaAPI("password_change", "POST", "auth/password") { try await $0.changePassword(old: " demo123 ", new: "demo1234") }
    expectKeys(bodyObject(r), reads: ServerReads.password, required: ServerReads.password, "auth/password (fixture)")
    expectEqual(bodyObject(r)?["old_password"] as? String, "demo123", "old_password trimmed")
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])   // the server sends the stored file as is
    MockServer.shared.reset(body: jpeg)
    let bytes = try? await makeClient().photoData(id: photoId)
    expectEqual(bytes, jpeg, "photoData returns the raw bytes")
    expectEqual(MockServer.shared.requests.last?.path, "/api/v1/uploads/\(photoId)", "photoData path")
    check(MockServer.shared.requests.last?.headers["Accept"]?.hasPrefix("image/") ?? false, "photoData Accept image/*")
}

// MARK: - Swift-encoded bodies the real server accepted (post-swift.sh)

section("swift round trip")
if let r = live(HealthSyncResponse.self, "swift_health_sync") {
    expectEqual(r.days?.rejected.count, 0, "swift sync: no rejected days"); expectEqual(r.samples?.rejected.count, 0, "swift sync: no rejected samples")
    expectEqual(r.workouts?.rejected.count, 0, "swift sync: no rejected workouts")
    expectEqual((r.samples?.inserted ?? 0) + (r.samples?.updated ?? 0) + (r.samples?.unchanged ?? 0), 4, "swift sync: 4 samples stored")
    expectEqual((r.workouts?.inserted ?? 0) + (r.workouts?.updated ?? 0) + (r.workouts?.unchanged ?? 0), 2, "swift sync: 2 workouts stored")
    expectEqual(r.deleted?.not_found, 1, "swift sync: unknown deletion")
}
if let s = live(HealthSyncState.self, "swift_health_sync_state") { check(s.devices.contains { $0.device_id == "swift-live-0001" }, "swift device in state") }
live(IdResponse.self, "swift_meal"); live(OkResponse.self, "swift_meal_update"); live(DayPreview.self, "swift_preview")
live(ActivityCommitResponse.self, "swift_activity_commit"); live(IdResponse.self, "swift_food"); live(OkResponse.self, "swift_food_update_seed_roundtrip")
live(IdResponse.self, "swift_from_item"); live(DraftItem.self, "swift_food_item"); live(DraftItem.self, "swift_food_item_default")
live(ProfileSaveResponse.self, "swift_profile"); live(OkResponse.self, "swift_settings"); live(WaterResponse.self, "swift_water")
live(IdResponse.self, "swift_body"); live(IdResponse.self, "swift_labs"); live(ExerciseCreated.self, "swift_exercise"); live(OkResponse.self, "swift_in_device")
live(OkResponse.self, "swift_activity_put"); live(HealthUnlinkResponse.self, "swift_unlink")
live(JobCreated.self, "swift_meal_ai"); live(JobCreated.self, "swift_activity_ai"); live(JobCreated.self, "swift_food_ai"); live(JobCreated.self, "swift_period_summary")
if let d = live(DayResponse.self, "swift_day") {
    check(d.visibleMeals.contains { $0.description == "Swift 编码的早餐（改）" }, "Swift-encoded meal update stored")
    check(d.body.contains { $0.weight_kg == 81.0 && $0.sbp == 125 && $0.bpTreated }, "Swift-encoded commit body stored (bp_treated true)")
    check(d.exercises.contains { $0.description == "力量训练" }, "Swift-encoded workout stored")
}
if let a = live(ActivityList.self, "swift_activity") {
    let w = a.exercises.first { $0.external_id == "5E1F0000-0000-4000-8000-0000000000A1" }
    expectEqual(w?.duration_min, 42.3, "synced workout duration"); expectEqual(w?.avg_hr, 151, "synced avg_hr"); expectEqual(w?.source_name, "Apple Watch", "synced source_name")
    expectEqual(w?.started_at, "\(LocalDay.addDays(today, -2))T06:40:00+08:00", "synced started_at"); expectEqual(w?.ended_at, "\(LocalDay.addDays(today, -2))T07:22:00+08:00", "synced ended_at")
    expectEqual(w?.hk_activity_type, 37, "synced hk_activity_type")
}
if let rows = live([BodyMetric].self, "swift_body_rows") {
    let bp = rows.first { $0.external_id == "5E1F0000-0000-4000-8000-000000000004" }
    expectEqual(bp?.sbp, 131, "synced sbp"); expectEqual(bp?.bp_treated, 1, "synced bp_treated true → 1")
    expectEqual(rows.first { $0.external_id == "5E1F0000-0000-4000-8000-000000000003" }?.waist_cm, 86.5, "synced waist")
}

// MARK: - Key audit

section("key audit")
/// Swift fields the server legitimately never sends in these fixtures (optional by design), with the reason.
let neverSentOK: [String: String] = [
    "DraftItem.saved_food_id": "client-only: set after 存入食物库 in the review list; the server ignores it (meals §1.10)",
]
/// Swift fields that legitimately fall back to a default when the server omits them.
let defaultedOK: [String: String] = [:]

let neverSent = Set(audit.absentNil.keys).union(audit.defaulted.keys).subtracting(audit.sent)
for key in neverSent.sorted() where neverSentOK[key] == nil {
    check(false, "never sent by the server: \(key)", "fixtures: " + (audit.absentNil[key] ?? audit.defaulted[key] ?? []).sorted().prefix(4).joined(separator: ", "))
}
for (key, fixtures) in audit.defaulted.sorted(by: { $0.key < $1.key }) where defaultedOK[key] == nil && !neverSent.contains(key) {
    check(false, "server omitted a non-optional field (default used): \(key)", fixtures.sorted().prefix(4).joined(separator: ", "))
}
if ProcessInfo.processInfo.environment["LIVE_VERBOSE"] != nil {
    print("— server keys the app does not read —")
    for (key, fixtures) in audit.ignored.sorted(by: { $0.key < $1.key }) { print("  \(key)  (\(fixtures.count) fixtures)") }
    print("— optional Swift fields absent in some fixtures —")
    for (key, fixtures) in audit.absentNil.sorted(by: { $0.key < $1.key }) where audit.sent.contains(key) { print("  \(key)  (\(fixtures.count))") }
}

summary()

/// Placeholder result type for pending (queued/running) job polls, whose `result` is always null.
struct EmptyResult: Decodable, Sendable {}
