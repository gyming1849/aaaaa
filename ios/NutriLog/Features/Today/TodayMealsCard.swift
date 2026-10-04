import SwiftUI

// MARK: - E1. Meals card `饮食记录` (web1 §4.3 E1; rep §2.3, §17.2; meals §2.14)
// Own view: the water row (`−` 250 ml when there is water, `+ 250 ml`), meal cards with ✎ (edit in Log Meal) and 🗑
// (confirmed delete, also in the long-press menu). The `饮水` pseudo-meal is hidden from the list. A member's view is
// read-only; when they share only the summary (`full == false`) no meal list is sent, so instead of the misleading
// "no record" the card says `只共享评分摘要` (the web's viewer-side wording for a summary share, web2 §5.4).

struct TodayMealsCard: View {
    let day: DayResponse
    /// `true` = another member's read-only day.
    let readOnly: Bool
    let isUpdatingWater: Bool
    let deletingMealId: Int?
    let onWater: @MainActor (Double) -> Void
    let onLogFirst: @MainActor () -> Void
    let onEdit: @MainActor (Meal) -> Void
    let onDelete: @MainActor (Meal) -> Void

    var body: some View {
        let meals = day.visibleMeals
        Card {
            CardHeader("饮食记录", icon: "fork.knife", hint: "\(day.score.mealCount) 餐 · \(fmt(day.score.energy.intake)) kcal")
            if !readOnly { waterRow }
            if meals.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(meals) { meal in
                        TodayMealRow(meal: meal, readOnly: readOnly, isDeleting: deletingMealId == meal.id,
                                     onEdit: { onEdit(meal) }, onDelete: { onDelete(meal) })
                    }
                }
            }
        }
    }

    // MARK: Water

    private var waterRow: some View {
        let water = day.waterMl
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "drop")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.s1)
                .accessibilityHidden(true)
            (Text("饮水 ")
                + Text(verbatim: fmt(water)).fontWeight(.bold).foregroundStyle(Theme.ink1)
                + Text(verbatim: " ml · 总水分 \(fmt(day.score.totals["water_g"] ?? 0)) / \(fmt(day.targets.intake["water_g"]?.value)) g（含食物）"))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if water > 0 {
                Button { onWater(-250) } label: { Text(verbatim: "−") }
                    .buttonStyle(.nl(.plain, size: .sm))
                    .accessibilityLabel(Text("减少 250 毫升"))
            }
            Button { onWater(250) } label: { Text("+ 250 ml") }
                .buttonStyle(.nl(.plain, size: .sm))
        }
        .disabled(isUpdatingWater)
        .padding(.top, -2)
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        if readOnly && !day.full {
            // Summary-only share: meals are never sent (rep §1), so "no record" would be wrong.
            VStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 26, weight: .light))
                    .frame(width: 36, height: 36)
                    .opacity(0.6)
                    .accessibilityHidden(true)
                Text("只共享评分摘要")
                    .font(Theme.Font.body)
            }
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        } else if readOnly {
            EmptyState("这一天没有记录", icon: "fork.knife")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 30, weight: .light))
                    .frame(width: 36, height: 36)
                    .opacity(0.6)
                    .accessibilityHidden(true)
                Text("还没有记录。")
                    .font(Theme.Font.body)
                Button(action: onLogFirst) {
                    Label("记录第一餐", systemImage: "plus")
                }
                .buttonStyle(.nl(.primary))
                .padding(.top, 4)
            }
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - One meal (web `.meal-card`): bordered, radius 12, padding 12×14.

private struct TodayMealRow: View {
    let meal: Meal
    let readOnly: Bool
    let isDeleting: Bool
    let onEdit: @MainActor () -> Void
    let onDelete: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if !meal.description.isEmpty {
                Text(verbatim: "“\(meal.description)”")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(meal.items.enumerated()), id: \.offset) { _, item in
                    itemRow(item)
                }
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
        .opacity(isDeleting ? 0.5 : 1)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            if !readOnly {
                Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
                Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
            }
        }
    }

    private var head: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(verbatim: meal.time)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .frame(minWidth: 42, alignment: .leading)
            Text(Vocab.mealZh(meal.meal_type))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(verbatim: TodayText.kcal(meal.kcal))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            if !readOnly {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
                .accessibilityLabel(Text("编辑"))
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.criticalText)
                }
                .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
                .accessibilityLabel(Text("删除"))
                .disabled(isDeleting)
            }
        }
    }

    /// Web `.meal-item`: name + muted amount (+ serious shield when the item carries hazards) … `{kcal} kcal`.
    private func itemRow(_ item: MealItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            (Text(verbatim: item.name).foregroundStyle(Theme.ink1)
                + Text(verbatim: " ")
                + Text(verbatim: TodayText.amount(item)).font(Theme.Font.small).foregroundStyle(Theme.ink3)
                + (item.hazards.isEmpty ? Text(verbatim: "")
                   : Text(verbatim: " ") + Text(Image(systemName: "exclamationmark.shield")).font(.system(size: 12)).foregroundStyle(Theme.serious)))
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: item.hazards.isEmpty
                                         ? "\(item.name) \(TodayText.amount(item))"
                                         : "\(item.name) \(TodayText.amount(item))，含风险项"))
            Text(verbatim: TodayText.kcal(item.nutrients["energy_kcal"]))
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }
}
