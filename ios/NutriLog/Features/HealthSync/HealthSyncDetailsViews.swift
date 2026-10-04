import SwiftUI
import UIKit

// MARK: - HealthSyncScreen parts (DESIGN §B.5 items 7–10): notices (server upgrade, legacy Shortcut, time zone),
// kept-manual dates, possible duplicates, the personal token (auth §3.13) and the Shortcut guide (web1 §7.2 Row 4).

/// Banners above the toggle: server needs upgrading, legacy Shortcut data, time-zone mismatch.
struct HealthSyncNotices: View {
    let sync: HealthSyncService
    /// `profile.timezone` (nil before onboarding).
    let profileTimeZone: String?

    var body: some View {
        if !sync.status.serverSupportsSync {
            bannerSection(HealthSyncText.serverNeedsUpgrade, icon: "server.rack", style: .warn)
        }
        if sync.snapshot.legacyShortcutDays > 0 {
            bannerSection(HealthSyncText.legacyShortcut, icon: "exclamationmark.triangle", style: .warn)
        }
        if let tz = timeZoneWarning {
            bannerSection(HealthSyncText.timeZoneWarning(tz), icon: "globe.asia.australia", style: .plain)
        }
    }

    /// The profile zone when it differs from the device's (or the server reported a mismatch).
    private var timeZoneWarning: String? {
        guard let id = profileTimeZone ?? HealthSyncSettings.cachedTimeZone, let tz = TimeZone(identifier: id) else { return nil }
        if sync.snapshot.timezoneMismatch || HealthSyncText.timeZonesDiffer(tz, .current) { return id }
        return nil
    }

    private func bannerSection(_ text: String, icon: String, style: Banner.Style) -> some View {
        Section {
            Banner(text, icon: icon, style: style)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }
}

/// Dates whose day totals the server kept because the user changed them, with `用苹果健康数据覆盖这些日期`.
struct HealthSyncKeptManualSection: View {
    let days: [HealthKeptManualDay]
    let today: String
    let isBusy: Bool
    let onOverwrite: @MainActor () -> Void

    var body: some View {
        Section {
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalDay.dateLabel(day.date, today: today))
                        .font(Theme.Font.body).foregroundStyle(Theme.ink)
                    Text(verbatim: HealthSyncText.fieldList(day.fields))
                        .font(Theme.Font.small).foregroundStyle(Theme.ink2)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                onOverwrite()
            } label: {
                Label(HealthSyncText.overwriteButton, systemImage: "arrow.down.doc")
            }
            .disabled(isBusy)
        } header: {
            Text("保留了你的手动修改")
        } footer: {
            Text("你在网页或 App 中改过这些日期的活动数据，同步时保留了你的数值，没有用“健康”App 的数据覆盖。")
        }
        .listRowBackground(Theme.surface)
    }
}

/// One `possible_duplicates` entry: the synced workout and the manual / AI row it may duplicate.
struct HealthSyncDuplicateRow: View {
    let item: HealthDuplicate
    let today: String
    let isDeleting: Bool
    let onDelete: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "figure.run").foregroundStyle(Theme.s2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(Theme.Font.body).foregroundStyle(Theme.ink)
                    Text("手动记录：\(item.manualDescription)").font(Theme.Font.small).foregroundStyle(Theme.ink2)
                }
            }
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    if isDeleting { Spinner(size: 14) }
                    Text("删除手动记录")
                }
                .buttonStyle(.nl(.danger, size: .sm))
                .disabled(isDeleting)
            }
        }
        .padding(.vertical, 2)
    }

    /// `9月30日 · 泳池游泳 45 分钟（苹果健康）`.
    private var title: String {
        var parts: [String] = []
        if LocalDay.isValid(item.date) { parts.append(LocalDay.dateLabel(item.date, today: today)) }
        var workout = item.workoutDescription.isEmpty ? "“健康”App 体能训练" : item.workoutDescription
        if item.durationMin > 0 { workout += " \(fmt(item.durationMin)) 分钟" }
        parts.append(workout + "（Apple 健康）")
        return parts.joined(separator: " · ")
    }
}

// MARK: - 个人 Token（快捷指令）(auth §3.13, web1 §7.2 Row 4)

/// Personal `nl_` token management, kept for users of the iPhone Shortcuts automation (`/health/ingest`).
struct HealthPersonalTokenScreen: View {
    @Environment(AppState.self) private var app
    @State private var token: String?
    @State private var isGenerating = false
    @State private var confirmRegenerate = false
    @State private var showGuide = false
    @State private var copied: CopyTarget?

    private enum CopyTarget: Equatable { case url, token }

