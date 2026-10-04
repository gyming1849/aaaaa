import SwiftUI

// MARK: - 记一餐 / 编辑这一餐 (web1 §5; meals §2–§4, §6.1)
// Presented as a sheet by MainTabView (`router.logMeal`). Phases: input → analyzing → review.
// After saving: `app.router.logMeal = nil; app.noteDataChanged(); app.router.showToday(date:)` (LogMealModel.save).

struct LogMealScreen: View {
    @Environment(AppState.self) private var app
    let request: LogMealRequest

    init(request: LogMealRequest) { self.request = request }

    var body: some View {
        LogMealContainer(app: app, request: request)
    }
}

private struct LogMealContainer: View {
    @State private var model: LogMealModel
    @State private var showPicker = false
    @State private var saveTarget: DraftItem?
    @State private var confirmDiscard = false
    @State private var consent: AIConsentRequest?

    init(app: AppState, request: LogMealRequest) {
        _model = State(initialValue: LogMealModel(app: app, request: request))
    }

    private enum Anchor: Hashable { case review }

    var body: some View {
        // Captured per body evaluation, so each analysis task only runs the run it was started for.
        let runId = model.analysisRunId
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                        Text("用自然语言描述即可，比如“中午一碗牛肉面加一个卤蛋，喝了杯无糖豆浆”")
                            .font(Theme.Font.subtitle)
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)

                        if let job = model.resumableJob, model.phase == .input {
                            LogMealResumeBanner(job: job, onResume: model.resumePendingJob, onDismiss: model.dismissPendingJob)
                        }

                        if !model.isEditLoaded {
                            if let error = model.editError, !model.isLoadingEdit {
                                LogMealErrorBanner(message: error) { Task { await model.loadEditIfNeeded() } }
                            } else {
                                Card { LoadingView() }
                            }
                        } else {
                            LogMealInputCard(model: model, onOpenPicker: { showPicker = true })
                        }

                        if model.phase == .analyzing {
                            LogMealAnalyzingCard(phase: model.jobPhase, startedAt: model.analysisStartedAt, onCancel: model.cancelAnalysis)
                        }

                        if model.phase == .review {
                            if let draft = model.draft, !draft.summary.isEmpty || !draft.questions.isEmpty {
                                LogMealDraftInfo(draft: draft, canSubmit: model.canAnalyze, onFollowUp: { extra in model.app.withAIConsent($consent) { model.analyze(extra: extra) } })
                            }
                            LogMealReviewCard(model: model, onOpenPicker: { showPicker = true }, onSaveItem: { saveTarget = model.item(id: $0) })
                                .id(Anchor.review)
                        }

                        if model.phase == .input, model.items.isEmpty, !model.isEdit, !model.quickFoods.isEmpty {
                            QuickFoodsCard(foods: model.quickFoods, onPick: model.setQuickItem)
                        }
                    }
                    .padding(Theme.Metrics.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.2), value: model.phase)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.phase) { old, new in
                    // A finished analysis lands below the tall input card: bring the review list into view.
                    guard old == .analyzing, new == .review else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Anchor.review, anchor: .top) }
                    }
                }
            }
            .background(Theme.page)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.page, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if model.hasUnsavedChanges { confirmDiscard = true } else { model.close() }
                    }
                }
                LogMealKeyboardDone()
            }
            .confirmationDialog("放弃未保存的内容？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { model.close() }
                Button("继续编辑", role: .cancel) {}
            }
            .interactiveDismissDisabled(model.hasUnsavedChanges)
            .aiConsentPrompt($consent)
            .task { await model.loadEditIfNeeded() }
            .task { await model.loadQuickFoods() }
            .task { await model.ensureMeta() }
            .task(id: runId) { await model.performAnalysisRun(runId) }
            .task(id: model.previewKey) { await model.refreshPreview() }
            .sheet(isPresented: $showPicker) {
                FoodPickerSheet { item in model.appendItem(item) }
            }
            .sheet(item: $saveTarget) { item in
                SaveFoodSheet(item: item, sources: model.draft?.sources ?? []) { foodId in
                    model.markSaved(itemId: item.id, foodId: foodId)
                }
            }
        }
        .tint(Theme.accent)
    }
}

// MARK: - Review card (`审核解析结果`, web1 §5.2 Review phase)

private struct LogMealReviewCard: View {
    let model: LogMealModel
    let onOpenPicker: @MainActor () -> Void
    let onSaveItem: @MainActor (UUID) -> Void

    var body: some View {
        Card {
            CardHeader("审核解析结果", hint: "可改名称、克数和每项营养数值，删除多余项；确认后才合并")
            if model.items.isEmpty {
                EmptyState("没有食物，重新分析或从食物库添加")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in
                        ItemEditorView(
                            item: item,
                            edit: { transform in model.updateItem(id: item.id, transform) },
                            onRemove: { model.removeItem(id: item.id) },
                            onSave: { onSaveItem(item.id) }
                        )
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.items.map(\.id))
                if let preview = model.preview {
                    ImpactPreviewCard(preview: preview)
                }
                Rectangle().fill(Theme.hair).frame(height: 1)
                footer
            }
        }
    }

    private var footer: some View {
        let t = model.totals
        return VStack(alignment: .leading, spacing: 12) {
            LogMealMacroLine([
                .init("合计 ", fmt(t.v("energy_kcal")), " kcal"),
                .init("蛋白 ", fmt(t.v("protein_g"), 1), "g"),
                .init("钠 ", fmt(t.v("sodium_mg")), "mg"),
                .init("添加糖 ", fmt(t.v("added_sugars_g"), 1), "g"),
                .init("饱和脂肪 ", fmt(t.v("sat_fat_g"), 1), "g"),
            ], fontSize: 14)
            FlowLayout(spacing: 10, alignment: .trailing) {
                Button(action: onOpenPicker) {
                    Image(systemName: "plus")
                    Text("添加")
                }
                .buttonStyle(.nl())
                Button {
                    Task { await model.save() }
                } label: {
                    if model.isSaving {
                        Spinner(track: Theme.accentInk.opacity(0.35), head: Theme.accentInk)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    Text(model.saveTitle)
                }
                .buttonStyle(.nl(.primary, size: .lg))
                .disabled(model.isSaving)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Resume banner (`继续等待上次的 AI 分析`) and edit-load error

private struct LogMealResumeBanner: View {
    let job: PendingJob
    let onResume: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onResume) {
                    Image(systemName: "sparkles")
                    Text("继续等待上次的 AI 分析")
                }
                .buttonStyle(.nl(.primary, size: .sm))
                if let text = job.context["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    Text(verbatim: text)
                        .font(Theme.Font.small)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("关闭"))
        }
        .nlBanner(.accent)
    }
}

private struct LogMealErrorBanner: View {
    let message: String
    let onRetry: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .accessibilityHidden(true)
            Text(verbatim: message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试", action: onRetry)
                .buttonStyle(.nl(.plain, size: .sm))
        }
        .nlBanner(.warn)
    }
}
