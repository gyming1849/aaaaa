import SwiftUI

// MARK: - `-NLScrollTo <anchor>` (DEBUG launch argument, README "Debug launch arguments")
// Scrolls 今日 / 趋势 / 身体 / 周期报告 / 社区 / Apple 健康同步 / 个人档案 (and 建档) to a named card once its data has
// loaded, so simulator QA can screenshot cards below the fold (anchor names: README "Debug launch arguments"). Release builds compile both modifiers to no-ops (no `.id`, no task).

extension View {
    /// Names this card as a `-NLScrollTo` target.
    @ViewBuilder func debugScrollAnchor(_ name: String) -> some View {
        #if DEBUG
        id(name)
        #else
        self
        #endif
    }

    /// Scrolls `proxy` to the `-NLScrollTo` anchor the first time `ready` is true.
    @ViewBuilder func debugScrollTo(_ proxy: ScrollViewProxy, ready: Bool) -> some View {
        #if DEBUG
        modifier(DebugScrollToModifier(proxy: proxy, ready: ready))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugScrollToModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let ready: Bool
    @State private var done = false

    func body(content: Content) -> some View {
        content.task(id: ready) {
            guard ready, !done, let anchor = DebugLaunchOptions.current.scrollTo else { return }
            done = true
            try? await Task.sleep(for: .milliseconds(600))   // let charts and flow layouts settle first
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}
#endif
