import Foundation

// MARK: - Uploads, AI jobs, meals, water, food library (meals §2)

extension APIClient {
    /// Most photos per request and per meal (meals §2.1).
    nonisolated static let maxPhotos = 6

    /// `POST uploads` multipart, field `photos`, filenames `photo{n}.jpg`, `image/jpeg` (meals §2.1). Pass JPEG bytes
    /// (`ImageTranscoder` output). At most 6 per request; more is rejected here because the server would answer 500.
    func uploadPhotos(jpegs: [Data]) async throws -> [UploadedPhoto] {
        guard !jpegs.isEmpty else { return [] }
        guard jpegs.count <= Self.maxPhotos else { throw APIError.http(status: 400, message: "最多上传 \(Self.maxPhotos) 张照片") }
        let files = jpegs.enumerated().map { i, data in
            MultipartFile(fieldName: "photos", filename: "photo\(i + 1).jpg", mimeType: "image/jpeg", data: data)
        }
        let res: UploadResponse = try await upload("uploads", form: MultipartFormData(), files: files)
        return res.photos
    }

    /// `GET uploads/{id}` with the Bearer header (meals §2.2) → raw image bytes. Only the owner's photos resolve;
    /// anything else is a 404 `不存在`.
    func photoData(id: String) async throws -> Data {
        guard Self.isValidPhotoId(id) else { throw APIError.http(status: 404, message: "不存在") }
        return try await rawData(absolutePath: "/api/v1/uploads/\(id)")
    }

    /// `GET ai/status` (meals §2.3).
    func aiStatus() async throws -> AIStatus { try await send(.get, "ai/status") }

    /// `POST ai/meal` (meals §2.4) → job id; the result is a `MealDraft`.
    func startMealAI(_ req: MealAIRequest) async throws -> String {
        let res: JobCreated = try await send(.post, "ai/meal", body: AnyEncodable(req))
        return res.job_id
    }

    /// `POST ai/food` (meals §2.5) → job id; the result is a `FoodDraft`.
    func startFoodAI(_ req: FoodAIRequest) async throws -> String {
        let res: JobCreated = try await send(.post, "ai/food", body: AnyEncodable(req))
        return res.job_id
    }

    /// `GET ai/jobs/{id}` (meals §2.7). Use `JobPoller` rather than calling this in a loop.
    func job<T: Decodable & Sendable>(id: String, as type: T.Type) async throws -> Job<T> {
        try await send(.get, "ai/jobs/\(id)")
    }

    /// `POST meals` (meals §2.9) → new meal id.
    func createMeal(_ body: MealBody) async throws -> Int {
        let res: IdResponse = try await send(.post, "meals", body: AnyEncodable(body))
        return res.id
    }

    /// `PUT meals/{id}` (meals §2.10). The server ignores `photos` / `ai_summary` / `ai_model` on update.
    func updateMeal(id: Int, _ body: MealBody) async throws { try await sendNoContent(.put, "meals/\(id)", body: AnyEncodable(body)) }

    /// `DELETE meals/{id}` (meals §2.11).
    func deleteMeal(id: Int) async throws { try await sendNoContent(.delete, "meals/\(id)") }

    /// `GET meals/recent-items` (meals §2.13), without the water item `饮用水`.
    func recentItems() async throws -> [RecentItem] {
        let rows: [RecentItem] = try await send(.get, "meals/recent-items")
        return rows.filter { $0.name != "饮用水" }
    }

    /// `POST water {ml, date}` (meals §2.14) → the day's new total in ml.
    func addWater(ml: Double, date: String) async throws -> Double {
        let res: WaterResponse = try await send(.post, "water", body: AnyEncodable(WaterBody(ml: ml, date: date)))
        return res.total_ml
    }

    /// `GET foods?q&scope` (meals §2.15). `q` is omitted when empty.
    func foods(query: String?, scope: FoodScope) async throws -> [Food] {
        let q = query.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
        return try await send(.get, "foods", query: Self.items(["q": q, "scope": scope.rawValue]))
    }

    /// `GET foods/{id}` (meals §2.16).
    func food(id: Int) async throws -> Food { try await send(.get, "foods/\(id)") }

    /// `POST foods` (meals §2.17) → new food id.
    func createFood(_ input: FoodInput) async throws -> Int {
        let res: IdResponse = try await send(.post, "foods", body: AnyEncodable(input))
        return res.id
    }

    /// `PUT foods/{id}` (meals §2.18): full replace, round-trip every field.
    func updateFood(id: Int, _ input: FoodInput) async throws { try await sendNoContent(.put, "foods/\(id)", body: AnyEncodable(input)) }

    /// `DELETE foods/{id}` (meals §2.19).
    func deleteFood(id: Int) async throws { try await sendNoContent(.delete, "foods/\(id)") }

    /// `POST foods/{id}/item {grams?}` (meals §2.20) → a ready-to-save `DraftItem`. nil grams → `serving_g ?? 100`.
    func foodItem(id: Int, grams: Double?) async throws -> DraftItem {
        try await send(.post, "foods/\(id)/item", body: AnyEncodable(FoodItemRequest(grams: grams)))
    }

    /// `POST foods/from-item` (meals §2.21) → new food id.
    func saveFoodFromItem(_ req: FromItemRequest) async throws -> Int {
        let res: IdResponse = try await send(.post, "foods/from-item", body: AnyEncodable(req))
        return res.id
    }

    /// Upload ids match `^[\w.-]+$` (meals §2.1–§2.2).
    nonisolated static func isValidPhotoId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { s in
            switch s {
            case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "-": return true
            default: return false
            }
        } && id != "." && id != ".."
    }
}
