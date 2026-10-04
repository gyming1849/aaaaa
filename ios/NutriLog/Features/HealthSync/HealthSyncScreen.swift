import SwiftUI

// MARK: - 苹果健康同步 (DESIGN §B.5 "HealthSyncScreen"; replaces the web "连接苹果健康" card, web1 §7.2 Row 4). Owner: WP9.
// Sections: availability and notices · the sync toggle · last sync + 立即同步 · backfill range and 降压药 ·
// kept-manual dates · possible duplicates · data read · 高级 (重新同步全部, 个人 Token, 断开并删除).

struct HealthSyncScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var isToggling = false
    @State private var isUnlinking = false
    @State private var confirmResync = false
    @State private var confirmUnlink = false
    @State private var confirmOverwrite = false
    @State private var pendingDuplicate: HealthDuplicate?
    @State private var deletingDuplicate: String?

    init() {}

    var body: some View {
        let sync = app.healthSync
        ScrollViewReader { proxy in
            List {
                if sync.status.isAvailable {
                    HealthSyncNotices(sync: sync, profileTimeZone: app.profile?.timezone)
                    toggleSection(sync)
                    if sync.status.isEnabled || sync.status.lastSyncAt != nil { statusSection(sync) }
                    settingsSection(sync)
                    if !sync.snapshot.keptManual.isEmpty {
                        HealthSyncKeptManualSection(days: sync.snapshot.keptManual, today: app.today,
                                                    isBusy: sync.status.isSyncing || !sync.status.isEnabled) {
                            confirmOverwrite = true
                        }
                    }
                    if !sync.snapshot.duplicates.isEmpty { duplicatesSection(sync) }
                    readSection.debugScrollAnchor("read")
                    advancedSection(sync).debugScrollAnchor("advanced")
                } else {
                    Section {
                        Banner(HealthSyncText.unavailable, icon: "exclamationmark.triangle", style: .warn)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } footer: {
                        Text("“健康”App 只在 iPhone 上可用。你仍可以在“身体”页手动填写或用 AI 识别健康截图。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .debugScrollTo(proxy, ready: true)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .tint(Theme.accent)
        .navigationTitle("Apple 健康同步")
        .task { await sync.refreshServerState() }
        .refreshable {
            await sync.refreshServerState()
            // Like 立即同步: start the sync without waiting for it (the status section shows its spinner and progress),
            // and don't queue a run on top of one in progress, e.g. the initial backfill.
            if sync.status.isEnabled, !sync.status.isSyncing { Task { await sync.syncNow(reason: .manual) } }
        }
        .confirmationDialog("重新同步全部？", isPresented: $confirmResync, titleVisibility: .visible) {
            Button("重新同步全部") { Task { await sync.resyncAll() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将重新读取并上传\(sync.backfillDays >= 365 ? "最近一年" : "最近 \(sync.backfillDays) 天")的全部“健康”App 数据。服务器按记录去重，不会产生重复数据。")
        }
        .confirmationDialog("断开并删除已同步的数据？", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("断开并删除", role: .destructive) { unlink(sync) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将关闭同步，并从服务器删除所有从“健康”App 同步的体重、体脂、腰围、血压、体能训练和每日活动数据（包括其他设备同步的）。你手动填写或修改过的数值会保留。此操作无法撤销。")
        }
        .confirmationDialog(HealthSyncText.overwriteButton + "？", isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button("覆盖", role: .destructive) { overwrite(sync) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些日期中你在网页或 App 里修改过的数值，将改为“健康”App 中的数据。")
        }
        .confirmationDialog(
            pendingDuplicate.map { "删除手动记录“\($0.manualDescription)”？" } ?? "",
            isPresented: Binding(get: { pendingDuplicate != nil }, set: { if !$0 { pendingDuplicate = nil } }),
            titleVisibility: .visible,
            presenting: pendingDuplicate
        ) { item in
            Button("删除手动记录", role: .destructive) { deleteDuplicate(item, sync) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("从“健康”App 同步的那条运动会保留。")
        }
    }

    // MARK: Sections

    private func toggleSection(_ sync: HealthSyncService) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { sync.status.isEnabled || isToggling },
                set: { on in
                    if on { enable(sync) } else { sync.disable() }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("同步“健康”App 数据").font(Theme.Font.body).foregroundStyle(Theme.ink)
                    Text("步数、能量、睡眠、身体数据和体能训练").font(Theme.Font.small).foregroundStyle(Theme.ink3)
                }
            }
            .disabled(isToggling || isUnlinking)
            .listRowBackground(Theme.surface)
        } footer: {
            Text(HealthSyncText.uploadDisclosure + "你在网页或 App 中手动修改的数值会被保留，不会被同步覆盖。")
        }
    }

    private func statusSection(_ sync: HealthSyncService) -> some View {
        let status = sync.status
        let snapshot = sync.snapshot
        return Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lastSyncLine(status.lastSyncAt))
                        .font(Theme.Font.body).foregroundStyle(Theme.ink)
                    if let summary = status.lastSummary {
                        Text(summary).font(Theme.Font.small).foregroundStyle(Theme.ink2).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                if status.isSyncing { Spinner().padding(.top, 2) }
            }
            .accessibilityElement(children: .combine)
            if status.isSyncing {
                Text(sync.progress ?? "正在同步…")
                    .font(Theme.Font.small).foregroundStyle(Theme.ink3).nlPulse()
            }
            if let error = status.lastError, error != HealthSyncText.serverNeedsUpgrade || status.serverSupportsSync {
                Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(Theme.Font.small).foregroundStyle(Theme.warningText)
            }
            if !snapshot.rejected.isEmpty {
                DisclosureGroup {
                    ForEach(snapshot.rejected, id: \.self) { message in
                        Text(verbatim: message).font(Theme.Font.small).foregroundStyle(Theme.ink2)
                    }
                } label: {
                    Text("\(snapshot.rejected.count) 条数据未被服务器接受").font(Theme.Font.small).foregroundStyle(Theme.ink2)
                }
            }
            if !snapshot.approximateSleepDates.isEmpty {
                Text("这些日期没有睡眠阶段数据，睡眠时长按卧床时间估算：\(snapshot.approximateSleepDates.prefix(7).map(HealthSyncText.monthDay).joined(separator: "、"))")
                    .font(Theme.Font.small).foregroundStyle(Theme.ink3)
            }
            if let counts = snapshot.serverCounts {
                Text(HealthSyncText.serverCounts(days: counts.days, body: counts.body, workouts: counts.workouts))
                    .font(Theme.Font.small).foregroundStyle(Theme.ink3).monospacedDigit()
            }
            Button {
                Task { await sync.syncNow(reason: .manual) }
            } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(status.isSyncing || !status.isEnabled)
        } header: {
            Text("同步状态")
        }
        .listRowBackground(Theme.surface)
    }

    private func settingsSection(_ sync: HealthSyncService) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("首次同步范围").font(Theme.Font.body).foregroundStyle(Theme.ink)
                Seg(HealthSyncSettings.backfillOptions.map { SegOption(value: $0, label: Self.rangeLabel($0)) },
                    selection: Binding(get: { sync.backfillDays }, set: { days in Task { await sync.setBackfillDays(days) } }))
            }
            .padding(.vertical, 4)
            Toggle(isOn: Binding(get: { sync.bpTreated }, set: { on in Task { await sync.setBPTreated(on) } })) {
                Text("正在服用降压药").font(Theme.Font.body).foregroundStyle(Theme.ink)
            }
        } header: {
            Text("同步设置")
        } footer: {
            Text("首次同步和“重新同步全部”会读取所选范围内的数据。“正在服用降压药”会标记在从“健康”App 同步的血压记录上。")
        }
        .listRowBackground(Theme.surface)
    }

    private func duplicatesSection(_ sync: HealthSyncService) -> some View {
        Section {
            ForEach(sync.snapshot.duplicates) { item in
                HealthSyncDuplicateRow(item: item, today: app.today, isDeleting: deletingDuplicate == item.id) {
                    pendingDuplicate = item
                }
                .swipeActions(edge: .trailing) {
                    Button("忽略") { sync.dismissDuplicate(item) }.tint(Theme.ink3)
                }
            }
        } header: {
            Text("可能重复的运动记录")
        } footer: {
            Text("这些“健康”App 体能训练与同一天的手动或 AI 记录类型相同、时长接近，可能是同一次运动。删除手动记录可避免重复计算消耗；左滑可忽略。")
        }
        .listRowBackground(Theme.surface)
    }

    private var readSection: some View {
        Section {
            ForEach(HealthTypes.readList, id: \.name) { item in
                Label {
                    Text(item.name).font(Theme.Font.body).foregroundStyle(Theme.ink1)
                } icon: {
                    Image(systemName: item.symbol).foregroundStyle(Theme.accent)
                }
            }
            Button {
                if let url = URL(string: "x-apple-health://") { openURL(url) }
            } label: {
                Label("打开“健康” App", systemImage: "heart.text.square")
            }
        } header: {
            Text("读取的数据")
        } footer: {
            Text("\(HealthSyncText.permissionHint)。iOS 不会告诉 App 哪些权限被拒绝；如果某项数据没有同步，请在那里检查。血糖、糖化血红蛋白和血脂不会同步，请在“身体”页手动填写。")
        }
        .listRowBackground(Theme.surface)
    }

    private func advancedSection(_ sync: HealthSyncService) -> some View {
        let canResync = sync.status.isEnabled && !sync.status.isSyncing
        return Section {
            Button {
                confirmResync = true
            } label: {
                // Explicit colours: a disabled List button otherwise renders in plain ink, which reads as enabled.
                Label("重新同步全部", systemImage: "arrow.clockwise")
                    .foregroundStyle(canResync ? Theme.accentText : Theme.ink3)
            }
            .disabled(!canResync)
            NavigationLink {
                HealthPersonalTokenScreen()
            } label: {
                Label("个人 Token（快捷指令）", systemImage: "key")
            }
            Button(role: .destructive) {
                confirmUnlink = true
            } label: {
                HStack {
                    Label("断开并删除已同步的数据", systemImage: "trash")
                        .foregroundStyle(Theme.criticalText)
                    if isUnlinking {
                        Spacer()
                        Spinner()
                    }
                }
            }
            .disabled(isUnlinking)
        } header: {
            Text("高级")
        } footer: {
            Text("断开会删除服务器上所有从“健康”App 同步的数据（不分设备），你手动填写的数据不受影响。")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Actions

    private func enable(_ sync: HealthSyncService) {
        isToggling = true
        Task {
            await sync.enable()
            isToggling = false
        }
    }

    private func unlink(_ sync: HealthSyncService) {
        isUnlinking = true
        Task {
            defer { isUnlinking = false }
            do {
                let d = try await sync.unlinkAndDeleteData()
                app.toasts.show("已断开 Apple 健康，删除了 \(d.body) 条身体数据、\(d.exercises) 次运动、\(d.days) 天活动数据")
            } catch {
                app.toasts.error(error)
            }
        }
    }

    private func overwrite(_ sync: HealthSyncService) {
        Task {
            await sync.overwriteKeptManual()
            if sync.status.lastError == nil { app.toasts.show("已用“健康”App 数据覆盖") }
        }
    }

    private func deleteDuplicate(_ item: HealthDuplicate, _ sync: HealthSyncService) {
        deletingDuplicate = item.id
        Task {
            defer { deletingDuplicate = nil }
            do {
                try await sync.deleteManualDuplicate(item)
                app.toasts.show("已删除")
            } catch {
                app.toasts.error(error)
            }
        }
    }

    // MARK: Text

    private func lastSyncLine(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        return "上次同步 " + HealthSyncText.lastSyncLabel(date, now: Date(), in: .current)
    }

    static func rangeLabel(_ days: Int) -> String { days >= 365 ? "一年" : "\(days) 天" }
}

#Preview("苹果健康同步") {
    NavigationStack { HealthSyncScreen() }
        .environment(AppState())
}
