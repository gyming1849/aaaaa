import SwiftUI
import Observation

// MARK: - Foods library state (web2 §5.9; meals §1.12, §2.15–§2.19, §6.5)

/// List state for `FoodsScreen` plus the delete / save calls shared by the detail and editor sheets.
@MainActor @Observable final class FoodsModel {
    /// `GET /foods` result for the last query (≤ 200, own foods first). `nil` until the first load finishes.
    private(set) var foods: [Food]?
    private(set) var isLoading = false
    /// Load failure shown as a warning banner with 重试 (the web fails silently).
    private(set) var error: String?
    /// Standards meta fetched here only when `app.meta` is unavailable (the nutrient table and editor need it).
    private(set) var fallbackMeta: Meta?
    private(set) var metaError: String?
    private(set) var isLoadingMeta = false

    /// Query of the most recent load; responses for older queries are dropped.
    @ObservationIgnored private var lastQuery: FoodsQuery?

    struct FoodsQuery: Hashable, Sendable {
        let text: String
        let scope: FoodScope
    }

    init() {}

    /// `GET /foods?q&scope` (`q` omitted when blank). Keeps the previous list visible while loading.
    func load(app: AppState, query: String, scope: FoodScope) async {
        let key = FoodsQuery(text: query, scope: scope)
        lastQuery = key
        isLoading = true
        defer { if lastQuery == key { isLoading = false } }
        do {
            let rows = try await app.api.foods(query: query, scope: scope)
            guard !Task.isCancelled, lastQuery == key else { return }
            foods = rows
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, lastQuery == key else { return }
            self.error = APIError.from(error).message
        }
    }

    /// Re-runs the last query (pull to refresh, after a save or delete).
    func reload(app: AppState) async {
        let key = lastQuery ?? FoodsQuery(text: "", scope: .all)
        await load(app: app, query: key.text, scope: key.scope)
    }

    /// `DELETE /foods/{id}` → toast `已删除`. Removes the row locally on success; errors are toasted.
    func delete(app: AppState, food: Food) async -> Bool {
        do {
            try await app.api.deleteFood(id: food.id)
            foods?.removeAll { $0.id == food.id }
            app.toasts.show("已删除")
            return true
        } catch {
            app.toasts.error(error)
            return false
        }
    }

    /// `PUT /foods/{id}` (full replace, every field round-tripped) or `POST /foods`, with `aliases` split on `[,，、]+`.
    /// Toast `已保存到食物库` on success; errors are toasted.
    func save(app: AppState, draft: FoodsEditorDraft) async -> Bool {
        let body = draft.requestBody()
        do {
            if let id = draft.foodId {
                try await app.api.updateFood(id: id, body)
            } else {
                _ = try await app.api.createFood(body)
            }
            app.toasts.show("已保存到食物库")
            return true
        } catch {
            app.toasts.error(error)
            return false
        }
    }

    /// The nutrient definitions source: `app.meta`, or a copy fetched here when the app-wide load failed.
    func meta(_ app: AppState) -> Meta? { app.meta ?? fallbackMeta }

    /// Makes sure standards meta is available for the detail table and the editor.
    func ensureMeta(app: AppState, force: Bool = false) async {
        if !force, meta(app) != nil { return }
        guard !isLoadingMeta else { return }
        isLoadingMeta = true
        defer { isLoadingMeta = false }
        metaError = nil
        await app.ensureMeta(force: force)
        if app.meta != nil { return }
        do {
            fallbackMeta = try await app.api.standardsMeta()
        } catch is CancellationError {
            return
        } catch {
            metaError = APIError.from(error).message
        }
    }
}

// MARK: - Editor state

/// What the food editor edits (web `EditState`): the full `FoodInput` plus the alias text as typed.
/// `foodId` set → `PUT /foods/{id}` (title `编辑食物`), otherwise `POST /foods` (title `保存到食物库`).
struct FoodsEditorDraft: Identifiable, Sendable {
    let id = UUID()
    var foodId: Int?
    var input: FoodInput
    /// Comma-separated aliases as shown in the text field; split on `[,，、]+` when saving.
    var aliasesText: String

    init(foodId: Int?, input: FoodInput, aliasesText: String) {
        self.foodId = foodId
        var input = input
        // The server stores any category outside CATEGORY_ZH as `other`; show the picker on that value.
        if !Vocab.categories.contains(where: { $0.key == input.category }) { input.category = "other" }
        self.input = input
        self.aliasesText = aliasesText
    }

    /// `手动录入`: the web's blank state (meals §6.5 defaults).
    static func blank() -> FoodsEditorDraft {
        FoodsEditorDraft(foodId: nil, input: .blank(), aliasesText: "")
    }

    /// `编辑` from the detail view: every field of the food (nulls become `""`, `serving_g ?? 100`, `category ?? "other"`),
    /// including the non-editable `groups100`, `hazards100`, `label_fields` and `source_urls`.
    init(food: Food) {
        var input = food.toInput()
        input.serving_g = food.serving_g ?? 100
        self.init(foodId: food.id, input: input, aliasesText: food.aliases)
    }

    /// AI lookup result: `{...blank, ...draft, aliases: draft.aliases.join(","), source_urls: draft.sources}` (web2 §5.9.3).
    init(draft: FoodDraft) {
        self.init(foodId: nil, input: FoodInput(draft: draft), aliasesText: draft.aliases.joined(separator: ","))
    }

    /// `显示全部 43 项` starts on when editing an existing food or when the data did not come from manual entry.
    var showsAllNutrientsInitially: Bool { foodId != nil || input.source != "manual" }

    var canSave: Bool { !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The request body: the complete state with `aliases` re-split into an array.
    func requestBody() -> FoodInput {
        var body = input
        body.aliases = FoodInput.splitAliases(aliasesText)
        return body
    }
}

// MARK: - Shared presentation helpers

enum FoodsText {
    /// `SOURCE_ZH[source] ?? source`.
    static func source(_ key: String) -> String { Vocab.foodSourceZh[key] ?? key }

    /// Card subtitle: `[brand, serving_desc || (serving_g ? "一份 {fmt(serving_g)} g" : "")]`, empties dropped, joined by ` · `.
    static func subtitle(_ food: Food) -> String {
        let serving: String
        if let desc = food.serving_desc, !desc.isEmpty {
            serving = desc
        } else if let g = food.serving_g, g != 0 {
            serving = "一份 \(fmt(g)) g"
        } else {
            serving = ""
        }
        return [food.brand ?? "", serving].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `NOVA {n} · {zh}` (picker rows use `{n} · {zh}`).
    static func novaOption(_ n: Int) -> String { "\(n) · \(Vocab.novaZh[n] ?? "")" }

    /// Non-empty trimmed text, or nil (`""` and `null` are equivalent for brand, notes, ingredients and serving_desc).
    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
