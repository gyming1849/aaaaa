import SwiftUI

// MARK: - Main tabs (DESIGN §B.2)

/// Pushed screen for a `Route` (every tab's `NavigationStack` registers it via `.nlRouteDestinations()`).
struct RouteDestinationView: View {
    let route: Route
    var body: some View {
        switch route {
        case .memberDay(let u): TodayScreen(member: u)
        case .memberTrends(let u): TrendsScreen(member: u)
        case .reports: ReportsScreen()
        case .community: CommunityScreen()
        case .foods: FoodsScreen()
        case .standards(let t): StandardsScreen(initialTab: t)
        case .healthSync: HealthSyncScreen()
        case .shareSettings: ShareSettingsScreen()
        case .settings(let page): SettingsPageDestination(page: page)
        }
    }
}

/// 更多 → 设置 pages (WP1 screens).
private struct SettingsPageDestination: View {
    let page: SettingsPage
    var body: some View {
        switch page {
        case .profile: ProfileSettingsScreen()
        case .appearance: AppearanceScreen()
        case .password: PasswordScreen()
        case .devices: DevicesScreen()
        case .server: ServerSettingsScreen()
        case .blocked: BlockedMembersScreen()
        case .deleteAccount: DeleteAccountScreen()
        }
    }
}

extension View { func nlRouteDestinations() -> some View { navigationDestination(for: Route.self) { RouteDestinationView(route: $0) } } }

/// 今日 / 趋势 / [记一餐] / 身体 / 更多. The centre item is an action: selecting it opens the Log Meal sheet and keeps
/// the previous tab selected. Re-selecting the current tab pops it to its root.
struct MainTabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var router = app.router
        TabView(selection: Binding(get: { router.selectedTab }, set: { t in
            if t == .log {
                router.openLogMeal()
            } else {
                if t == router.selectedTab { router.popToRoot(t) }
                router.selectedTab = t
            }
        })) {
            NavigationStack(path: $router.todayPath) { TodayScreen().nlRouteDestinations() }
                .tabItem { Label("今日", systemImage: "house") }.tag(AppRouter.Tab.today)
            NavigationStack(path: $router.trendsPath) { TrendsScreen().nlRouteDestinations() }
                .tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }.tag(AppRouter.Tab.trends)
            Color.clear.tabItem { Label("记一餐", systemImage: "plus.circle.fill") }.tag(AppRouter.Tab.log)
            NavigationStack(path: $router.bodyPath) { BodyScreen().nlRouteDestinations() }
                .tabItem { Label("身体", systemImage: "scalemass") }.tag(AppRouter.Tab.body)
            NavigationStack(path: $router.morePath) { MoreScreen().nlRouteDestinations() }
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }.tag(AppRouter.Tab.more)
        }
        // A large sheet covers RootView's toast overlay, so the sheet installs its own (only the newest host renders).
        .sheet(item: $router.logMeal) { req in LogMealScreen(request: req).toastOverlay(app.toasts) }
    }
}
