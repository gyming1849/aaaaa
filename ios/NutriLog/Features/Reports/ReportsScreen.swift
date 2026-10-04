import SwiftUI

// MARK: - 周期报告 (web2 §5.2, rep §6–§8, §17.4). Own data only.
// Week/month Seg (default: last week; 月报 = the current month), 上一期/下一期 (next disabled when end ≥ today),
// then: total tile + TotalParts, LE8 card, the 2×2 index tiles, AI 点评, WCRF card, weekly checks, energy & weight with
// the key daily nutrients, hazards (if any) and the HEI components (if any). Reloading keeps the previous content at
// 55 % opacity; errors show a retryable banner (the web shows a blank page). Toolbar `历史报告` lists stored reports.

struct ReportsScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReportsModel
    @State private var showHistory = false
    @State private var consent: AIConsentRequest?

    init() {
        _model = State(initialValue: ReportsModel())
    }

    /// Opens Reports at a given period (used by 历史报告). Week and month periods are normalised like the web's anchor.
    init(start: String, end: String, kind: ReportsPeriodKind) {
        _model = State(initialValue: ReportsModel(range: .make(start: start, end: end, kind: kind)))
    }

    var body: some View {
        let today = app.today
        let range = model.effectiveRange(today: today)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                    ReportsHeader(range: range, today: today,
                                  onSelectKind: { model.selectKind($0, today: today) },
                                  onShift: { model.shift($0, today: today) })
                    content(range)
                }
                .padding(Theme.Metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .debugScrollTo(proxy, ready: model.data != nil && !model.isLoading)
        }
        .background(Theme.page)
        .navigationTitle("周期报告")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("历史报告") { showHistory = true }
            }
        }
        .navigationDestination(isPresented: $showHistory) { ReportHistoryScreen() }
        .aiConsentPrompt($consent)
        .refreshable {
            model.show(range)
            await model.load(app: app, range: range)
        }
        .task(id: ReportsLoadKey(range: range, dataVersion: app.dataVersion)) {
            model.show(range)
            await model.load(app: app, range: range)
        }
        .task(id: model.activeJobId) { await model.pollActiveJob(app: app) }
        .onChange(of: scenePhase) { _, phase in
            // Back from the background: resume a pending AI 点评 job whose polling stopped (rep §7.2).
            if phase == .active { model.show(range) }
        }
    }

    @ViewBuilder private func content(_ range: ReportsRange) -> some View {
        let current = model.isCurrent(range)
        if let error = model.error {
            ReportsRetryBanner(message: error) {
                Task { await model.load(app: app, range: range) }
            }
        }
        if let data = model.data, current || model.error == nil {
            sections(data, range: range, current: current)
                .opacity(model.isLoading || !current ? 0.55 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isLoading || !current)
                .allowsHitTesting(current)
        } else if model.error == nil {
            LoadingView()
        }
    }

    @ViewBuilder private func sections(_ data: PeriodScore, range: ReportsRange, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            ReportsTotalTile(kind: model.loadedRange?.kind ?? range.kind, total: data.total)
            Le8Card(indices: data.indices, title: "心血管健康 LE8",
                    subtitle: "AHA Life's Essential 8 · \(data.daysLogged)/\(data.days) 天有记录")
                .debugScrollAnchor("le8")
            ReportsIndexTiles(data: data)
                .debugScrollAnchor("tiles")
            ReportsAISummaryCard(summary: data.aiSummary, daysLogged: data.daysLogged, isMockAI: app.isMockAI,
                                 isGenerating: current && model.isGenerating(for: range), phase: model.jobPhase, startedAt: model.jobStartedAt) {
                app.withAIConsent($consent) { Task { await model.generate(app: app, range: range) } }
            }
            .debugScrollAnchor("ai")
            WcrfCard(indices: data.indices, subtitle: "\(data.start) 至 \(data.end)")
                .debugScrollAnchor("wcrf")
            ReportsChecksCard(checks: data.checks)
                .debugScrollAnchor("checks")
            ReportsEnergyCard(energy: data.energy, avgTotals: data.avgTotals)
                .debugScrollAnchor("energy")
            if !data.hazards.isEmpty {
                ReportsHazardsCard(hazards: data.hazards)
                    .debugScrollAnchor("hazards")
            }
            if let hei = data.hei {
                ReportsHeiComponentsCard(hei: hei)
                    .debugScrollAnchor("hei")
            }
        }
    }
}

/// Reload trigger: the shown period and `app.dataVersion` (any write elsewhere recomputes the report server-side).
private struct ReportsLoadKey: Hashable {
    let range: ReportsRange
    let dataVersion: Int
}

/// Warning banner with a 重试 button (Reports and 历史报告 load failures).
struct ReportsRetryBanner: View {
    let message: String
    let onRetry: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试", action: onRetry)
                .buttonStyle(.nl(.plain, size: .sm))
        }
        .nlBanner(.warn)
        .accessibilityElement(children: .contain)
    }
}
