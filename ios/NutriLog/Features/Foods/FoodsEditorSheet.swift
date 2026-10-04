import SwiftUI
import UIKit

// MARK: - Food editor (web2 §5.9.4; meals §2.17–§2.18, §6.5)

/// `编辑食物` (existing food → full-replace `PUT /foods/{id}`) / `保存到食物库` (`POST /foods`).
/// Edits name, brand, category, serving, NOVA, aliases, visibility, per-100 g nutrients and ingredients; `groups100`,
/// `hazards100`, `label_fields`, `source_urls`, `notes` and `source` are kept and sent back unchanged.
struct FoodsEditorSheet: View {
    @Environment(AppState.self) private var app
    let model: FoodsModel
    let onSaved: @MainActor () -> Void
    @State private var draft: FoodsEditorDraft
    @State private var showAll: Bool
    @State private var isSaving = false

    init(draft: FoodsEditorDraft, model: FoodsModel, onSaved: @escaping @MainActor () -> Void) {
        self.model = model
        self.onSaved = onSaved
        self._draft = State(initialValue: draft)
        self._showAll = State(initialValue: draft.showsAllNutrientsInitially)
    }

    var body: some View {
        SheetScaffold(title: draft.foodId != nil ? "编辑食物" : "保存到食物库",
                      primary: SheetAction(title: "保存", isEnabled: draft.canSave, isBusy: isSaving) { Task { await save() } }) {
            if let notes = FoodsText.nonEmpty(draft.input.notes), draft.input.source != "manual" {
                Banner(notes, icon: "sparkles", style: .accent)
            }
            FoodsSourceLinksRow(links: draft.input.source_urls)
            basics
            VStack(alignment: .leading, spacing: 16) {
                FoodsTextField(label: "别名（逗号分隔，用于搜索和自动匹配）", text: $draft.aliasesText)
                VStack(alignment: .leading, spacing: 6) {
                    FoodsFieldLabel("可见范围")
                    Seg([SegOption(value: "private", label: "仅自己"), SegOption(value: "public", label: "所有成员可用")],
                        selection: $draft.input.visibility)
                }
            }
            nutrients
            FoodsTextField(label: "配料表（可选）", text: $draft.input.ingredients, multiline: true)
                .toolbar {
                    // The decimal pad has no return key, and return in the ingredients box inserts a new line.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { FoodsKeyboard.dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: Sections

    /// 名称 · 品牌 · 分类 · 一份重量 · 份量描述 · 加工程度 (NOVA), in the web's field order (paired up on the phone).
    private var basics: some View {
        VStack(alignment: .leading, spacing: 16) {
            FoodsTextField(label: "名称", text: $draft.input.name)
            HStack(alignment: .top, spacing: 12) {
                FoodsTextField(label: "品牌", text: $draft.input.brand)
                FoodsSelectField(label: "分类", value: Vocab.categoryZh(draft.input.category) ?? "其他") {
                    Picker("分类", selection: $draft.input.category) {
                        ForEach(Vocab.categories, id: \.key) { c in
                            Text(verbatim: c.zh).tag(c.key)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                NumberField("一份重量", value: $draft.input.serving_g, unit: "g", prompt: "")
                FoodsTextField(label: "份量描述", text: $draft.input.serving_desc, prompt: "1 包 335 g")
            }
            FoodsSelectField(label: "加工程度 (NOVA)", value: draft.input.nova_group.map(FoodsText.novaOption) ?? "未知") {
                Picker("加工程度 (NOVA)", selection: $draft.input.nova_group) {
                    Text("未知").tag(Int?.none)
                    ForEach(1...4, id: \.self) { n in
                        Text(verbatim: FoodsText.novaOption(n)).tag(Int?.some(n))
                    }
                }
            }
        }
    }

    /// `每 100 g 营养成分` with the `显示全部 {n} 项` switch; collapsed it shows the 10 label nutrients plus a footnote.
    private var nutrients: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("每 100 g 营养成分")
                    .font(Theme.Font.h3)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Toggle(isOn: $showAll) {
                    Text(verbatim: "显示全部 \(model.meta(app)?.nutrients.count ?? Vocab.nutrientOrder.count) 项")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink2)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .fixedSize()
            }
            FoodsMetaGate(model: model) { meta in
                let list = meta.nutrients.filter { showAll || Vocab.foodEditorMainNutrients.contains($0.key) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(list) { n in
                        FoodsNutrientField(def: n, isLabel: draft.input.label_fields.contains(n.key), value: per100(n.key))
                    }
                }
                if !showAll {
                    Text("营养标签上通常只有这几项；其余营养素留空按 0 计，也可以让 AI 查询补全。")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Per-100 g value; clearing a field removes the key, which the server stores as 0 (`留空按 0 计`).
    private func per100(_ key: String) -> Binding<Double?> {
        Binding(
            get: { draft.input.per100[key] },
            set: { value in
                if let value { draft.input.per100[key] = value } else { draft.input.per100.removeValue(forKey: key) }
            }
        )
    }

    private func save() async {
        guard !isSaving, draft.canSave else { return }
        isSaving = true
        let ok = await model.save(app: app, draft: draft)
        isSaving = false
        if ok { onSaved() }
    }
}

// MARK: - Form controls (web `.field` / `.input`, matching the design-system `NumberField` chrome)

/// Field label: 13 pt, weight 550, ink-2.
struct FoodsFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Input chrome: surface, radius 10, 1 pt border (accent and a soft ring while focused), 40 pt tall.
struct FoodsInputChrome: ViewModifier {
    var focused: Bool
    var multiline = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 10 : 0)
            .frame(minHeight: 40)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: 1)
            }
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius + 3, style: .continuous)
                        .stroke(Theme.accentSoft, lineWidth: 3)
                        .padding(-1.5)
                }
            }
    }
}

