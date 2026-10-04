import SwiftUI

// MARK: - 记录体重 (web1 §7.2 1a; body §3.1–§3.3)
// Weight / time / body fat / waist / blood pressure form, `POST /body`, then the newest 30 rows in a ~220 pt scroll area.
// Rows are deleted with a swipe (no confirmation, like the web's trash button), a long-press menu or the VoiceOver action.

struct BodyWeightCard: View {
    @Environment(AppState.self) private var app
    @Bindable var model: BodyModel

    var body: some View {
        Card {
            CardHeader("记录体重", icon: "scalemass", hint: "建议每晚睡前、同一时间称")
            fields
            if model.weightForm.sbp != nil {
                Toggle("正在服用降压药", isOn: $model.weightForm.bp_treated)
                    .toggleStyle(.bodyCheckbox)
            }
            Button {
                Task { await model.saveWeight(app: app) }
            } label: {
                if model.isSavingWeight { Spinner(track: Theme.accentInk.opacity(0.35), head: Theme.accentInk) }
                Text("保存")
            }
            .buttonStyle(.nl(.primary, block: true))
            .disabled(!model.weightForm.canSave || model.isSavingWeight)
            if !model.recentBodyRows.isEmpty {
                BodyWeightHistoryList(rows: Array(model.recentBodyRows)) { row in
                    Task { await model.deleteBodyRow(row, app: app) }
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: BodyGrid.twoColumns, alignment: .leading, spacing: 12) {
                NumberField("体重", value: $model.weightForm.weight_kg, unit: "kg")
                BodyTimeField("时间", time: $model.weightForm.time)
                NumberField("体脂率（可选）", value: $model.weightForm.body_fat_pct, unit: "%")
                NumberField("腰围（可选）", value: $model.weightForm.waist_cm, unit: "cm")
            }
            VStack(alignment: .leading, spacing: 6) {
                BodyFieldLabel("血压（可选）")
                HStack(spacing: 8) {
                    NumberField("", value: $model.weightForm.sbp, prompt: "收缩压")
                        .accessibilityLabel(Text("收缩压"))
                    Text(verbatim: "/").foregroundStyle(Theme.ink3).accessibilityHidden(true)
                    NumberField("", value: $model.weightForm.dbp, prompt: "舒张压")
                        .accessibilityLabel(Text("舒张压"))
                }
            }
        }
    }
}

/// The history rows (web: newest 30, `max-height: 220`, scrolling). A plain `List` so rows get native swipe actions.
private struct BodyWeightHistoryList: View {
    let rows: [BodyMetric]
    let onDelete: @MainActor (BodyMetric) -> Void

    private static let rowHeight: CGFloat = 44
    private static let maxHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hair).frame(height: 1)
            List {
                ForEach(rows) { row in
                    BodyWeightHistoryRow(row: row)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.hair)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { onDelete(row) } label: { Label("删除", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { onDelete(row) } label: { Label("删除", systemImage: "trash") }
                        }
                        .accessibilityAction(named: Text("删除")) { onDelete(row) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 36)
            .frame(height: min(Self.maxHeight, CGFloat(rows.count) * Self.rowHeight))
        }
    }
}

/// `{MM-DD} {time}` · **{w} kg** · 体脂 {x}% · 腰围 {x} cm · 血压 {sbp}/{dbp} · source label.
private struct BodyWeightHistoryRow: View {
    let row: BodyMetric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(BodyDates.monthDay(row.date)) \(row.time)")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
                .frame(width: 92, alignment: .leading)
            Text(values)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink1)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            let source = Vocab.bodySourceLabel(row.source)
            if !source.isEmpty {
                Text(source)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Web concatenation; the leading ` · ` is dropped when there is no weight.
    private var values: AttributedString {
        var out = AttributedString()
        if let w = row.weight_kg {
            var bold = AttributedString("\(fmt(w, 1)) kg")
            bold.inlinePresentationIntent = .stronglyEmphasized
            out += bold
        }
        var rest: [String] = []
        if let f = row.body_fat_pct { rest.append("体脂 \(fmt(f, 1))%") }
        if let w = row.waist_cm { rest.append("腰围 \(fmt(w, 1)) cm") }
        if let s = row.sbp { rest.append("血压 \(fmt(s))/\(fmt(row.dbp))") }
        if !rest.isEmpty {
            out += AttributedString((row.weight_kg == nil ? "" : " · ") + rest.joined(separator: " · "))
        }
        return out
    }
}
