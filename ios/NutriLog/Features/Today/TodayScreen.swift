import SwiftUI

// MARK: - Today 今日概览 (web1 §4; rep §1–§5, §17.2). Owner: WP2.
// Own day (`member == nil`) or another member's read-only day (`/u/:username`, pushed as `Route.memberDay`).
// Sections in display order, single column: A1 score, A2 energy, B1 highlights + B2 key limits (with data), C LE8 + WCRF,
// D hazards (when any), E1 meals + E2 activity, F detail tabs (with data).
// The date follows `app.today` until the user picks another day; `router.todayFocusDate` (e.g. after saving a meal)
// moves the own screen to that day. Reloads on pull-to-refresh, on date change and on `app.dataVersion`.

struct TodayScreen: View {
    let member: String?

    @Environment(AppState.self) private var app
    @State private var model = TodayModel()
    /// The picked day; `nil` = follow `app.today` (web: no `?date=` param).
    @State private var pickedDate: String?
    @State private var recognizer: TodayRecognizerRequest?
    @State private var pendingDelete: Meal?

    init(member: String? = nil) { self.member = member }

    /// Another member's username (read-only mode); your own username counts as your own view, like the web.
    private var other: String? {
        guard let member, !member.isEmpty else { return nil }
        if let me = app.user?.username, me.caseInsensitiveCompare(member) == .orderedSame { return nil }
        return member
    }

    private var date: String { pickedDate ?? app.today }

    private var dateBinding: Binding<String> {
        Binding(get: { date }, set: { newValue in pickedDate = newValue == app.today ? nil : newValue })
    }

