import SwiftUI

// MARK: - ItemEditor "调整" panel (web1 §5.3 item 5, meals §4.3, §6.2):
// library banner; 分类 / 加工程度（NOVA） / 份量描述; nutrients of this portion (MAIN 13 or `显示全部 n 项`);
// food groups; `补充风险标记：`. Nutrient, group and hazard edits unlink `food_id` (ItemMath); name, category,
// NOVA and portion description do not.

struct ItemAdjustPanel: View {
    @Environment(AppState.self) private var app
    let item: DraftItem
    let edit: @MainActor ((DraftItem) -> DraftItem) -> Void
    @State private var showAll = false

    init(item: DraftItem, edit: @escaping @MainActor ((DraftItem) -> DraftItem) -> Void) {
        self.item = item
        self.edit = edit
    }

    private let grid = [GridItem(.adaptive(minimum: 128), spacing: 8, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.food_id != nil {
                Banner("这一项来自食物库。修改具体数值后将按你填写的数值保存，不再与食物库条目关联。")
            }

            HStack(alignment: .top, spacing: 8) {
                LogMealField("分类") { categoryPicker }
                LogMealField("加工程度（NOVA）") { novaPicker }
            }
            LogMealField("份量描述") {
                LogMealTextInput("份量描述", text: amountDescBinding, size: .sm)
            }

            nutrientSection
            groupSection
            hazardPicker
        }
    }

    // MARK: Category / NOVA / portion description

    private var categoryPicker: some View {
        // Web `it.category ?? "other"`; an empty string (written through the API) also reads as `other`.
        let current = item.category.flatMap { $0.isEmpty ? nil : $0 } ?? "other"
        return Menu {
            Picker("分类", selection: Binding(get: { current }, set: { key in
                edit { cur in
                    var copy = cur
                    copy.category = key
                    return copy
                }
            })) {
                ForEach(Vocab.categories, id: \.key) { c in
                    Text(c.zh).tag(c.key)
                }
            }
        } label: {
            pickerLabel(Vocab.categoryZh(current) ?? current)
        }
        .accessibilityLabel(Text("分类"))
        .accessibilityValue(Text(Vocab.categoryZh(current) ?? current))
    }

    private var novaPicker: some View {
        Menu {
            Picker("加工程度（NOVA）", selection: Binding<Int?>(get: { item.nova_group }, set: { nova in
                edit { cur in
                    var copy = cur
                    copy.nova_group = nova
                    return copy
                }
            })) {
                Text("未知").tag(Int?.none)
                ForEach(1...4, id: \.self) { n in
                    Text("\(n) · \(Vocab.novaZh[n] ?? "")").tag(Int?.some(n))
                }
            }
        } label: {
            pickerLabel(novaText(item.nova_group))
        }
        .accessibilityLabel(Text("加工程度（NOVA）"))
        .accessibilityValue(Text(novaText(item.nova_group)))
    }

    private func novaText(_ nova: Int?) -> String {
        guard let nova, let zh = Vocab.novaZh[nova] else { return "未知" }
        return "\(nova) · \(zh)"
    }

    private func pickerLabel(_ text: String, placeholder: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .foregroundStyle(placeholder ? Theme.ink3 : Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink3)
        }
        .logMealInputChrome(.sm)
        .contentShape(Rectangle())
    }

    private var amountDescBinding: Binding<String> {
        Binding(get: { item.amount_desc ?? "" }, set: { text in
            edit { cur in
                var copy = cur
                copy.amount_desc = text
                return copy
            }
        })
    }

    // MARK: Nutrients (`营养素（这一份的总量）`)

    private struct Cell: Identifiable {
        let key: String
        let zh: String
        let unit: String
        let note: String?
        var id: String { key }
    }

    private var nutrientCells: [Cell] {
        if let defs = app.meta?.nutrients, !defs.isEmpty {
            return defs.filter { showAll || Vocab.itemEditorMainNutrients.contains($0.key) }
                .map { Cell(key: $0.key, zh: $0.zh, unit: $0.unit, note: nil) }
        }
        let keys = showAll ? Vocab.nutrientOrder : Vocab.itemEditorMainNutrients
        return keys.map { Cell(key: $0, zh: $0, unit: "", note: nil) }
    }

    private var nutrientTotal: Int { app.meta?.nutrients.count ?? Vocab.nutrientOrder.count }

    private var nutrientSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("营养素（这一份的总量）")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink1)
                Spacer(minLength: 8)
                Button {
                    showAll.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showAll ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16))
                            .foregroundStyle(showAll ? Theme.accent : Theme.ink3)
                        Text("显示全部 \(nutrientTotal) 项")
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showAll ? .isSelected : [])
            }
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                ForEach(nutrientCells) { cell in
                    valueCell(cell, value: item.nutrients.v(cell.key)) { v in
                        edit { cur in
                            cur.nutrients.v(cell.key) == v ? cur : ItemMath.setNutrient(cur, key: cell.key, value: v)
                        }
                    }
                }
            }
        }
    }

    // MARK: Food groups (`食物组（影响 HEI-2020 与红肉/加工肉判断）`)

    private var groupCells: [Cell] {
        if let defs = app.meta?.foodGroups, !defs.isEmpty {
            return defs.map { Cell(key: $0.key, zh: $0.zh, unit: $0.unit, note: $0.note) }
        }
        return Vocab.foodGroupOrder.map { Cell(key: $0, zh: $0, unit: "", note: nil) }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("食物组（影响 HEI-2020 与红肉/加工肉判断）")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ink1)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                ForEach(groupCells) { cell in
                    valueCell(cell, value: item.groups.v(cell.key)) { v in
                        edit { cur in
                            cur.groups.v(cell.key) == v ? cur : ItemMath.setGroup(cur, key: cell.key, value: v)
                        }
                    }
                }
            }
        }
    }

    /// Label `zh` (12 pt) over a number field showing `round(v×100)/100` with the unit; input → `max(0, Number || 0)`.
    private func valueCell(_ cell: Cell, value: Double, apply: @escaping @MainActor (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cell.zh)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(cell.note ?? "")
            LogMealDecimalField(value: value, decimals: 2, unit: cell.unit, accessibilityLabel: cell.zh) { v in
                apply(max(0, v ?? 0))
            }
            .accessibilityHint(Text(verbatim: cell.note ?? ""))
        }
    }

    // MARK: `补充风险标记：`

    /// Flag-type hazards (`dose.from == "flag"`) not already on the item, in meta order.
    private var flaggable: [HazardDef] {
        let present = Set(item.hazards.map(\.key))
        return (app.meta?.hazards ?? []).filter { $0.dose.from == "flag" && !present.contains($0.key) }
    }

    @ViewBuilder private var hazardPicker: some View {
        let options = flaggable
        if !options.isEmpty {
            HStack(spacing: 8) {
                Text("补充风险标记：")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink2)
                Menu {
                    ForEach(options) { h in
                        Button {
                            edit { cur in
                                cur.hazards.contains { $0.key == h.key } ? cur : ItemMath.addHazard(cur, key: h.key)
                            }
                        } label: {
                            Text(verbatim: "\(h.zh)（IARC \(h.iarc)）")
                        }
                    }
                } label: {
                    pickerLabel("选择…", placeholder: true)
                }
                .frame(maxWidth: 220)
                .accessibilityLabel(Text("添加风险标记"))
            }
        }
    }
}
