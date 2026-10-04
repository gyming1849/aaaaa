import SwiftUI
import Observation

// MARK: - Navigation model (DESIGN §B.2)

/// Standards library tabs (web `?tab=`; rep §9, web2 §5.10).
enum StandardsTab: String, CaseIterable, Hashable, Sendable {
    case mine, dri, hazards, hei, met, rules, sources
    var title: String {
        switch self { case .mine: "我的个性化目标"; case .dri: "DRI 总表"; case .hazards: "致癌物与风险物"; case .hei: "HEI-2020"; case .met: "运动 MET"; case .rules: "评分规则"; case .sources: "资料来源" }
    }
}

/// 更多 → 设置 sub-screens (WP1), reachable as `Route.settings(_:)` so MoreScreen and debug deep links can push them.
enum SettingsPage: String, CaseIterable, Hashable, Sendable {
    case profile, appearance, password, devices, server, blocked, deleteAccount
    var title: String {
        switch self { case .profile: "个人档案"; case .appearance: "外观"; case .password: "修改密码"; case .devices: "登录设备"; case .server: "服务器"; case .blocked: "已屏蔽的成员"; case .deleteAccount: "删除账号" }
    }
}

/// Cross-feature destinations pushed onto a tab's `NavigationStack` (rendered by `RouteDestinationView`).
enum Route: Hashable, Sendable {
    case memberDay(username: String)
    case memberTrends(username: String)
    case reports
    case community
    case foods
    case standards(StandardsTab)
    case healthSync
    case shareSettings
    case settings(SettingsPage)
}

enum RecognizerMode: String, Sendable { case manual, ai }

/// Presents the Log Meal sheet. `date == nil` means today; `editMealId` opens an existing meal.
struct LogMealRequest: Identifiable, Hashable, Sendable { let id = UUID(); let date: String?; let editMealId: Int? }

@MainActor @Observable final class AppRouter {
    enum Tab: Hashable, Sendable { case today, trends, log, body, more }
    var selectedTab: Tab = .today
    var todayPath = NavigationPath()
    var trendsPath = NavigationPath()
    var bodyPath = NavigationPath()
    var morePath = NavigationPath()
    var logMeal: LogMealRequest?
    var todayFocusDate: String?
    var bodyFocusDate: String?

    func openLogMeal(date: String? = nil, editMealId: Int? = nil) { logMeal = LogMealRequest(date: date, editMealId: editMealId) }

    /// Appends to the selected tab's path; `.log` (never really selected) falls back to 更多.
    func push(_ route: Route) {
        switch selectedTab {
        case .today: todayPath.append(route)
        case .trends: trendsPath.append(route)
        case .body: bodyPath.append(route)
        case .more: morePath.append(route)
        case .log:
            selectedTab = .more
            morePath.append(route)
        }
    }

    func showToday(date: String?) { selectedTab = .today; todayFocusDate = date }
    func showBody(date: String?) { selectedTab = .body; bodyFocusDate = date }

    /// Pops a tab (default: the selected one) back to its root screen.
    func popToRoot(_ tab: Tab? = nil) {
        switch tab ?? selectedTab {
        case .today: todayPath = NavigationPath()
        case .trends: trendsPath = NavigationPath()
        case .body: bodyPath = NavigationPath()
        case .more: morePath = NavigationPath()
        case .log: break
        }
    }

    /// Back to a fresh 今日 tab with no sheet (logout, server change).
    func reset() {
        selectedTab = .today
        todayPath = NavigationPath(); trendsPath = NavigationPath(); bodyPath = NavigationPath(); morePath = NavigationPath()
        logMeal = nil
        todayFocusDate = nil
        bodyFocusDate = nil
    }
}
