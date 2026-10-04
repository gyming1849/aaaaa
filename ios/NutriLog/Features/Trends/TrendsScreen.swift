import SwiftUI

// MARK: - Trends 健康趋势 (web2 §5.1, rep §10.3; web `pages/Trends.tsx`). Owner: WP5.
// Own data (`member == nil`, or the own username) or another member's shared data (`/u/:username/trends`, `?user=`).
// Header: title + `{start} 至 {end} · {每日|每周平均|每月平均}`, the 7-option range Seg (wraps) and, for 自定义, two date
// pickers joined by `至`. Sections in web order, single column: summary tiles, HEI chart, energy chart, weight chart,
// HEI/MAR chart, nutrient explorer, score calendar (span ≥ 45), LE8 + WCRF for the period, pass rates + periodic checks,
// hazard totals. First load shows `加载中…`; reloads keep the content visible at 55 % opacity.

/// Own trends (`member == nil`) or another member's (`/u/:username/trends`).
struct TrendsScreen: View {
    let member: String?

    @Environment(AppState.self) private var app
    @State private var model = TrendsModel()

    init(member: String? = nil) { self.member = member }

    /// The member being viewed, or nil for the own view (a member link to oneself is the own view, as on the web).
    private var other: String? {
        guard let member, !member.isEmpty, member != app.user?.username else { return nil }
        return member
    }

    private var title: String { other.map { "@\($0) 的健康趋势" } ?? "健康趋势" }

    var body: some View {
        let today = app.today
        let (start, end) = model.bounds(today: today)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                    header(start: start, end: end, today: today)
                    content
                }
                .padding(Theme.Metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .debugScrollTo(proxy, ready: model.trends != nil && model.period != nil)
        }
        .background(Theme.page)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(other == nil ? .large : .inline)
        .refreshable {
            await app.refreshMeIfDayChanged()
            await model.refresh(app: app, other: other)
        }
        .task(id: "\(start)|\(end)|\(other ?? "")|\(app.dataVersion)") {
            await model.load(app: app, other: other)
        }
        .task(id: "\(other ?? "")|\(app.dataVersion)") {
            await model.loadTargets(app: app, other: other)
        }
        .task {
            if app.meta == nil { await app.ensureMeta() }
        }
    }

    // MARK: Header

    private func header(start: String, end: String, today: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "\(start) 至 \(end) · \(model.unit.zh)")
                .font(Theme.Font.subtitle)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
            Seg(TrendsRange.allCases.map { SegOption(value: $0, label: $0.label) },
                selection: Binding(get: { model.range }, set: { model.selectRange($0) }))
            if model.range == .custom {
                TrendsCustomRangeRow(model: model, today: today)
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error = model.trendsError {
            TrendsErrorBanner(message: error) {
                Task { await model.refresh(app: app, other: other) }
            }
        }
        if model.trends == nil {
            if model.isLoadingTrends || model.trendsError == nil { LoadingView() }
        } else {
            sections
                .opacity(model.isLoadingTrends ? 0.55 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isLoadingTrends)
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            TrendsSummaryTiles(days: model.days, period: model.period)
                .debugScrollAnchor("tiles")
            TrendsScoreChart(buckets: model.buckets, unit: model.unit)
                .debugScrollAnchor("hei")
            TrendsEnergyChart(buckets: model.buckets)
                .debugScrollAnchor("energy")
            TrendsWeightChart(buckets: model.buckets, unit: model.unit, period: model.period)
                .debugScrollAnchor("weight")
            TrendsCategoryChart(buckets: model.buckets)
                .debugScrollAnchor("category")
            TrendsNutrientExplorer(buckets: model.buckets, unit: model.unit, targets: other == nil ? model.targets : nil,
                                   nutrients: app.meta?.nutrients ?? [],
                                   metricKey: Binding(get: { model.metricKey }, set: { model.metricKey = $0 }))
                .debugScrollAnchor("nutrients")
            if model.days.count >= TrendsBucketing.calendarMinSpan {
                TrendsScoreCalendar(days: model.days)
                    .debugScrollAnchor("calendar")
            }
            if let period = model.period {
                let range = "\(period.start) 至 \(period.end)"
                Le8Card(indices: period.indices, subtitle: range)
                    .debugScrollAnchor("le8")
                WcrfCard(indices: period.indices, subtitle: range)
                    .debugScrollAnchor("wcrf")
                TrendsPassRatesCard(period: period)
                    .debugScrollAnchor("passrates")
                TrendsChecksCard(checks: period.checks)
                    .debugScrollAnchor("checks")
                if !period.hazards.isEmpty {
                    TrendsHazardTable(hazards: period.hazards)
                        .debugScrollAnchor("hazards")
                }
            }
        }
    }
}

// MARK: - Custom range: start (max = custom end) `至` end (max = today)

private struct TrendsCustomRangeRow: View {
    let model: TrendsModel
    let today: String

    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.utc
        return c
    }

    private func date(_ key: String) -> Date { LocalDay.date(fromKey: key, in: Self.utc) ?? Date() }

    var body: some View {
        let c = model.customRange(today: today)
        HStack(spacing: 8) {
            DatePicker("开始日期",
                       selection: Binding(get: { date(c.start) },
                                          set: { model.setCustomStart(LocalDay.key(for: $0, in: Self.utc), today: today) }),
                       in: ...date(c.end), displayedComponents: .date)
            Text("至")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
            DatePicker("结束日期",
                       selection: Binding(get: { date(c.end) },
                                          set: { model.setCustomEnd(LocalDay.key(for: $0, in: Self.utc), today: today) }),
                       in: ...date(today), displayedComponents: .date)
        }
        .labelsHidden()
        .datePickerStyle(.compact)
        .tint(Theme.accent)
        .environment(\.timeZone, Self.utc)
        .environment(\.calendar, calendar)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

// MARK: - `/trends` error: warning banner (e.g. `对方没有向你共享数据`) with a retry button

private struct TrendsErrorBanner: View {
    let message: String
    let retry: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .accessibilityHidden(true)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试", action: retry)
                .buttonStyle(.nl(.plain, size: .sm))
        }
        .nlBanner(.warn)
    }
}
