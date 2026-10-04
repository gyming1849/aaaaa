import Foundation

// MARK: - Text and timestamp helpers for HealthKit sync (Foundation only; covered by the logic tests)

enum HealthSyncText {
    // Status strings (DESIGN §B.5)
    static let serverNeedsUpgrade = "服务器需要升级后才能同步“健康”App 数据"
    static let deviceLocked = "设备锁定时无法读取健康数据，解锁后会自动同步"
    static let unavailable = "此设备不支持“健康”App"
    static let legacyShortcut = "检测到 iPhone 快捷指令同步的数据。开启 App 同步后，请关闭快捷指令自动化，避免重复。"
    static let permissionHint = "可在“设置 → 健康 → 数据访问与设备 → 食迹”中修改权限"
    static let overwriteButton = "用“健康”App 数据覆盖这些日期"
    /// Apple's name for the Health app in Simplified Chinese UI (never translate "Apple" as 苹果).
    static let appName = "“健康”App"
    /// Where synced data goes, including the third-party AI provider (Info.plist `NSHealthShareUsageDescription` agrees).
    static let uploadDisclosure = "开启后，食迹会在后台读取“健康”App 中的数据，上传到你登录的食迹服务器，用于计算每日能量消耗与健康评分；当你使用 AI 识别或 AI 周报/月报点评时，服务器会把相关数值（如体重、睡眠、血压、能量消耗）发送给第三方 AI 服务商 Anthropic 处理。"

    /// `当前设备时区与档案时区不同，按档案时区 {tz} 统计每天的数据`.
    static func timeZoneWarning(_ tz: String) -> String { "当前设备时区与档案时区不同，按档案时区 \(tz) 统计每天的数据" }

    /// `同步了 30 天活动、12 条身体数据、3 次运动` (+ `，删除 2 条` when HealthKit deletions were propagated).
    static func summary(days: Int, body: Int, workouts: Int, deleted: Int) -> String {
        var s = "同步了 \(days) 天活动、\(body) 条身体数据、\(workouts) 次运动"
        if deleted > 0 { s += "，删除 \(deleted) 条" }
        return s
    }

    /// `已同步到服务器：90 天活动、120 条身体数据、80 次运动`.
    static func serverCounts(days: Int, body: Int, workouts: Int) -> String {
        "已同步到服务器：\(days) 天活动、\(body) 条身体数据、\(workouts) 次运动"
    }

    /// ISO-8601 with the zone offset of `timeZone`, e.g. `2026-10-02T18:05:00+08:00` (UTC → `+00:00`).
    static func isoTimestamp(_ date: Date, in timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let abs = Swift.abs(offset)
        let year = String(c.year ?? 1970)
        return String(repeating: "0", count: max(0, 4 - year.count)) + year
            + "-" + pad2(c.month ?? 1) + "-" + pad2(c.day ?? 1)
            + "T" + pad2(c.hour ?? 0) + ":" + pad2(c.minute ?? 0) + ":" + pad2(c.second ?? 0)
            + sign + pad2(abs / 3600) + ":" + pad2((abs % 3600) / 60)
    }

    /// `今天 14:32` / `昨天 08:01` / `10月2日 14:32` / `2025年12月31日 23:10`, in `timeZone`.
    static func lastSyncLabel(_ date: Date, now: Date, in timeZone: TimeZone) -> String {
        let day = LocalDay.key(for: date, in: timeZone)
        let today = LocalDay.key(for: now, in: timeZone)
        let time = LocalDay.hhmm(date, in: timeZone)
        switch LocalDay.diffDays(day, today) {
        case 0: return "今天 \(time)"
        case 1: return "昨天 \(time)"
        default:
            guard let p = LocalDay.parts(day), let t = LocalDay.parts(today) else { return "\(day) \(time)" }
            return p.year == t.year ? "\(p.month)月\(p.day)日 \(time)" : "\(p.year)年\(p.month)月\(p.day)日 \(time)"
        }
    }

    /// `10月1日` (`M月D日`, no padding).
    static func monthDay(_ date: String) -> String {
        guard let p = LocalDay.parts(date) else { return date }
        return "\(p.month)月\(p.day)日"
    }

    /// Kept-manual fields as Chinese labels, e.g. `睡眠、步数`.
    static func fieldList(_ keys: [String]) -> String { keys.map(HealthDayField.zh(forKey:)).joined(separator: "、") }

    /// At most `max` characters (server column limits).
    static func truncate(_ s: String?, max: Int) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(max))
    }

    /// True when the two zones currently have different UTC offsets (the profile zone decides the day keys).
    static func timeZonesDiffer(_ a: TimeZone, _ b: TimeZone, at date: Date = Date()) -> Bool {
        a.secondsFromGMT(for: date) != b.secondsFromGMT(for: date)
    }

    /// True when the offset between `timeZone` and the device zone is the same at every profile midnight of
    /// `start … end + 1` (then device-calendar day steps from a profile midnight land on profile midnights; see
    /// `HealthQueries.dailySums`).
    static func zonesStayAligned(start: String, end: String, timeZone: TimeZone, device: TimeZone) -> Bool {
        let skew = { (d: Date) in timeZone.secondsFromGMT(for: d) - device.secondsFromGMT(for: d) }
        guard let first = LocalDay.date(fromKey: start, in: timeZone) else { return false }
        let skew0 = skew(first)
        return LocalDay.range(start, LocalDay.addDays(end, 1)).allSatisfy { key in
            LocalDay.date(fromKey: key, in: timeZone).map { skew($0) == skew0 } ?? false
        }
    }

    private static func pad2(_ v: Int) -> String { v < 10 ? "0\(v)" : String(v) }
}
