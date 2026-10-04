import SwiftUI
import UIKit

// MARK: - Toasts (web2 §1.8, web1 §3.3): a top-centre stack of pills.
// Info: ink background, surface text, 2.6 s. Error: critical background, white text, 5 s. Radius 10, 14 pt, padding 10×16.

@MainActor @Observable final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// The most recent visible toast.
    private(set) var current: Toast?
    /// Every visible toast, oldest first (the web shows a stack).
    private(set) var stack: [Toast] = []
    /// Overlay hosts in presentation order; only the newest one renders, so a toast raised while a sheet is up
    /// appears on the sheet (whose `SheetScaffold` installs its own overlay) and not twice.
    private(set) var hosts: [UUID] = []

    static let infoDuration: Duration = .milliseconds(2600)
    static let errorDuration: Duration = .seconds(5)
    private static let maxVisible = 4

    init() {}

    func show(_ text: String) { push(Toast(text: text, isError: false), for: Self.infoDuration) }

    func error(_ text: String) { push(Toast(text: text, isError: true), for: Self.errorDuration) }

    /// Shows `APIError.message`. A cancelled task shows the info toast `已取消` instead of an error.
    func error(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            show("已取消")
            return
        }
        self.error(APIError.from(error).message)
    }

    func dismiss(id: UUID) {
        stack.removeAll { $0.id == id }
        current = stack.last
    }

    func dismissAll() {
        stack.removeAll()
        current = nil
    }

    private func push(_ toast: Toast, for duration: Duration) {
        let text = toast.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A repeated identical message replaces the older copy instead of stacking.
        stack.removeAll { $0.text == toast.text && $0.isError == toast.isError }
        stack.append(toast)
        if stack.count > Self.maxVisible { stack.removeFirst(stack.count - Self.maxVisible) }
        current = toast
        UIAccessibility.post(notification: .announcement, argument: toast.text)
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.dismiss(id: id)
        }
    }

    // Overlay host bookkeeping (used by `toastOverlay`).
    fileprivate func register(host: UUID) {
        hosts.removeAll { $0 == host }
        hosts.append(host)
    }

    fileprivate func unregister(host: UUID) {
        hosts.removeAll { $0 == host }
    }
}

private struct ToastOverlayModifier: ViewModifier {
    let center: ToastCenter
    @State private var host = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ToastStackView(center: center, isActive: center.hosts.last == host || center.hosts.isEmpty)
            }
            .environment(center)
            .onAppear { center.register(host: host) }
            .onDisappear { center.unregister(host: host) }
    }
}

private struct ToastStackView: View {
    let center: ToastCenter
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            if isActive {
                ForEach(center.stack) { toast in
                    ToastPill(toast: toast)
                        .onTapGesture { center.dismiss(id: toast.id) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.25), value: center.stack)
    }
}

private struct ToastPill: View {
    let toast: ToastCenter.Toast

    var body: some View {
        Text(toast.text)
            .font(Theme.Font.toast)
            .foregroundStyle(toast.isError ? Color.white : Theme.surface)
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(toast.isError ? Theme.critical : Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Theme.shadowLarge, radius: 24, x: 0, y: 12)
            .frame(maxWidth: 520)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// Installs the toast stack at the top centre and publishes `center` in the environment
    /// (so `SheetScaffold` can show toasts above sheets). Apply once at the root (RootView) and on full-screen sheets.
    func toastOverlay(_ center: ToastCenter) -> some View { modifier(ToastOverlayModifier(center: center)) }
}

// MARK: - Preview

private struct ToastPreview: View {
    @State private var center = ToastCenter()
    var body: some View {
        VStack(spacing: 12) {
            Button("已保存，评分已更新") { center.show("已保存，评分已更新") }.buttonStyle(.nl(.primary))
            Button("请描述吃了什么，或上传照片") { center.error("请描述吃了什么，或上传照片") }.buttonStyle(.nl(.danger))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
        .toastOverlay(center)
        .onAppear {
            center.show("已删除")
            center.error("网络连接失败，请检查网络或服务器地址")
        }
    }
}

#Preview("Toast") { ToastPreview() }

#Preview("Toast · 深色") { ToastPreview().preferredColorScheme(.dark) }
