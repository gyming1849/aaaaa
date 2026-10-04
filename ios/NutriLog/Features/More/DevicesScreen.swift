import SwiftUI

// MARK: - 登录设备 (iOS only; auth §3.6–§3.7, §4.7, DESIGN §C.7, §D row 48)
// `GET /auth/sessions` (ordered by last use) with swipe-to-remove (`DELETE /auth/sessions/{id}`, confirmed first).
// 本机 = the row with `current == true`; on servers without that field, the newest `app` row with this device's name.
// Removing 本机 signs out. Expired rows are greyed. Timestamps are UTC on the wire and shown in local time.

struct DevicesScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = DevicesModel()
    @State private var pendingRemoval: SessionRow?
    @State private var confirmRemoveOthers = false

    init() {}

    var body: some View {
        List {
            if let error = model.error, model.sessions == nil {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Banner(error, icon: "exclamationmark.triangle", style: .warn)
                        Button("重试") { Task { await model.load(app: app) } }
                            .buttonStyle(.nl(.plain, size: .sm))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            if let sessions = model.sessions {
                if sessions.isEmpty {
                    Section {
                        EmptyState("没有登录记录", icon: "iphone.slash")
                            .listRowBackground(Theme.surface)
                    }
                } else {
                    Section {
                        ForEach(sessions) { row in
                            DevicesRow(row: row, isCurrent: model.isCurrent(row))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingRemoval = row
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingRemoval = row
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }
                                }
                                .listRowBackground(Theme.surface)
                        }
                    } header: {
                        Text(verbatim: "共 \(sessions.count) 个登录")
                    } footer: {
                        Text("向左滑动可移除登录。移除后该设备需要重新登录；修改密码不会让已登录的设备退出。")
                    }

                    if model.otherIds.count > 0 && model.currentId != nil {
                        Section {
                            Button(role: .destructive) {
                                confirmRemoveOthers = true
                            } label: {
                                HStack {
                                    Text("移除其他所有设备")
                                    Spacer()
                                    if model.isWorking { Spinner() }
                                }
                                .foregroundStyle(Theme.criticalText)
                            }
                            .disabled(model.isWorking)
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
            } else if model.error == nil {
                Section {
                    LoadingView()
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("登录设备")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(app: app) }
        .task { await model.load(app: app) }
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible, presenting: pendingRemoval) { row in
            Button(model.isCurrent(row) ? "移除并退出登录" : "移除", role: .destructive) {
                Task { await model.remove(row, app: app) }
            }
            Button("取消", role: .cancel) {}
        } message: { row in
            if model.isCurrent(row) {
                Text("这是本机正在使用的登录，移除后会退出登录。")
            } else {
                Text(verbatim: "“\(DevicesRow.title(row))”将需要重新登录。")
            }
        }
        .confirmationDialog("移除其他所有设备？", isPresented: $confirmRemoveOthers, titleVisibility: .visible) {
            Button("移除其他所有设备", role: .destructive) {
                Task { await model.removeOthers(app: app) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("除本机外的所有登录都会失效，需要重新登录。")
        }
    }

    private var removalTitle: String { "移除这个登录？" }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
}

/// Session list state.
@MainActor @Observable final class DevicesModel {
    private(set) var sessions: [SessionRow]?
    private(set) var error: String?
    private(set) var isWorking = false

    init() {}

    /// The id of this device's session: `current == true` (§C.7), or on old servers (no `current` key at all) the newest
    /// `app` row whose `device_name` is the one this app sends (auth §3.6 heuristic; rows are ordered by last use).
    var currentId: Int? {
        guard let sessions else { return nil }
        if sessions.contains(where: { $0.current != nil }) {
            return sessions.first { $0.current == true }?.id
        }
        let name = DeviceInfo.deviceName
        return sessions.first { $0.kind == "app" && $0.device_name == name }?.id
    }

    func isCurrent(_ row: SessionRow) -> Bool { row.id == currentId }

    var otherIds: [Int] { (sessions ?? []).map(\.id).filter { $0 != currentId } }

    func load(app: AppState) async {
        do {
            sessions = try await app.api.sessions()
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = APIError.from(error).message
        }
    }

    /// Ids are SQLite rowids and may change after a VACUUM, so the list is refetched after every removal (auth §3.6).
    func remove(_ row: SessionRow, app: AppState) async {
        guard !isWorking else { return }
        let wasCurrent = isCurrent(row)
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.api.deleteSession(id: row.id)
        } catch {
            app.toasts.error(error)
            return
        }
        if wasCurrent {
            await app.logout()
            return
        }
        app.toasts.show("已移除")
        await load(app: app)
    }

    func removeOthers(app: AppState) async {
        guard !isWorking, currentId != nil else { return }
        isWorking = true
        defer { isWorking = false }
        await load(app: app)
        let ids = otherIds
        var failure: Error?
        for id in ids {
            do { try await app.api.deleteSession(id: id) } catch { failure = error; break }
        }
        if let failure { app.toasts.error(failure) } else { app.toasts.show("已移除") }
        await load(app: app)
    }
}

/// One session: kind icon, device name, `本机` / `已过期` chips, last use (or sign-in time for web sessions) and expiry.
private struct DevicesRow: View {
    let row: SessionRow
    let isCurrent: Bool

    static func title(_ row: SessionRow) -> String {
        if let name = row.device_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return row.kind == "web" ? "网页浏览器" : "App"
    }

    private var expiresAt: Date? { Timestamps.iso(row.expires_at) }
    private var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.kind == "app" ? "iphone" : "globe")
                .font(.system(size: 18))
                .foregroundStyle(isCurrent ? Theme.accent : Theme.ink2)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: Self.title(row))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    if isCurrent { Chip("本机", style: .accent) }
                    if isExpired { Chip("已过期") }
                }
                Text(verbatim: usageLine)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                Text(verbatim: expiryLine)
                    .font(Theme.Font.foot)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(isExpired ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String { row.kind == "app" ? "App" : "网页" }

    /// App rows: last authenticated request. Web rows: sign-in time (their `last_used_at` is never updated).
    private var usageLine: String {
        if row.kind == "app" {
            return "\(kindLabel) · 最近使用 \(DevicesTime.local(Timestamps.sqlite(row.last_used_at)))"
        }
        return "\(kindLabel) · 登录于 \(DevicesTime.local(Timestamps.sqlite(row.created_at ?? row.last_used_at)))"
    }

    private var expiryLine: String {
        guard let expiresAt else { return "有效期至 —" }
        let text = DevicesTime.local(expiresAt, withTime: false)
        return isExpired ? "已于 \(text) 过期" : "有效期至 \(text)"
    }
}

/// Server timestamps (UTC) → device-local `YYYY-MM-DD HH:MM`.
enum DevicesTime {
    static func local(_ date: Date?, withTime: Bool = true) -> String {
        guard let date else { return "—" }
        let tz = TimeZone.current
        let day = LocalDay.key(for: date, in: tz)
        return withTime ? "\(day) \(LocalDay.hhmm(date, in: tz))" : day
    }
}
