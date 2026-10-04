import SwiftUI

// MARK: - Food detail sheet (web2 §5.9.2; meals §4.7, §2.16, §2.19)

/// Chips, notes, ingredients, source links and the 43-row nutrient table (per 100 g, per serving, % label DV).
/// Owners get `删除` (confirmation → `DELETE /foods/{id}` → `已删除`) and `编辑` (opens the editor prefilled from the food).
struct FoodsDetailView: View {
    @Environment(AppState.self) private var app
    let model: FoodsModel
    let onEdit: @MainActor (Food) -> Void
    let onDeleted: @MainActor () -> Void
    @State private var food: Food
    @State private var confirmDelete = false
    @State private var isDeleting = false

    init(food: Food, model: FoodsModel, onEdit: @escaping @MainActor (Food) -> Void, onDeleted: @escaping @MainActor () -> Void) {
        self.model = model
        self.onEdit = onEdit
        self.onDeleted = onDeleted
        self._food = State(initialValue: food)
    }

    var body: some View {
        SheetScaffold(title: food.name, primary: editAction, secondary: deleteAction) {
            VStack(alignment: .leading, spacing: 16) {
                chips
                if let notes = FoodsText.nonEmpty(food.notes) {
                    Text(verbatim: notes)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ingredients = FoodsText.nonEmpty(food.ingredients) {
                    Text(verbatim: "配料：\(ingredients)")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FoodsSourceLinksRow(links: food.source_urls)
                FoodsMetaGate(model: model) { meta in
                    FoodsNutrientTable(food: food, nutrients: meta.nutrients)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { titleView }
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .confirmationDialog("删除这个食物？已记录的餐食不受影响。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        }
        .task(id: food.id) {
            // `GET /foods/{id}`: show the latest copy (it may have been edited on another device).
            if let fresh = try? await app.api.food(id: food.id), fresh.id == food.id { food = fresh }
        }
    }

    /// Title `name` with the brand in small muted text (web modal title).
    private var titleView: some View {
        VStack(spacing: 1) {
            Text(verbatim: food.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if let brand = FoodsText.nonEmpty(food.brand) {
                Text(verbatim: brand)
                    .font(Theme.Font.foot)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Category, `NOVA n · zh`, source, and one IARC-coloured chip per `hazards100` entry.
    private var chips: some View {
        FlowLayout(spacing: 6) {
            Chip(Vocab.categoryZh(food.category ?? "other") ?? "其他")
            if let nova = food.nova_group { Chip(Vocab.novaLabel(nova)) }
            Chip(FoodsText.source(food.source))
            ForEach(Array(food.hazards100.enumerated()), id: \.offset) { _, hazard in
                let def = model.meta(app)?.hazards.first { $0.key == hazard.key }
                Chip(def?.zh ?? hazard.key, style: .iarc(def?.iarc ?? ""))
            }
        }
    }

    private var editAction: SheetAction? {
        guard food.mine else { return nil }
        return SheetAction(title: "编辑", icon: "pencil", isEnabled: !isDeleting) { onEdit(food) }
    }

    private var deleteAction: SheetAction? {
        guard food.mine else { return nil }
        return SheetAction(title: "删除", icon: "trash", role: .destructive, isBusy: isDeleting) { confirmDelete = true }
    }

    private func delete() async {
        guard !isDeleting else { return }
        isDeleting = true
        let ok = await model.delete(app: app, food: food)
        isDeleting = false
        if ok { onDeleted() }
    }
}

// MARK: - Nutrient table (meals §4.7)

/// `营养素 | 每 100 g | 每份 {s} g | 占标签 DV` for every `meta.nutrients` entry, `s = serving_g ?? 100`.
/// Label-read nutrients carry a `标签` tag; DV% only for nutrients with a label Daily Value.
struct FoodsNutrientTable: View {
    let food: Food
    let nutrients: [NutrientDef]

    var body: some View {
        let s = food.serving_g ?? 100
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                Text("营养素")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("每 100 g")
                    .gridColumnAlignment(.trailing)
                Text(verbatim: "每份 \(fmt(s)) g")
                    .gridColumnAlignment(.trailing)
                Text("占标签 DV")
                    .gridColumnAlignment(.trailing)
            }
            .font(Theme.Font.tableHead)
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .padding(.vertical, 8)
            hairline
            ForEach(nutrients) { n in
                let v = food.per100[n.key] ?? 0
                let serving = v * s / 100
                GridRow {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: n.zh)
                            .foregroundStyle(Theme.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                        if food.label_fields.contains(n.key) { FoodsLabelTag() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Text(verbatim: fmt(v, n.decimals)).foregroundStyle(Theme.ink1)) \(Text(verbatim: n.unit).font(Theme.Font.foot).foregroundStyle(Theme.ink3))")
                        .fixedSize()
                    Text(verbatim: fmt(serving, n.decimals))
                        .foregroundStyle(Theme.ink1)
                        .fixedSize()
                    Text(verbatim: dvText(serving: serving, dv: n.dv))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize()
                }
                .font(Theme.Font.meter)
                .monospacedDigit()
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                hairline
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hair)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    /// `fmt(serving / dv × 100)%` when the nutrient has a (non-zero) label DV, else blank.
    private func dvText(serving: Double, dv: Double?) -> String {
        guard let dv, dv != 0 else { return "" }
        return "\(fmt(serving / dv * 100))%"
    }
}

// MARK: - Shared pieces (detail + editor)

/// Small accent tag `标签` for nutrients read from a real nutrition label (`label_fields`).
struct FoodsLabelTag: View {
    var body: some View {
        Text("标签")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.accentSoft, in: Capsule())
            .fixedSize()
    }
}

/// Link icon followed by each source title (falling back to the host), opened in Safari. Nothing when empty.
struct FoodsSourceLinksRow: View {
    let links: [SourceLink]

    private struct Item: Identifiable {
        let id: Int
        let title: String
        let url: URL
    }

    private var items: [Item] {
        links.enumerated().compactMap { i, link in
            let raw = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            let title = FoodsText.nonEmpty(link.title)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (url.host ?? raw)
            return Item(id: i, title: title, url: url)
        }
    }

    var body: some View {
        let list = items
        if !list.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
                ForEach(list) { item in
                    Link(destination: item.url) {
                        Text(verbatim: item.title)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.accentText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }
}

/// Renders `content` once standards meta is available; otherwise a loading row, or the error with `重试`.
struct FoodsMetaGate<Content: View>: View {
    @Environment(AppState.self) private var app
    let model: FoodsModel
    let content: (Meta) -> Content

    init(model: FoodsModel, @ViewBuilder content: @escaping (Meta) -> Content) {
        self.model = model
        self.content = content
    }

    var body: some View {
        if let meta = model.meta(app) {
            content(meta)
        } else if let error = model.metaError, !model.isLoadingMeta {
            VStack(alignment: .leading, spacing: 8) {
                Banner(error, icon: "exclamationmark.triangle", style: .warn)
                Button("重试") {
                    Task { await model.ensureMeta(app: app, force: true) }
                }
                .buttonStyle(.nl(size: .sm))
            }
        } else {
            LoadingView()
                .task { await model.ensureMeta(app: app) }
        }
    }
}
