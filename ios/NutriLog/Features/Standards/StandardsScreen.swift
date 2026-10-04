import SwiftUI

// MARK: - 标准库 (web2 §5.10, rep §9, §17.7)
// Pushed from 更多 → 标准库 (`.standards(.mine)`) and from Today's `评分依据` (`.standards(.rules)`), so it starts on
// `initialTab` (the web's `?tab=` deep link). Header: title `标准库` + subtitle; a scrollable tab bar of the 7 tabs that
// stays pinned under the navigation bar; the selected tab's content below. Pull to refresh reloads the visible tab.

struct StandardsScreen: View {
    let initialTab: StandardsTab

    @Environment(AppState.self) private var app
    @State private var model = StandardsModel()
    @State private var tab: StandardsTab

    init(initialTab: StandardsTab = .mine) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    static let subtitle = "本站离线评分使用的全部标准：美国 NASEM DRI、膳食指南 DGA 2020–2025 / 2025–2030、HEI-2020、FDA、AHA、IARC、WCRF、体力活动指南"
    private static let topAnchor = "standards-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Text(Self.subtitle)
                        .font(Theme.Font.subtitle)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Metrics.pagePadding)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                        .id(Self.topAnchor)
                    Section {
                        content
                            .padding(.horizontal, Theme.Metrics.pagePadding)
                            .padding(.top, 18)
                            .padding(.bottom, 32)
                    } header: {
                        StandardsTabBar(selection: $tab)
                            .background(Theme.page)
                    }
                }
            }
            .onChange(of: tab) { _, _ in
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
        .background(Theme.page)
        .navigationTitle("标准库")
        .refreshable { await model.refresh(tab, app: app) }
        .task(id: StandardsLoadKey(tab: tab, dataVersion: app.dataVersion)) {
            await model.load(tab, app: app)
        }
    }

    // MARK: Tab content and states

    @ViewBuilder
    private var content: some View {
        let meta = model.meta(app)
        switch tab {
        case .mine:
            if let targets = model.targets, let meta {
                StandardsMineTab(targets: targets, meta: meta)
            } else if let message = model.targetsError ?? (meta == nil ? model.metaError : nil) {
                errorBanner(message)
            } else {
                LoadingView()
            }
        case .dri:
            if let dri = model.dri, let meta {
                StandardsDriTab(dri: dri, meta: meta)
            } else if let message = model.driError ?? (meta == nil ? model.metaError : nil) {
                errorBanner(message)
            } else {
                LoadingView()
            }
        case .hazards, .hei, .met, .rules, .sources:
            if let meta {
                metaTab(meta)
            } else if let message = model.metaError {
                errorBanner(message)
            } else {
                LoadingView()
            }
        }
    }

    @ViewBuilder
    private func metaTab(_ meta: Meta) -> some View {
        switch tab {
        case .hazards: StandardsHazardsTab(meta: meta)
        case .hei: StandardsHeiTab(meta: meta)
        case .met: StandardsMetTab(meta: meta)
        case .rules: StandardsRulesTab(meta: meta)
        case .sources: StandardsSourcesTab(meta: meta)
        case .mine, .dri: EmptyView()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        StandardsLoadErrorBanner(message: message) {
            let current = tab
            Task { await model.load(current, app: app) }
        }
    }
}
