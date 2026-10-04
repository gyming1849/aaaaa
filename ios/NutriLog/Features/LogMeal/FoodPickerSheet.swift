import SwiftUI

// MARK: - FoodPicker, modal `从食物库添加` (web1 §5.6, meals §2.15, §2.20, §4.5)
// Search (200 ms debounce, `GET /foods?q&scope=all`) → pick a food → `吃了多少` grams (+ 0.5/1/1.5/2 份 chips) →
// `添加 {g} g` = `POST /foods/{id}/item {grams}`; the returned DraftItem goes to the review list.

struct FoodPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onPick: @MainActor (DraftItem) -> Void

    @State private var query = ""
    @State private var foods: [Food]?
    @State private var loadError: String?
    @State private var reloadToken = 0
    @State private var selected: Food?
    @State private var grams: Double? = 100
    @State private var isAdding = false
    @FocusState private var searchFocused: Bool

    init(onPick: @escaping @MainActor (DraftItem) -> Void) { self.onPick = onPick }

    /// Server range for `grams` (meals §2.20).
    static let gramsRange: ClosedRange<Double> = 0.1...20000

    private var gramsValue: Double { grams ?? 0 }
    private var gramsValid: Bool { Self.gramsRange.contains(gramsValue) }
    private var gramsMessage: String? {
        if gramsValue < Self.gramsRange.lowerBound { return "克数不能小于 0.1" }
        if gramsValue > Self.gramsRange.upperBound { return "克数不能大于 20000" }
        return nil
    }

    var body: some View {
        SheetScaffold(title: "从食物库添加", primary: primaryAction) {
            VStack(alignment: .leading, spacing: 0) {
                if let selected {
                    selectedView(selected)
                } else {
                    searchView
                }
            }
            .toolbar { LogMealKeyboardDone() }
        }
        .task(id: "\(query)\u{1F}\(reloadToken)") { await search() }
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            if selected == nil { searchFocused = true }
        }
    }

    private var primaryAction: SheetAction? {
        guard selected != nil else { return nil }
        return SheetAction(title: "添加 \(fmt(gramsValue)) g", icon: "plus", isEnabled: gramsValid, isBusy: isAdding) {
            Task { await add() }
        }
    }

    // MARK: Search state

    private var searchView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("搜索", text: $query, prompt: Text("搜索名称、品牌、别名…").foregroundStyle(Theme.ink3))
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
            }
            .logMealInputChrome(.md, focused: searchFocused)

            if let loadError {
                HStack(alignment: .center, spacing: 10) {
                    Text(verbatim: loadError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { reloadToken += 1 }
                        .buttonStyle(.nl(.plain, size: .sm))
                }
                .nlBanner(.warn)
            } else if let foods = foods.map(app.blocked.visible) {
                if foods.isEmpty {
                    EmptyState("食物库里没有匹配项。可以在“食物库”里用 AI 联网查询或拍营养成分表来添加。")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(foods.enumerated()), id: \.element.id) { index, food in
                            row(food)
                            if index < foods.count - 1 {
                                Rectangle().fill(Theme.hair).frame(height: 1)
                            }
                        }
                    }
                }
            } else {
                LoadingView()
            }
        }
    }

    private func row(_ food: Food) -> some View {
        Button {
            searchFocused = false
            selected = food
            grams = food.serving_g ?? 100
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: food.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink1)
                    if let brand = food.brand, !brand.isEmpty {
                        Text(verbatim: brand)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                Text(verbatim: Self.subtitle(food))
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `每 100 g {kcal} kcal · 钠 {mg} mg · 一份 {g} g · 来自 {owner_name}` (the last two parts only when present / not mine).
    static func subtitle(_ food: Food) -> String {
        var s = "每 100 g \(fmt(food.per100["energy_kcal"])) kcal · 钠 \(fmt(food.per100["sodium_mg"])) mg"
        if let serving = food.serving_g, serving != 0 { s += " · 一份 \(fmt(serving)) g" }
        if !food.mine { s += " · 来自 \(food.owner_name ?? "")" }
        return s
    }

    // MARK: Selected state

    private func selectedView(_ food: Food) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: food.name)
                    .font(Theme.Font.h3)
                    .foregroundStyle(Theme.ink)
                let sub = "\(food.brand ?? "") \(food.serving_desc ?? "")".trimmingCharacters(in: .whitespaces)
                if !sub.isEmpty {
                    Text(verbatim: sub)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                }
            }

            LogMealField("吃了多少") {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    LogMealDecimalField(value: grams, decimals: 4, unit: "g", accessibilityLabel: "吃了多少", size: .md,
                                        autoFocus: true) { grams = $0 }
                        .frame(width: 140)
                    if let serving = food.serving_g, serving != 0 {
                        ForEach([0.5, 1, 1.5, 2], id: \.self) { m in
                            let target = serving * m
                            Button {
                                grams = target
                            } label: {
                                Chip("\(DSFormat.js(m)) 份", style: grams == target ? .selected : .plain)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(grams == target ? .isSelected : [])
                        }
                    }
                }
                if let gramsMessage {
                    Text(verbatim: gramsMessage)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.criticalText)
                }
            }

            let g = gramsValue
            LogMealMacroLine([
                .init("", fmt(food.per100.v("energy_kcal") * g / 100), " kcal"),
                .init("蛋白 ", fmt(food.per100.v("protein_g") * g / 100, 1), "g"),
                .init("钠 ", fmt(food.per100.v("sodium_mg") * g / 100), "mg"),
                .init("添加糖 ", fmt(food.per100.v("added_sugars_g") * g / 100, 1), "g"),
            ])

            Button {
                selected = nil
            } label: {
                Text("← 返回搜索")
            }
            .buttonStyle(.nl(.ghost, size: .sm))
        }
    }

    // MARK: Actions

    private func search() async {
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await app.api.foods(query: q.isEmpty ? nil : q, scope: .all)
            guard !Task.isCancelled else { return }
            foods = result
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = APIError.from(error).message
        }
    }

    private func add() async {
        guard let food = selected, gramsValid, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        do {
            let item = try await app.api.foodItem(id: food.id, grams: gramsValue)
            onPick(item)
            dismiss()
        } catch {
            app.toasts.error(error)
        }
    }
}
