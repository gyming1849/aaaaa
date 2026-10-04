import SwiftUI

// MARK: - SaveFoodModal, modal `存入食物库` (web1 §5.7, meals §2.21)
// Saves a reviewed draft item to the library per 100 g (`POST /foods/from-item`). On success the item gets
// `saved_food_id` (its `food_id` stays nil, so the meal is saved with its own numbers).

struct SaveFoodSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: DraftItem
    let sources: [SourceLink]
    let onSaved: @MainActor (Int) -> Void

    @State private var name: String
    @State private var brand = ""
    @State private var serving: Double?
    @State private var aliases = ""
    @State private var visibility = "private"
    @State private var busy = false

    init(item: DraftItem, sources: [SourceLink], onSaved: @escaping @MainActor (Int) -> Void) {
        self.item = item
        self.sources = sources
        self.onSaved = onSaved
        _name = State(initialValue: item.name)
        _serving = State(initialValue: item.amount_g.isFinite ? item.amount_g.rounded(.toNearestOrAwayFromZero) : nil)
    }

    /// Server range for `serving_g` (meals §2.17).
    static let servingRange: ClosedRange<Double> = 0.1...10000

    var body: some View {
        SheetScaffold(title: "存入食物库",
                      primary: SheetAction(title: "保存", icon: "bookmark", isBusy: busy) { Task { await save() } }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("按每 100 g 的营养数据保存。下次记录时说出名称会自动匹配，也可以在“从食物库添加”里直接选择克数。")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                LogMealField("名称") {
                    LogMealTextInput("名称", text: $name)
                }
                LogMealField("品牌（可选）") {
                    LogMealTextInput("品牌（可选）", text: $brand)
                }
                LogMealField("一份的重量") {
                    LogMealDecimalField(value: serving, decimals: 4, unit: "g", accessibilityLabel: "一份的重量", size: .md) { serving = $0 }
                }
                LogMealField("别名（逗号分隔）") {
                    LogMealTextInput("别名（逗号分隔）", text: $aliases, prompt: "如：螺狮粉, luosifen")
                }
                LogMealField("可见范围") {
                    Seg([SegOption(value: "private", label: "仅自己"), SegOption(value: "public", label: "所有成员可用")],
                        selection: $visibility)
                }

                LogMealMacroLine([
                    .init("每 100 g：", fmt(item.per100.nutrients["energy_kcal"]), " kcal"),
                    .init("蛋白 ", fmt(item.per100.nutrients["protein_g"], 1), "g"),
                    .init("钠 ", fmt(item.per100.nutrients["sodium_mg"]), "mg"),
                ])
            }
            .toolbar { LogMealKeyboardDone() }
        }
    }

    /// Web `aliases.split(/[,，、\s]+/).filter(Boolean)`.
    static func splitAliases(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func save() async {
        guard !busy else { return }
        // Same checks and wording as the server (meals §5), without the round trip.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            app.toasts.error("名称不能为空")
            return
        }
        guard let servingG = serving, servingG >= Self.servingRange.lowerBound else {
            app.toasts.error("每份重量不能小于 0.1")
            return
        }
        guard servingG <= Self.servingRange.upperBound else {
            app.toasts.error("每份重量不能大于 10000")
            return
        }
        busy = true
        defer { busy = false }
        let req = FromItemRequest(item: item, name: name, brand: brand, aliases: Self.splitAliases(aliases), serving_g: servingG,
                                  serving_desc: item.amount_desc ?? "", source_urls: sources, visibility: visibility)
        do {
            let id = try await app.api.saveFoodFromItem(req)
            app.toasts.show("已存入食物库，下次可直接搜索选择")
            onSaved(id)
            dismiss()
        } catch {
            app.toasts.error(error)
        }
    }
}
