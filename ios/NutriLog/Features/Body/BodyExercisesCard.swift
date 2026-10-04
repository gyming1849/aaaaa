import SwiftUI

// MARK: - 记录运动 (web1 §7.2 2a; body §3.9–§3.11)
// AI entry banner (opens the recognizer in `ai` mode), the 手动选择运动类型 disclosure (`POST /exercises`), and the
// workouts of the selected date with the `in_device` checkbox (`PATCH`) and the trash button (`DELETE`, immediate like the web).

struct BodyExercisesCard: View {
    @Environment(AppState.self) private var app
    @Bindable var model: BodyModel
    let onRecognize: @MainActor () -> Void
    @State private var manualExpanded = false

    var body: some View {
        Card {
            CardHeader("记录运动", icon: "flame", hint: model.date)
            aiBanner
            manualSection
            list
        }
    }

    private var modelName: String { app.isMockAI ? "离线规则" : (app.me?.ai.model ?? "") }

    private var aiBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "说一句“游泳 5km”“打了两小时羽毛球”，或上传手表的运动记录截图，由 \(modelName) 按 2024 运动代谢当量表识别，先预览再合并。")
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRecognize) {
                Image(systemName: "sparkles")
                Text("AI 识别运动 / 截图")
            }
            .buttonStyle(.nl(.primary, size: .sm))
        }
        .nlBanner(.accent)
    }

    private var manualSection: some View {
        DisclosureGroup(isExpanded: $manualExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                BodyMenuPicker("运动类型", selection: $model.manualActivityKey,
                               options: (app.meta?.activities ?? []).map { BodyPickerOption(key: $0.key, label: "\($0.zh)（MET \(DSFormat.js($0.met))）") })
                HStack(spacing: 10) {
                    NumberField("", value: $model.manualMinutes, unit: "分钟")
                        .accessibilityLabel(Text("分钟"))
                        .frame(width: 130)
                    Button {
                        Task { await model.addManualExercise(app: app) }
                    } label: {
                        if model.isAddingExercise { Spinner() }
                        Text("添加")
                    }
                    .buttonStyle(.nl(.plain, size: .sm))
                    .disabled(model.isAddingExercise || model.date.isEmpty)
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("手动选择运动类型")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
        }
        .tint(Theme.ink3)
    }

    @ViewBuilder private var list: some View {
        let rows = model.exercisesOnDate
        if rows.isEmpty {
            Text("这一天还没有运动记录")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, exercise in
                    if i > 0 { Rectangle().fill(Theme.hair).frame(height: 1) }
                    BodyExerciseRow(
                        exercise: exercise,
                        inDevice: Binding(get: { model.inDevice(exercise) },
                                          set: { on in Task { await model.setInDevice(exercise, on, app: app) } }),
                        onDelete: { Task { await model.deleteExercise(exercise, app: app) } }
                    )
                }
            }
        }
    }
}

/// flame · `{description} {fmt(duration)} 分钟 · MET {met}[ · {km} km]` / checkbox `已含在设备活动能量中` · `{kcal} kcal` · trash.
private struct BodyExerciseRow: View {
    let exercise: Exercise
    @Binding var inDevice: Bool
    let onDelete: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flame")
                .font(.system(size: 15))
                .foregroundStyle(Theme.s2)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink1)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("已含在设备活动能量中", isOn: $inDevice)
                    .toggleStyle(.bodyCheckboxMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(fmt(exercise.kcal)) kcal")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink1)
                .monospacedDigit()
                .fixedSize()
                .padding(.top, 1)
            BodyDeleteButton(action: onDelete)
                .padding(.top, -5)
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
        }
    }

    private var title: AttributedString {
        var out = AttributedString(exercise.description + " ")
        var detail = "\(fmt(exercise.duration_min)) 分钟 · MET \(DSFormat.js(exercise.met))"
        if let km = exercise.distance_km, km != 0 { detail += " · \(fmt(km, 1)) km" }
        var small = AttributedString(detail)
        small.font = Theme.Font.small
        small.foregroundColor = Theme.ink3
        out += small
        return out
    }
}