    private var loadKey: String { "\(other ?? "")|\(date)|\(app.dataVersion)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                    header
                    if let error = model.error { errorBanner(error) }
                    if let day = model.day {
                        let stale = model.isShowingStale(for: date)
                        TodayDayContent(
                            day: day,
                            readOnly: other != nil,
                            meta: app.meta,
                            isUpdatingWater: model.isUpdatingWater,
                            deletingMealId: model.deletingMealId,
                            healthSyncEnabled: app.healthSync.status.isEnabled,
                            actions: actions(for: day)
                        )
                        // Another day is being loaded (or failed to load): the previous day stays visible, dimmed, and its
                        // controls are disabled so water ± / delete / 填写 cannot act on a day other than the one in DateNav.
                        .opacity(stale ? 0.55 : 1)
                        .disabled(stale)
                        .animation(.easeInOut(duration: 0.2), value: stale)
                    } else if model.isLoading || model.error == nil {
                        LoadingView()
                    }
                }
                .padding(.horizontal, Theme.Metrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .debugScrollTo(proxy, ready: model.day != nil)
        }
        .background(Theme.page)
        .navigationTitle(other.map { "@\($0) 的记录" } ?? "今日概览")
        .navigationBarTitleDisplayMode(other == nil ? .large : .inline)
        .refreshable {
            await app.refreshMeIfDayChanged()   // past midnight: `today` rolls over and the load key reloads
            await reload()
        }
        .task(id: loadKey) { await reload() }
        .task { if app.meta == nil { await app.ensureMeta() } }
        .onAppear(perform: applyFocusDate)
        .onChange(of: app.router.todayFocusDate) { _, _ in applyFocusDate() }
        .sheet(item: $recognizer) { req in
            ActivityRecognizerSheet(date: req.date, current: model.day?.date == req.date ? model.day?.activity : nil, mode: req.mode) {
                recognizer = nil
                app.noteDataChanged()
            }
            .toastOverlay(app.toasts)
        }
        .confirmationDialog(pendingDelete.map(TodayText.deleteTitle) ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { meal in
            Button("删除", role: .destructive) {
                Task { await model.deleteMeal(app: app, meal: meal) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: Header (subtitle, DateNav, primary action)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(other == nil ? "每一项都对照美国权威标准实时评估" : "只读视图（对方开启了共享）")
                .font(Theme.Font.subtitle)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 10, lineSpacing: 10) {
                DateNav(date: dateBinding, today: app.today)
                if let other {
                    Button {
                        app.router.push(.memberTrends(username: other))
                    } label: {
                        Label("看趋势", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(.nl(.plain))
                } else {
                    Button {
                        app.router.openLogMeal(date: date == app.today ? nil : date)
                    } label: {
                        Label("记一餐", systemImage: "plus")
                    }
                    .buttonStyle(.nl(.primary))
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .accessibilityHidden(true)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") { Task { await reload() } }
                .buttonStyle(.nl(.plain, size: .sm))
                .disabled(model.isLoading)
        }
        .nlBanner(.warn)
    }

    // MARK: Actions

    private func reload() async {
        await model.load(app: app, date: date, member: other)
    }

    /// Consumes `router.todayFocusDate` (own view only): switch to that day and pop pushed screens off the 今日 tab.
    private func applyFocusDate() {
        guard member == nil, let focus = app.router.todayFocusDate else { return }
        app.router.todayFocusDate = nil
        if LocalDay.isValid(focus) {
            pickedDate = focus >= app.today ? nil : focus
        }
        if !app.router.todayPath.isEmpty { app.router.todayPath = NavigationPath() }
    }

    private func actions(for day: DayResponse) -> TodayDayActions {
        TodayDayActions(
            showRules: { app.router.push(.standards(.rules)) },
            water: { ml in Task { await model.addWater(app: app, date: day.date, ml: ml) } },
            logFirstMeal: { app.router.openLogMeal(date: day.date == app.today ? nil : day.date) },
            editMeal: { meal in app.router.openLogMeal(date: meal.date, editMealId: meal.id) },
            deleteMeal: { meal in pendingDelete = meal },
            recognize: { mode in recognizer = TodayRecognizerRequest(mode: mode, date: day.date) },
            showBody: { app.router.showBody(date: day.date) }
        )
    }
}

// MARK: - Day content

/// Callbacks from the cards to the screen.
struct TodayDayActions {
    let showRules: @MainActor () -> Void
    let water: @MainActor (Double) -> Void
    let logFirstMeal: @MainActor () -> Void
    let editMeal: @MainActor (Meal) -> Void
    let deleteMeal: @MainActor (Meal) -> Void
    let recognize: @MainActor (RecognizerMode) -> Void
    let showBody: @MainActor () -> Void
}

/// Sections A–F for one loaded day.
private struct TodayDayContent: View {
    let day: DayResponse
    let readOnly: Bool
    let meta: Meta?
    let isUpdatingWater: Bool
    let deletingMealId: Int?
    let healthSyncEnabled: Bool
    let actions: TodayDayActions

    var body: some View {
        let s = day.score
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            // A. Hero
            TodayScoreCard(score: s, heiUsMean: meta?.heiUsMean ?? 58, onShowRules: actions.showRules)
                .debugScrollAnchor("score")
            TodayEnergyCard(day: day)
                .debugScrollAnchor("energy")

            // B. Only with data. A summary-only share strips the highlights (rep §1), so that card is hidden.
            if s.hasData {
                if day.full { TodayHighlightsCard(top: s.top).debugScrollAnchor("highlights") }
                TodayKeyLimitsCard(score: s, targets: day.targets)
                    .debugScrollAnchor("limits")
            }

            // C. Always
            Le8Card(indices: day.indices)
                .debugScrollAnchor("le8")
            WcrfCard(indices: day.indices)
                .debugScrollAnchor("wcrf")

            // D. Hazards
            if !s.hazards.isEmpty {
                TodayHazardsCard(hazards: s.hazards, meta: meta)
                    .debugScrollAnchor("hazards")
            }

            // E. Meals + activity
            TodayMealsCard(day: day, readOnly: readOnly, isUpdatingWater: isUpdatingWater, deletingMealId: deletingMealId,
                           onWater: actions.water, onLogFirst: actions.logFirstMeal,
                           onEdit: actions.editMeal, onDelete: actions.deleteMeal)
                .debugScrollAnchor("meals")
            TodayActivityCard(day: day, readOnly: readOnly, healthSyncEnabled: healthSyncEnabled,
                              onRecognize: actions.recognize, onShowBody: actions.showBody)
                .debugScrollAnchor("activity")

            // F. Only with data
            if s.hasData {
                TodayDetailTabs(score: s, targets: day.targets, meta: meta)
                    .debugScrollAnchor("details")
            }
        }
    }
}
