import SwiftUI

// MARK: - 食物库 (web2 §5.9.1; meals §2.15, §6.5)
// Seeded stub signature kept: `FoodsScreen()`. Pushed from 更多 → 快捷入口 (`Route.foods`).

struct FoodsScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = FoodsModel()
    @State private var lookup = FoodsLookupModel()
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var scope: FoodScope = .all
    @State private var sheet: FoodsSheet?
    @State private var pendingDelete: Food?
    @State private var checkedPendingLookup = false
    @State private var pendingBlock: Food?
    @Environment(\.openURL) private var openURL

    init() {}

    var body: some View {
        List {
            header
                .foodsListRow(top: 4)
            if let error = model.error {
                errorBanner(error)
                    .foodsListRow()
            }
            if let foods = model.foods.map(app.blocked.visible) {
                if foods.isEmpty {
                    Card {
                        EmptyState("还没有食物。记一餐时 AI 分析出的食物可以一键“存入食物库”，也可以在这里用 AI 联网查询或拍营养成分表添加。",
                                   icon: "books.vertical")
                    }
                    .foodsListRow()
                } else {
                    ForEach(foods) { food in
                        row(food)
                    }
                }
            } else if model.error == nil {
                LoadingView()
                    .foodsListRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Theme.page)
        .navigationTitle("食物库")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索名称、品牌、别名…"))
        .refreshable { await model.reload(app: app) }
        // 250 ms debounce (web2 §5.9.1).
        .task(id: query) {
            guard query != debouncedQuery else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            debouncedQuery = query
        }
        // Also re-runs when other screens change data (e.g. a meal saved a food or bumped `use_count`).
        .task(id: FoodsLoadKey(query: FoodsModel.FoodsQuery(text: debouncedQuery, scope: scope), dataVersion: app.dataVersion)) {
            await model.load(app: app, query: debouncedQuery, scope: scope)
        }
        .task {
            // Resume an AI lookup that was still running when the app was last closed.
            guard !checkedPendingLookup else { return }
            checkedPendingLookup = true
            if sheet == nil, FoodsLookupModel.pendingJob() != nil { sheet = .lookup }
        }
        .sheet(item: $sheet, onDismiss: {
            // Closing the AI lookup while its job runs stops polling (toast `已取消`).
            if lookup.isBusy { lookup.cancel() }
        }) { which in
            sheetContent(which)
        }
    }

    // MARK: Header (subtitle, actions, scope)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常吃的包装食品、外卖、自制菜存下来，下次直接搜索并填克数，无需再调用 AI")
                .font(Theme.Font.subtitle)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 10) {
                Button {
                    sheet = .editor(.blank())
                } label: {
                    Image(systemName: "plus")
                    Text("手动录入")
                }
                .buttonStyle(.nl())
                Button {
                    lookup.resetFields()
                    sheet = .lookup
                } label: {
                    Image(systemName: "sparkles")
                    Text("AI 查询 / 拍营养表")
                }
                .buttonStyle(.nl(.primary))
            }
            Seg([SegOption(value: FoodScope.all, label: "全部可用"), SegOption(value: FoodScope.mine, label: "我创建的")],
                selection: $scope)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(message, icon: "exclamationmark.triangle", style: .warn)
            Button("重试") {
                Task { await model.reload(app: app) }
            }
            .buttonStyle(.nl(size: .sm))
        }
    }

    // MARK: Rows

    private func row(_ food: Food) -> some View {
        Button {
            sheet = .detail(food)
        } label: {
            FoodsCard(food: food)
        }
        .buttonStyle(.plain)
        .foodsListRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if food.mine {
                Button(role: .destructive) {
                    pendingDelete = food
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    sheet = .editor(FoodsEditorDraft(food: food))
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(Theme.accent)
            }
        }
        // Anchored on the row so the iOS 26 popover points at the card being deleted.
        .confirmationDialog("删除这个食物？已记录的餐食不受影响。",
                            isPresented: Binding(get: { pendingDelete?.id == food.id },
                                                 set: { if !$0, pendingDelete?.id == food.id { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    if await model.delete(app: app, food: food) { await model.reload(app: app) }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .contextMenu {
            if food.mine {
                Button {
                    sheet = .editor(FoodsEditorDraft(food: food))
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = food
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } else {
                // Another member's public food: 举报 (mail, only with a support address) and 屏蔽 its creator.
                if let url = BlockedMembersText.reportFood(id: food.id, name: food.name, owner: food.owner_name, server: app.serverURL) {
                    Button { openURL(url) } label: { Label("举报", systemImage: "exclamationmark.bubble") }
                }
                if food.owner_id > 0 {
                    Button(role: .destructive) {
                        pendingBlock = food
                    } label: {
                        Label("屏蔽 \(food.owner_name ?? "创建者")", systemImage: "hand.raised")
                    }
                }
            }
        }
        .confirmationDialog("屏蔽 \(food.owner_name ?? "创建者")？",
                            isPresented: Binding(get: { pendingBlock?.id == food.id },
                                                 set: { if !$0, pendingBlock?.id == food.id { pendingBlock = nil } }),
                            titleVisibility: .visible) {
            Button("屏蔽", role: .destructive) {
                app.blocked.block(food.owner_id, label: food.owner_name ?? "成员 #\(food.owner_id)")
                app.toasts.show("已屏蔽")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对方的公开食物和社区卡片将不再显示给你（仅在这台设备上）。可在“更多 → 已屏蔽的成员”中取消。")
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheetContent(_ which: FoodsSheet) -> some View {
        switch which {
        case .detail(let food):
            FoodsDetailView(food: food, model: model,
                            onEdit: { edited in sheet = .editor(FoodsEditorDraft(food: edited)) },
                            onDeleted: {
                                sheet = nil
                                Task { await model.reload(app: app) }
                            })
        case .lookup:
            FoodsLookupSheet(lookup: lookup, api: app.api, toasts: app.toasts) { draft in
                sheet = .editor(FoodsEditorDraft(draft: draft))
            }
        case .editor(let draft):
            FoodsEditorSheet(draft: draft, model: model) {
                sheet = nil
                Task { await model.reload(app: app) }
            }
        }
    }
}

/// Identity of one list load: the debounced query and scope plus `app.dataVersion`.
private struct FoodsLoadKey: Hashable {
    let query: FoodsModel.FoodsQuery
    let dataVersion: Int
}

/// The single sheet slot of the Foods screen (web: detail, AI lookup and editor modals, one at a time).
enum FoodsSheet: Identifiable {
    case detail(Food)
    case lookup
    case editor(FoodsEditorDraft)

    var id: String {
        switch self {
        case .detail(let food): "detail-\(food.id)"
        case .lookup: "lookup"
        case .editor(let draft): "editor-\(draft.id.uuidString)"
        }
    }
}

// MARK: - Food card (web2 §5.9.1)

/// Name + visibility icon, `brand · serving` subtitle, per-100 g macro line, and the source / NOVA / usage / owner chips.
struct FoodsCard: View {
    let food: Food

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: food.name)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: food.visibility == "public" ? "globe" : "lock")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink3)
                        .accessibilityLabel(food.visibility == "public" ? "公开" : "私有")
                }
                let subtitle = FoodsText.subtitle(food)
                if !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                macroLine
                FlowLayout(spacing: 6) {
                    Chip(FoodsText.source(food.source))
                    if let nova = food.nova_group { Chip("NOVA \(nova)") }
                    if food.use_count > 0 { Chip("用过 \(food.use_count) 次") }
                    if !food.mine { Chip("来自 \(food.owner_name ?? "")", style: .accent) }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// `每 100 g **{kcal}** kcal` · `蛋白 **{g,1}**` · `钠 **{mg}**mg` (12.5 pt ink-2, 12 pt gaps; values ink-1 weight 600).
    private var macroLine: some View {
        FlowLayout(spacing: 12, lineSpacing: 2) {
            Text("每 100 g \(bold(fmt(food.per100.v("energy_kcal")))) kcal")
            Text("蛋白 \(bold(fmt(food.per100.v("protein_g"), 1)))")
            Text("钠 \(bold(fmt(food.per100.v("sodium_mg"))))mg")
        }
        .font(Theme.Font.hint)
        .foregroundStyle(Theme.ink2)
        .monospacedDigit()
    }

    private func bold(_ value: String) -> Text {
        Text(verbatim: value).fontWeight(.semibold).foregroundStyle(Theme.ink1)
    }
}

// MARK: - Helpers

private extension View {
    /// Card-style list row: no separator, transparent background, page gutters.
    func foodsListRow(top: CGFloat = 6) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: Theme.Metrics.pagePadding, bottom: 6, trailing: Theme.Metrics.pagePadding))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
