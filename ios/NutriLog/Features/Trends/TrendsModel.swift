import SwiftUI
import Observation

// MARK: - Trends view model (web2 §5.1.1–§5.1.4; web `pages/Trends.tsx`)
// Three independent loads, like the web's three `useLoad`s: `/trends` and `/period` re-fire when start/end/member change
// (and on pull-to-refresh / `dataVersion`), `/profile/targets` only for the own view. Previous data stays visible while
// reloading (the screen dims it to 0.55). `/trends` errors surface as a warning banner (with 重试 on iOS); `/period`
// and `/profile/targets` errors are silent, as on the web: their sections fall back to `—` or stay hidden.

@MainActor @Observable final class TrendsModel {
    /// Range preset (default `30 天`).
    var range: TrendsRange = .d30
    /// Custom range; nil until the user edits it (then `today − 59 … today`).
    var customStart: String?
    var customEnd: String?
    /// Nutrient-explorer metric (default `sodium_mg`).
    var metricKey = TrendsBucketing.defaultMetricKey

    private(set) var trends: TrendsResponse?
    private(set) var trendsError: String?
    private(set) var isLoadingTrends = false
    private(set) var period: PeriodScore?
    private(set) var targets: Targets?

    /// Days after the 全部 trim, their bucket unit and buckets (recomputed when `/trends` returns).
    private(set) var days: [TrendDay] = []
    private(set) var unit: TrendsUnit = .day
    private(set) var buckets: [TrendsBucket] = []

    @ObservationIgnored private var trendsGeneration = 0
    @ObservationIgnored private var periodGeneration = 0
    @ObservationIgnored private var targetsGeneration = 0
    /// Key (`start|end|member|dataVersion`) and time of the last successful load; see `load(app:other:force:)`.
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var loadedAt: Date?
    private static let reuseInterval: TimeInterval = 300

    // MARK: Range

    func customRange(today: String) -> (start: String, end: String) {
        let d = TrendsBucketing.defaultCustom(today: today)
        return (customStart ?? d.start, customEnd ?? d.end)
    }

    /// Effective `start`/`end` for the current preset.
    func bounds(today: String) -> (start: String, end: String) {
        let c = customRange(today: today)
        return TrendsBucketing.bounds(range, today: today, customStart: c.start, customEnd: c.end)
    }

    /// Sets the custom start (the picker caps it at the custom end).
    func setCustomStart(_ date: String, today: String) {
        let c = customRange(today: today)
        customStart = date
        customEnd = c.end
    }

    /// Sets the custom end (the picker caps it at today).
    func setCustomEnd(_ date: String, today: String) {
        let c = customRange(today: today)
        customStart = c.start
        customEnd = date
    }

    /// Changes the range preset, re-bucketing the data on screen at once (the web derives `days` from the current range).
    func selectRange(_ newRange: TrendsRange) {
        guard newRange != range else { return }
        range = newRange
        rebuild()
    }

    // MARK: Loading

    /// `/trends` + `/period` in parallel for the current range.
    /// `force == false` (the view's `.task`) skips the reload when the same range was loaded successfully less than
    /// `reuseInterval` ago: `.task` re-fires every time the tab re-appears, and 全部 is about 3 MB (rep §10.1 "cache on
    /// device"). A new range, member or `dataVersion` changes the key and always reloads; pull-to-refresh forces it.
    /// Only a load where both `/trends` and `/period` succeeded is reused, so a failed (silent) `/period` is retried
    /// the next time the screen appears, as the web refetches both on every visit.
    func load(app: AppState, other: String?, force: Bool = false) async {
        let (start, end) = bounds(today: app.today)
        let key = "\(start)|\(end)|\(other ?? "")|\(app.dataVersion)"
        if !force, key == loadedKey, let at = loadedAt, Date().timeIntervalSince(at) < Self.reuseInterval, trendsError == nil {
            return
        }
        async let trendsDone: Bool = loadTrends(api: app.api, start: start, end: end, other: other)
        async let periodDone: Bool = loadPeriod(api: app.api, start: start, end: end, other: other)
        let (trendsOK, periodOK) = await (trendsDone, periodDone)
        if trendsOK && periodOK {
            loadedKey = key
            loadedAt = Date()
        } else if trendsOK || periodOK {
            // A partial success replaces only part of the data on screen: never reuse it.
            loadedKey = nil
            loadedAt = nil
        }
    }

    /// Pull-to-refresh: everything, including the targets.
    func refresh(app: AppState, other: String?) async {
        async let main: Void = load(app: app, other: other, force: true)
        async let targetsDone: Void = loadTargets(app: app, other: other)
        _ = await (main, targetsDone)
    }

    /// `GET /profile/targets` (today's targets) for the own view; a member's view draws no target lines.
    func loadTargets(app: AppState, other: String?) async {
        targetsGeneration += 1
        let generation = targetsGeneration
        guard other == nil else {
            targets = nil
            return
        }
        do {
            let fresh = try await app.api.targets(date: nil)
            guard generation == targetsGeneration, !Task.isCancelled else { return }
            targets = fresh
        } catch {
            // Silent, as on the web: the explorer simply has no target lines.
        }
    }

    /// Returns true when this call stored a fresh `/trends` response.
    private func loadTrends(api: APIClient, start: String, end: String, other: String?) async -> Bool {
        trendsGeneration += 1
        let generation = trendsGeneration
        isLoadingTrends = true
        defer { if generation == trendsGeneration { isLoadingTrends = false } }
        do {
            let fresh = try await api.trends(start: start, end: end, user: other)
            guard generation == trendsGeneration, !Task.isCancelled else { return false }
            trends = fresh
            trendsError = nil
            rebuild()
            return true
        } catch is CancellationError {
            // Superseded by a newer range, or the screen went away (it reloads when it re-appears).
            return false
        } catch {
            guard generation == trendsGeneration, !Task.isCancelled else { return false }
            trendsError = APIError.from(error).message
            return false
        }
    }

    /// Returns true when this call stored a fresh `/period` response.
    private func loadPeriod(api: APIClient, start: String, end: String, other: String?) async -> Bool {
        periodGeneration += 1
        let generation = periodGeneration
        do {
            let fresh = try await api.period(start: TrendsBucketing.periodStart(start: start, end: end), end: end, user: other)
            guard generation == periodGeneration, !Task.isCancelled else { return false }
            period = fresh
            return true
        } catch {
            // Silent, as on the web: tiles show `—`, the period sections stay hidden (or keep the last period).
            return false
        }
    }

    /// Recomputes the trimmed days, unit and buckets from the loaded `/trends` and the current preset.
    private func rebuild() {
        let trimmed = TrendsBucketing.trimmed(trends?.days ?? [], range: range)
        let newUnit = TrendsBucketing.unit(span: trimmed.count)
        days = trimmed
        unit = newUnit
        buckets = TrendsBucketing.bucketize(trimmed, unit: newUnit)
    }
}
