import SwiftUI

// MARK: - ActivityRecognizer (web1 §6; body §4). Owner: WP4. Signature `init(date:current:mode:onDone:)` is the contract.
// Presented in a sheet by Today (WP2, both modes) and Body (WP4, `ai`). After a successful commit it toasts
// `已合并到当天记录`, calls `app.noteDataChanged()`, then `onDone` and dismisses itself.
//
// Stages: ai without a draft → description + screenshots + `AI 识别` (spinner + `{n}s` while polling);
// draft → notes / date banners, 活动 and 身体 fields, 运动 workouts, live 合并预览, `取消` + `确认合并到 {date}`.
// iOS additions: a header date picker (≤ today), a hint that emptied fields are kept by the merge, and resuming a
// pending AI job (< 30 min) for the same date when the sheet reopens.

struct ActivityRecognizerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    let date: String; let current: ActivityDay?; let mode: RecognizerMode; let onDone: @MainActor () -> Void
    @State private var model: ActivityRecognizerModel
    @State private var consent: AIConsentRequest?

    init(date: String, current: ActivityDay?, mode: RecognizerMode, onDone: @escaping @MainActor () -> Void) {
        self.date = date; self.current = current; self.mode = mode; self.onDone = onDone
        _model = State(initialValue: ActivityRecognizerModel(date: date, current: current, mode: mode))
    }

    var body: some View {
        SheetScaffold(title: title, primary: primaryAction, secondary: secondaryAction) {
            VStack(alignment: .leading, spacing: 18) {
                BodyDateField("日期",
                              date: Binding(get: { model.effectiveDate }, set: { model.setDate($0) }),
                              maxDate: app.today, accessibilityName: "日期")
                    .disabled(model.isRecognizing || model.isSaving)
                if model.draft != nil {
                    draftStage
                } else {
                    inputStage
                }
            }
            .bodyKeyboardDoneButton()
        }
        .interactiveDismissDisabled(model.isSaving)
        .aiConsentPrompt($consent)
        .onAppear { model.appear(app: app) }
        .onDisappear { model.stop(app: app) }
        .task(id: model.previewKey) { await model.refreshPreview(app: app) }
        .task(id: model.draft?.date) { await model.loadStored(app: app) }
    }

    private var title: String {
        mode == .manual ? "填写 \(model.effectiveDate) 的活动与身体数据" : "AI 识别活动与身体数据"
    }

    // MARK: Footer

    private var primaryAction: SheetAction {
        if let draft = model.draft {
            return SheetAction(title: "确认合并到 \(draft.date)", icon: "checkmark", isBusy: model.isSaving) {
                Task {
                    if await model.commit(app: app) {
                        // Dismiss first, then let the presenter clear its own state (it may also nil its item).
                        dismiss()
                        onDone()
                    }
                }
            }
        }
        return SheetAction(title: model.isRecognizing ? "\(model.elapsed)s" : "AI 识别", icon: "sparkles",
                           isEnabled: model.canRecognize, isBusy: model.isRecognizing) {
            BodyKeyboard.dismiss()
            app.withAIConsent($consent) { model.recognize(app: app) }
        }
    }

    private var secondaryAction: SheetAction? {
        guard model.draft != nil else { return nil }
        return SheetAction(title: "取消") { dismiss() }
    }

    // MARK: AI input stage

    @ViewBuilder private var inputStage: some View {
        Text(verbatim: "用一句话描述，或上传“健康”App / 健身圆环 / 手表运动记录 / 体脂秤 / 血压计的截图，由 \(app.isMockAI ? "离线规则（未配置 AI，无法读图）" : (app.me?.ai.model ?? "")) 识别步数、能量、睡眠、体重和每次运动。识别结果会先给你预览，确认后才合并。")
            .font(Theme.Font.small)
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        TextField("活动描述", text: $model.text, prompt: Text("例：今天走了 8500 步，下午游泳 5km，昨晚睡了 7 个半小时，睡前体重 70.2").foregroundStyle(Theme.ink3),
                  axis: .vertical)
            .lineLimit(3, reservesSpace: true)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 10)
            .bodyInputChrome()
            .disabled(model.isRecognizing)
        if let photos = model.photos {
            PhotoUploadStrip(model: photos, addLabel: "上传截图")
                .disabled(model.isRecognizing)
        }
        if model.isRecognizing {
            Text(model.jobPhase == .queued ? "排队中…" : JobProgressView.activityHint(model.elapsed))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .nlPulse()
        }
    }

    // MARK: Draft stage

    @ViewBuilder private var draftStage: some View {
        if let draft = model.draft {
            if !draft.notes.isEmpty {
                Banner(draft.notes, icon: "sparkles", style: .accent)
            }
            if draft.date_from_image {
                Banner("截图显示的日期是 \(draft.date)，将合并到这一天。", style: .warn)
            }
            VStack(alignment: .leading, spacing: 10) {
                BodySectionTitle("活动")
                LazyVGrid(columns: BodyGrid.twoColumns, alignment: .leading, spacing: 12) {
                    ForEach(ActivityRecognizerActField.allCases) { field in
                        NumberField(field.label,
                                    value: Binding(get: { model.activityValue(field) }, set: { model.setActivityValue(field, $0) }),
                                    unit: field.unit)
                    }
                }
                if model.keepsStoredValues {
                    Label {
                        Text("留空的项目会保留已记录的数值，合并不会清除数据；如需清除，请在“身体”页的“步数与活动能量”中修改后保存。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                BodySectionTitle("身体")
                LazyVGrid(columns: BodyGrid.twoColumns, alignment: .leading, spacing: 12) {
                    ForEach(ActivityRecognizerBodyField.allCases) { field in
                        NumberField(field.label,
                                    value: Binding(get: { model.bodyValue(field) }, set: { model.setBodyValue(field, $0) }),
                                    unit: field.unit)
                    }
                }
            }
            workouts(draft.workouts)
            if let preview = model.preview {
                ImpactPreviewCard(preview: preview)
            }
        }
    }

    private func workouts(_ list: [WorkoutDraft]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BodySectionTitle("运动")
                Spacer()
                Button {
                    model.addWorkout()
                } label: {
                    Image(systemName: "plus")
                    Text("添加一项")
                }
                .buttonStyle(.nl(.plain, size: .sm))
            }
            if list.isEmpty {
                Text("没有运动")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            }
            ForEach(list) { w in
                WorkoutEditorRow(
                    workout: Binding(get: { model.workout(id: w.id) ?? w }, set: { model.updateWorkout($0) }),
                    activities: app.meta?.activities ?? [],
                    weightKg: app.profile?.weight_kg ?? 65,
                    onDelete: { model.removeWorkout(id: w.id) }
                )
            }
        }
    }
}
