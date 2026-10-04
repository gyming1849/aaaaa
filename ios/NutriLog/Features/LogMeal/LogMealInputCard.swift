import SwiftUI

// MARK: - Input card (web1 §5.2 "Input card"): 日期 · 时间 · 餐次, 吃了什么, 照片, AI 分析 / 从食物库添加 + model note.

struct LogMealInputCard: View {
    @Environment(AppState.self) private var app
    @Bindable var model: LogMealModel
    let onOpenPicker: @MainActor () -> Void
    @FocusState private var textFocused: Bool
    @State private var consent: AIConsentRequest?

    /// Date pickers work in the device calendar; the `YYYY-MM-DD` keys are converted at the boundary.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    var body: some View {
        Card {
            // On phones: 日期 + 时间 on one row, 餐次 full width (web `grid g3 compact`).
            HStack(alignment: .top, spacing: 12) {
                LogMealField("日期") {
                    DatePicker("日期", selection: dateBinding, in: ...maxDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                LogMealField("时间") {
                    DatePicker("时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
            }
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.calendar, calendar)
            .environment(\.timeZone, .current)

            LogMealField("餐次") {
                Menu {
                    Picker("餐次", selection: $model.mealType) {
                        ForEach(Vocab.mealTypes, id: \.key) { m in
                            Text(m.zh).tag(m.key)
                        }
                    }
                } label: {
                    HStack {
                        Text(Vocab.mealZh(model.mealType))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                    }
                    .logMealInputChrome(.md)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("餐次"))
                .accessibilityValue(Text(Vocab.mealZh(model.mealType)))
            }

            LogMealField("吃了什么") {
                // The long placeholder is drawn as an overlay so it wraps fully instead of being truncated. The empty
                // prompt keeps the title (`吃了什么`, still the accessibility label) from showing underneath it.
                TextField("吃了什么", text: $model.text, prompt: Text(verbatim: ""), axis: .vertical)
                    .lineLimit(3...10)
                    .focused($textFocused)
                    .frame(minHeight: 66, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text("例：早上两个水煮蛋、一杯燕麦牛奶、半个苹果；中午一包李子柒螺蛳粉…（写上品牌、份量、做法会更准）")
                                .foregroundStyle(Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .logMealInputChrome(.md, focused: textFocused, verticalPadding: 10)
            }

            LogMealField("照片（可选：食物照片、包装、配料表、营养成分表）") {
                PhotoUploadStrip(model: model.photos, addLabel: "添加照片")
            }

            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 10) {
                    Button {
                        textFocused = false
                        app.withAIConsent($consent) { model.analyze() }
                    } label: {
                        Image(systemName: "sparkles")
                        Text(model.analyzeTitle)
                    }
                    .buttonStyle(.nl(.primary, size: .lg))
                    .disabled(!model.canAnalyze)

                    Button(action: onOpenPicker) {
                        Image(systemName: "books.vertical")
                        Text("从食物库添加")
                    }
                    .buttonStyle(.nl(.plain, size: .lg))
                }
                Text(model.aiNote)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .aiConsentPrompt($consent)
    }

    // MARK: Date / time bindings (`YYYY-MM-DD` / `HH:MM` strings in the model)

    private var maxDate: Date {
        LocalDay.date(fromKey: model.today, in: .current) ?? Date()
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { LocalDay.date(fromKey: model.date, in: .current) ?? maxDate },
            set: { picked in
                let key = LocalDay.key(for: picked, in: .current)
                // The picker caps at today; keep the cap even if the user scrolls past it.
                model.date = LocalDay.diffDays(model.today, key) > 0 ? model.today : key
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let base = LocalDay.date(fromKey: model.date, in: .current) ?? Date()
                let parts = model.time.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return base }
                return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: base) ?? base
            },
            set: { picked in model.time = LocalDay.hhmm(picked, in: .current) }
        )
    }
}
