import SwiftUI
import Charts

// MARK: - 步数与活动能量 (web1 §7.2 2b; body §3.8)
// The day-totals form (`PUT /activity/{date}` with all 7 fields; an empty field clears the stored value), the AI screenshot
// entry, the energy footnote and a 30-day steps bar chart from the 90-day `/trends` load.

struct BodyActivityCard: View {
    @Environment(AppState.self) private var app
    @Bindable var model: BodyModel
    let onRecognize: @MainActor () -> Void

    var body: some View {
        Card {
            CardHeader("步数与活动能量", icon: "shoeprints.fill", hint: hint)
            LazyVGrid(columns: BodyGrid.twoColumns, alignment: .leading, spacing: 12) {
                ForEach(BodyActivityField.allCases) { field in
                    NumberField(field.label,
                                value: Binding(get: { model.activityValue(field) }, set: { model.setActivityValue(field, $0) }),
                                unit: field.unit)
                }
            }
            .disabled(!model.activityReady)
            if app.healthSync.status.isEnabled {
                Banner("开启 Apple 健康同步后，你手动修改的数值会被保留，不会被同步覆盖", icon: "info.circle")
            }
            FlowLayout(spacing: 10) {
                Button {
                    Task { await model.saveActivity(app: app) }
                } label: {
                    if model.isSavingActivity { Spinner() }
                    Text(verbatim: "保存 \(model.date) 的活动数据")
                }
                .buttonStyle(.nl())
                .disabled(!model.activityReady || model.isSavingActivity)
                Button(action: onRecognize) {
                    Image(systemName: "camera")
                    Text("上传健康截图识别")
                }
                .buttonStyle(.nl(.primary))
            }
            Text("有“活动能量”时，消耗 = 静息 + 活动能量 + 未被设备记录的运动；只有步数时按步长与体重估算。")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if model.trendDays.contains(where: { $0.steps != nil }) {
                BodyStepsChart(days: Array(model.trendDays.suffix(30)))
            }
        }
    }

    /// `来源：手动 / iPhone 快捷指令 / …` when the day has a row, else `未记录` — but only once the window of the
    /// selected date has loaded (no "未记录" flash while a newly picked date is loading).
    private var hint: String? {
        if let day = model.day { return "来源：\(Vocab.activitySourceLabel(day.source))" }
        return model.activityReady ? "未记录" : nil
    }
}

/// Bars in series-1 with rounded tops (max width 20), `MM-DD` labels, y unit `步`, tooltip `步数 {fmt(steps)}`.
private struct BodyStepsChart: View {
    let labels: [String]
    let steps: [Double?]
    @State private var selected: String?

    init(days: [TrendDay]) {
        labels = days.map { BodyDates.monthDay($0.date) }
        steps = days.map(\.steps)
    }

    var body: some View {
        // Every 6th day is labelled. Marks are declared for every category and only the tick days get a label: a
        // subset passed to `AxisMarks(values:)` on this String scale still labelled all 30 bars (unreadable smear).
        let ticks = Set(labels.enumerated().filter { $0.offset % 6 == 0 }.map(\.element))
        Chart {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                if let s = steps[i] {
                    BarMark(x: .value("日期", label), y: .value("步数", s), width: .ratio(0.7))
                        .foregroundStyle(Theme.s1)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
                }
            }
        }
        .chartXScale(domain: labels)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: labels) { value in
                if let s = value.as(String.self), ticks.contains(s) {
                    AxisValueLabel(anchor: .top, collisionResolution: .greedy) {
                        Text(verbatim: s).font(Theme.Font.axis).foregroundStyle(Theme.ink3).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.hair)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(verbatim: fmt(v)).font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
                }
            }
        }
        .chartYAxisLabel(position: .topLeading) { Text("步").font(Theme.Font.axis).foregroundStyle(Theme.ink3) }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) { Rectangle().fill(Theme.axis).frame(height: 1) }
        }
        .chartSelectionTooltip($selected, pointer: .band(count: labels.count)) { label in
            guard let i = labels.firstIndex(of: label) else { return nil }
            return ChartTooltipData(title: label, rows: [
                ChartTooltipRow(color: Theme.s1, name: "步数", value: steps[i].map { fmt($0) } ?? "—"),
            ])
        }
        .frame(height: 180)
    }
}
