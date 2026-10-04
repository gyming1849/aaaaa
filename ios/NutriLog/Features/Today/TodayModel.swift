import SwiftUI
import Observation

// MARK: - Today view model (web1 §4.1; rep §1–§2)
// Loads `GET /day/{date}` (own) or `GET /day/{date}?user=` (a member who shares with you). The previous day stays
// visible while a reload runs; only the newest request may change the state (date taps can overlap).
// Mutations (water ±250 ml, meal delete) call `app.noteDataChanged()`, which reloads this screen through its
// `.task(id:)` key and every other screen that shows day data.

@MainActor @Observable final class TodayModel {
    /// The last successfully loaded day (kept while a newer request is in flight).
    private(set) var day: DayResponse?
    /// Screen-level load error (shown as a warn banner with 重试). Cleared by the next successful load.
    private(set) var error: String?
    private(set) var isLoading = false
    /// `POST /water` in flight (disables the ± buttons).
    private(set) var isUpdatingWater = false
    /// `DELETE /meals/{id}` in flight for this meal id.
    private(set) var deletingMealId: Int?

    @ObservationIgnored private var generation = 0

    init() {}

    /// `true` while the visible day belongs to another date than the one being requested.
    func isShowingStale(for date: String) -> Bool { day.map { $0.date != date } ?? false }

    /// `GET /day/{date}` (+ `?user=` for a member). Cancellation (date changed, screen left) is silent.
    func load(app: AppState, date: String, member: String?) async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let fresh = try await app.api.day(date, user: member)
            guard gen == generation, !Task.isCancelled else { return }
            day = fresh
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            self.error = APIError.from(error).message
        }
    }

    /// `POST /water {date, ml}` (web1 §4.3 E1): +250 or −250 ml. Errors are toasted.
    func addWater(app: AppState, date: String, ml: Double) async {
        guard !isUpdatingWater else { return }
        isUpdatingWater = true
        defer { isUpdatingWater = false }
        do {
            _ = try await app.api.addWater(ml: ml, date: date)
            app.noteDataChanged()
        } catch {
            app.toasts.error(error)
        }
    }

    /// `DELETE /meals/{id}` after the confirmation dialog; toast `已删除` (errors are toasted, unlike the web).
    func deleteMeal(app: AppState, meal: Meal) async {
        guard deletingMealId == nil else { return }
        deletingMealId = meal.id
        defer { deletingMealId = nil }
        do {
            try await app.api.deleteMeal(id: meal.id)
            app.toasts.show("已删除")
            app.noteDataChanged()
        } catch {
            app.toasts.error(error)
        }
    }
}

// MARK: - Shared Today helpers

/// Which ActivityRecognizer mode the Today activity card opened (web `mode: "ai" | "manual" | null`).
struct TodayRecognizerRequest: Identifiable, Hashable, Sendable {
    let mode: RecognizerMode
    let date: String
    var id: String { "\(mode.rawValue)|\(date)" }
}

/// Small text helpers used across the Today cards.
enum TodayText {
    /// Web `{fmt(it.nutrients.energy_kcal)} kcal`.
    static func kcal(_ v: Double?) -> String { "\(fmt(v)) kcal" }

    /// Item amount: `amount_desc` when non-empty, else `{fmt(amount_g)} g` (web `it.amount_desc || …`).
    static func amount(_ item: MealItem) -> String {
        if let d = item.amount_desc, !d.isEmpty { return d }
        return "\(fmt(item.amount_g)) g"
    }

    /// Body row value (web1 §4.3 E2): `{kg} kg` + ` · 体脂 {x}%` + ` · 血压 {s}/{d}`, each part only when present.
    static func bodyRow(_ b: BodyMetric) -> String {
        var s = ""
        if let w = b.weight_kg { s += "\(fmt(w, 1)) kg" }
        if let f = b.body_fat_pct { s += " · 体脂 \(fmt(f, 1))%" }
        if let sbp = b.sbp { s += " · 血压 \(fmt(sbp))/\(fmt(b.dbp))" }
        return s
    }

    /// The meal-delete confirmation title: `删除 {time} 的{餐次}？`.
    static func deleteTitle(_ meal: Meal) -> String { "删除 \(meal.time) 的\(Vocab.mealZh(meal.meal_type))？" }
}

// MARK: - Plain stat (web `.stat` inside a card): label 13 ink-2, value 26 semibold ink with an inline 14 pt ink-3 unit,
// optional 12.5 pt ink-3 delta. Unlike the design system's `StatTile` it has no card chrome of its own.

struct TodayStat: View {
    let label: String
    let value: String
    var unit: String?
    var delta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    valueText
                    if let unit { unitText(unit) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    valueText.minimumScaleFactor(0.6)
                    if let unit { unitText(unit) }
                }
            }
            if let delta, !delta.isEmpty {
                Text(delta)
                    .font(Theme.Font.hint)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value)
            .font(Theme.Font.statValue)
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func unitText(_ unit: String) -> some View {
        Text(unit)
            .font(Theme.Font.statUnit)
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
    }
}

/// A row of a hairline-separated list (web `.list-item`: 12 pt gap, 11 pt vertical padding, hair bottom border).
struct TodayListDivider: View {
    var body: some View { Rectangle().fill(Theme.hair).frame(height: 1) }
}

/// Header with a title and trailing controls that drop under the title when they do not fit on one line.
struct TodayCardHeader<Controls: View>: View {
    let title: String
    let icon: String?
    let controls: Controls

    init(_ title: String, icon: String? = nil, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.icon = icon
        self.controls = controls()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                CardHeader(title, icon: icon).fixedSize()
                Spacer(minLength: 6)
                controls.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title, icon: icon)
                controls
            }
        }
    }
}