/// Labelled text input (single line, or a growing multi-line box).
struct FoodsTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String? = nil
    var autofocus = false
    var multiline = false
    @FocusState private var focused: Bool
    /// Autofocus happens at most once per appearance (not again after a failed lookup re-enables the form).
    @State private var didAutofocus = false

    init(label: String, text: Binding<String>, prompt: String? = nil, autofocus: Bool = false, multiline: Bool = false) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.autofocus = autofocus
        self.multiline = multiline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FoodsFieldLabel(label)
            field
                .focused($focused)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.ink)
                .modifier(FoodsInputChrome(focused: focused, multiline: multiline))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focused = true })
        }
        // Keyed on `autofocus` so a resumed lookup (busy right after appearing) cancels the pending focus.
        .task(id: autofocus) {
            guard autofocus, !didAutofocus else { return }
            // Wait for the sheet presentation to settle before raising the keyboard (web `autoFocus`).
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            didAutofocus = true
            focused = true
        }
    }

    @ViewBuilder private var field: some View {
        // No prompt → an empty placeholder (SwiftUI would otherwise repeat the label inside the field).
        let promptText = Text(verbatim: prompt ?? "").foregroundStyle(Theme.ink3)
        if multiline {
            TextField(label, text: $text, prompt: promptText, axis: .vertical)
                .lineLimit(2...8)
        } else {
            TextField(label, text: $text, prompt: promptText)
        }
    }
}

/// Labelled picker that looks like an input (`<select>`): the current value with an up/down chevron, opening a menu.
struct FoodsSelectField<MenuContent: View>: View {
    let label: String
    let value: String
    let menu: MenuContent

    init(label: String, value: String, @ViewBuilder menu: () -> MenuContent) {
        self.label = label
        self.value = value
        self.menu = menu()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FoodsFieldLabel(label)
            Menu {
                menu
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: value)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
                .modifier(FoodsInputChrome(focused: false))
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(verbatim: value))
        }
    }
}

/// One per-100 g nutrient input: `zh` (+ `标签` tag) above a decimal field with the unit affix.
/// Shows the stored value rounded to 3 decimals (web `round(x × 1000) / 1000`); empty text means "not set" (0).
struct FoodsNutrientField: View {
    let def: NutrientDef
    let isLabel: Bool
    @Binding var value: Double?
    @State private var text: String
    @FocusState private var focused: Bool

    init(def: NutrientDef, isLabel: Bool, value: Binding<Double?>) {
        self.def = def
        self.isLabel = isLabel
        self._value = value
        self._text = State(initialValue: Self.display(value.wrappedValue))
    }

    static func display(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return NumberField.format((v * 1000).rounded() / 1000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: def.zh)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if isLabel { FoodsLabelTag() }
            }
            HStack(spacing: 6) {
                TextField(def.zh, text: $text, prompt: Text(verbatim: ""))
                    .keyboardType(.decimalPad)
                    .font(Theme.Font.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                if !def.unit.isEmpty {
                    Text(verbatim: def.unit)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .modifier(FoodsInputChrome(focused: focused))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            .accessibilityValue(Text(verbatim: text.isEmpty ? "" : "\(text) \(def.unit)"))
        }
        .onChange(of: text) { _, newText in
            let parsed = NumberField.parse(newText)
            if parsed != value { value = parsed }
        }
        .onChange(of: value) { _, newValue in
            if NumberField.parse(text) != newValue { text = Self.display(newValue) }
        }
    }
}

/// Ends editing in whichever text field is first responder.
enum FoodsKeyboard {
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
