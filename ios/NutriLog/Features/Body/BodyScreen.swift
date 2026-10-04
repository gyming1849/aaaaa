import SwiftUI

// MARK: - 身体与运动 (web1 §7; body §3–§4). Root of the 身体 tab.
// Single column in web order: 记录体重 · 近 90 天体重 · 记录运动 · 步数与活动能量 · 体检化验指标 · 苹果健康同步
// (the native replacement for the web's 连接苹果健康 card). The date (≤ today) drives the activity card and the
// weight/workout forms; `router.bodyFocusDate` (Today's "身体与运动" link) jumps to a date.

struct BodyScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = BodyModel()
    @State private var recognizer: BodyRecognizerRequest?

    init() {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                    header
                    if let error = model.loadError {
                        errorBanner(error)
                    }
                    BodyWeightCard(model: model)
                        .debugScrollAnchor("weight")
                    BodyWeightChartCard(days: model.trendDays, isLoaded: model.trendLoaded, isLoading: model.isLoading)
                        .debugScrollAnchor("chart")
                    BodyExercisesCard(model: model, onRecognize: openRecognizer)
                        .debugScrollAnchor("exercises")
                    BodyActivityCard(model: model, onRecognize: openRecognizer)
                        .debugScrollAnchor("activity")
                    BodyLabsCard(model: model)
                        .debugScrollAnchor("labs")
                    BodyHealthSyncRow()
                        .debugScrollAnchor("healthsync")
                }
                .padding(.horizontal, Theme.Metrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .debugScrollTo(proxy, ready: model.trendLoaded)
        }
        .background(Theme.page)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("身体与运动")
        .bodyKeyboardDoneButton()
        .refreshable {
            await app.refreshMeIfDayChanged()   // past midnight: `today` rolls over and the load key reloads
            await model.reloadAll(app: app)
        }
        .task(id: BodyLoadKey(date: effectiveDate, version: app.dataVersion, today: app.today)) { await model.refresh(app: app) }
        .onAppear {
            model.prepare(today: app.today)
            applyFocusDate()
        }
        .onChange(of: app.router.bodyFocusDate) { applyFocusDate() }
        .onChange(of: model.date) { model.dateDidChange() }
        .sheet(item: $recognizer) { request in
            ActivityRecognizerSheet(date: request.date, current: request.current, mode: request.mode) {
                recognizer = nil
            }
        }
    }

    private var effectiveDate: String { model.date.isEmpty ? app.today : model.date }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("睡前称重 + 步数/活动能量 + 运动记录，和饮食摄入交叉对照")
                .font(Theme.Font.subtitle)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            DateNav(date: Binding(get: { effectiveDate }, set: { model.date = min($0, app.today) }), today: app.today)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("日期"))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") { Task { await model.reloadAll(app: app) } }
                .buttonStyle(.nl(.plain, size: .sm))
        }
        .nlBanner(.warn)
    }

    /// Opens the recognizer in `ai` mode for the selected date (both Body entry points use `ai`, like the web).
    private func openRecognizer() {
        let date = effectiveDate
        recognizer = BodyRecognizerRequest(date: date, current: model.activityReady ? model.day : nil, mode: .ai)
    }

    /// `router.showBody(date:)` → select that date (clamped to today), then clear the request.
    private func applyFocusDate() {
        guard let focus = app.router.bodyFocusDate else { return }
        app.router.bodyFocusDate = nil
        if LocalDay.isValid(focus) { model.date = min(focus, app.today) }
    }
}

/// One presentation of `ActivityRecognizerSheet` from the Body screen.
private struct BodyRecognizerRequest: Identifiable {
    let id = UUID()
    let date: String
    let current: ActivityDay?
    let mode: RecognizerMode
}