    var body: some View {
        let hint = app.user?.api_token_hint
        List {
            Section {
                Text("网页无法直接读取 HealthKit。用“快捷指令 → 自动化”每晚定时读取当天的步数、活动能量、静息能量、体重，POST 到下面的地址即可。")
                    .font(Theme.Font.body).foregroundStyle(Theme.ink1)
                if app.healthSync.status.isEnabled {
                    Label {
                        Text("你已开启 App 内的 Apple 健康同步，不需要再用快捷指令；两者同时使用会重复写入同一天的数据。")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(Theme.Font.small).foregroundStyle(Theme.warningText)
                }
            } header: {
                Text("方式一：iPhone 快捷指令每天自动同步")
            }
            .listRowBackground(Theme.surface)

            Section {
                HStack(spacing: 10) {
                    Text(verbatim: ingestURL)
                        .font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.ink1)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    copyButton(.url, value: ingestURL)
                }
            } header: {
                Text("接口地址")
            }
            .listRowBackground(Theme.surface)

            Section {
                if let token {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("只显示这一次，请复制保存：")
                        HStack(spacing: 10) {
                            Text(verbatim: token)
                                .font(.system(size: 13.5, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            copyButton(.token, value: token)
                        }
                    }
                    .nlBanner(.accent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Button {
                    if hint == nil { generate() } else { confirmRegenerate = true }
                } label: {
                    HStack(spacing: 8) {
                        Text(hint == nil ? "生成个人 Token" : "重新生成 Token")
                        if isGenerating { Spinner() }
                    }
                }
                .disabled(isGenerating)
                .listRowBackground(Theme.surface)
                // Like the web: the hint is hidden while the new token is shown once.
                if let hint, token == nil {
                    Text(verbatim: "当前：\(hint)")
                        .font(Theme.Font.small).foregroundStyle(Theme.ink3).monospaced()
                        .listRowBackground(Theme.surface)
                }
            } header: {
                Text("个人 Token")
            }

            Section {
                Button("查看设置步骤") { showGuide = true }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .tint(Theme.accent)
        .navigationTitle("个人 Token（快捷指令）")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重新生成后旧 Token 立即失效，快捷指令需要更新。继续？", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("重新生成 Token", role: .destructive) { generate() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showGuide) {
            HealthShortcutGuideSheet(ingestURL: ingestURL)
        }
    }

    /// `{origin}/api/health/ingest` of the server this app talks to.
    private var ingestURL: String {
        var base = app.serverURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/api/health/ingest"
    }

    private func copyButton(_ target: CopyTarget, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = target
        } label: {
            Image(systemName: copied == target ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied == target ? Theme.goodText : Theme.ink2)
        }
        .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
        .accessibilityLabel(Text(copied == target ? "已复制" : "复制"))
    }

    private func generate() {
        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                token = try await app.api.regeneratePersonalToken()
                copied = nil
                await app.refreshMe()
            } catch {
                app.toasts.error(error)
            }
        }
    }
}

/// `iPhone 快捷指令设置步骤` (web1 §7.2 Row 4, verbatim).
struct HealthShortcutGuideSheet: View {
    let ingestURL: String

    var body: some View {
        SheetScaffold(title: "iPhone 快捷指令设置步骤") {
            VStack(alignment: .leading, spacing: 12) {
                step(1, Text("打开“快捷指令” App → 新建快捷指令。"))
                step(2, Text("添加“查找健康样本”：类型选**步数**，开始日期“今天”，分组“按天”，计算“总和”。再分别为**活动能量**、**静息能量**、**体重**（取最新 1 条）各添加一次。"))
                step(3, Text("添加“字典”，键为 `steps`、`active_kcal`、`resting_kcal`、`weight_kg`（可选 `distance_km`、`exercise_min`、`date`），值选上一步的结果。"))
                step(4, Text("添加“获取 URL 内容”：URL 填 \(Text(verbatim: ingestURL).font(.system(size: 13, design: .monospaced)))，方法 POST，请求体 JSON 选择上面的字典；头部添加 `Authorization` = `Bearer 你的Token`。"))
                step(5, Text("在“自动化”里设定每天 23:30 运行（关闭“运行前询问”）。"))
            }
            .font(Theme.Font.body)
            .foregroundStyle(Theme.ink1)
            VStack(alignment: .leading, spacing: 8) {
                Text("请求体示例：").font(Theme.Font.small).foregroundStyle(Theme.ink3)
                Text(verbatim: #"{"steps": 8532, "active_kcal": 412, "resting_kcal": 1620, "distance_km": 6.1, "exercise_min": 35, "weight_kg": 68.2}"#)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink1)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("数值带千分位或单位（如 “8,532”、“412 kcal”）也能识别；不传 date 时按你的时区记为今天。")
                    .font(Theme.Font.small).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func step(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(n).").monospacedDigit().foregroundStyle(Theme.ink3)
            text.fixedSize(horizontal: false, vertical: true)
        }
    }
}
