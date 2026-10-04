import SwiftUI

// MARK: - ItemEditor (web1 §5.3, meals §4, §6.2): one editable food row of the review list.
// Name, grams (rescale from per-100 g), 调整 toggle, delete; macro line; chips (portion, category, NOVA, 食物库,
// 置信度低, removable hazard chips, 加工肉 / 红肉); 存入食物库 or 已存入食物库; notes; the expanded ItemAdjustPanel.

struct ItemEditorView: View {
    @Environment(AppState.self) private var app
    let item: DraftItem
    /// Applies a transform to the current item in the model (so quick successive edits never use a stale copy).
    let edit: @MainActor ((DraftItem) -> DraftItem) -> Void
    let onRemove: @MainActor () -> Void
    let onSave: @MainActor () -> Void
    @State private var expanded = false

    init(item: DraftItem, edit: @escaping @MainActor ((DraftItem) -> DraftItem) -> Void,
         onRemove: @escaping @MainActor () -> Void, onSave: @escaping @MainActor () -> Void) {
        self.item = item
        self.edit = edit
        self.onRemove = onRemove
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: name + delete; grams + 调整 (the web's single row wraps the same way on phones)
            HStack(spacing: 8) {
                LogMealTextInput("食物名称", text: nameBinding, size: .sm, weight: .semibold)
                    .accessibilityLabel(Text("食物名称"))
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.nl(.danger, size: .sm, iconOnly: true))
                .accessibilityLabel(Text("删除这一项"))
            }
            HStack(spacing: 8) {
                LogMealDecimalField(value: item.amount_g, decimals: 1, unit: "g", accessibilityLabel: "克数") { v in
                    guard let v, v > 0 else { return }   // ≤ 0 or blank: ignored, like the web
                    edit { $0.amount_g == v ? $0 : ItemMath.rescale($0, grams: v) }
                }
                .frame(width: 120)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                    Text("调整")
                }
                .buttonStyle(.nl(expanded ? .primary : .plain, size: .sm))
                .accessibilityAddTraits(expanded ? .isSelected : [])
                Spacer(minLength: 0)
            }

            LogMealMacroLine([
                .init("", fmt(item.nutrients.v("energy_kcal")), " kcal"),
                .init("蛋白 ", fmt(item.nutrients.v("protein_g"), 1), "g"),
                .init("碳水 ", fmt(item.nutrients.v("carb_g"), 1), "g"),
                .init("脂肪 ", fmt(item.nutrients.v("fat_g"), 1), "g"),
                .init("钠 ", fmt(item.nutrients.v("sodium_mg")), "mg"),
                .init("添加糖 ", fmt(item.nutrients.v("added_sugars_g"), 1), "g"),
                .init("纤维 ", fmt(item.nutrients.v("fiber_g"), 1), "g"),
            ])

            chips
            libraryAction

            if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(verbatim: notes)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                Rectangle().fill(Theme.hair).frame(height: 1)
                    .padding(.top, 4)
                ItemAdjustPanel(item: item, edit: edit)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    // MARK: Pieces

    private var nameBinding: Binding<String> {
        Binding(get: { item.name }, set: { name in
            edit { current in
                var copy = current
                copy.name = name
                return copy
            }
        })
    }

    @ViewBuilder private var chips: some View {
        let hasChips = !(item.amount_desc ?? "").isEmpty || !(item.category ?? "").isEmpty || item.nova_group != nil
            || item.food_id != nil || item.confidence == "low" || !item.hazards.isEmpty
            || item.groups.v("processed_meat_g") > 0 || item.groups.v("red_meat_g") > 0
        if hasChips {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if let desc = item.amount_desc, !desc.isEmpty {
                    Chip(desc)
                }
                if let category = item.category, !category.isEmpty {
                    Chip(Vocab.categoryZh(category) ?? category)
                }
                if let nova = item.nova_group, nova != 0 {
                    Chip(Vocab.novaLabel(nova))
                }
                if item.food_id != nil {
                    Chip("食物库", icon: "books.vertical", style: .accent)
                }
                if item.confidence == "low" {
                    Chip("置信度低")
                }
                ForEach(Array(item.hazards.enumerated()), id: \.offset) { index, hazard in
                    let def = app.hazardDef(hazard.key)
                    Chip(def?.zh ?? hazard.key, icon: "exclamationmark.shield", style: .iarc(def?.iarc ?? "2B"))
                        .removable(label: "移除该风险标记") {
                            edit { ItemMath.removeHazard($0, at: index) }
                        }
                }
                if item.groups.v("processed_meat_g") > 0 {
                    Chip("加工肉 \(fmt(item.groups.v("processed_meat_g"))) g", icon: "exclamationmark.shield", style: .iarc("1"))
                }
                if item.groups.v("red_meat_g") > 0 {
                    Chip("红肉 \(fmt(item.groups.v("red_meat_g"))) g", style: .iarc("2A"))
                }
            }
        }
    }

    /// `存入食物库（推荐）` (primary when `save_suggested`) / `存入食物库`, or the `已存入食物库` chip; right-aligned.
    @ViewBuilder private var libraryAction: some View {
        if item.food_id == nil, item.saved_food_id == nil {
            HStack {
                Spacer(minLength: 0)
                Button(action: onSave) {
                    Image(systemName: "bookmark")
                    Text(item.save_suggested ? "存入食物库（推荐）" : "存入食物库")
                }
                .buttonStyle(.nl(item.save_suggested ? .primary : .plain, size: .sm))
            }
        } else if item.saved_food_id != nil {
            HStack {
                Spacer(minLength: 0)
                Chip("已存入食物库", icon: "checkmark", style: .accent)
            }
        }
    }
}
