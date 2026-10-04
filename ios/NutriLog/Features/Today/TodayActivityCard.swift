import SwiftUI

// MARK: - E2. ActivityCard `活动与身体` (web1 §4.3 E2; rep §2.4–§2.6, §17.2)
// Own view: `填写` / `AI 识别截图` open the ActivityRecognizer sheet (WP4). Four stats, the day's exercises and body rows,
// or — when the day has none of them — the hint, whose last sentence points to Apple Health sync on iOS.

struct TodayActivityCard: View {
    let day: DayResponse
    let readOnly: Bool
    /// Apple Health sync is already on: the "turn on sync" sentence is left out of the empty hint.
    let healthSyncEnabled: Bool
    let onRecognize: @MainActor (RecognizerMode) -> Void
    /// The `身体与运动` link in the empty hint.
    let onShowBody: @MainActor () -> Void

    /// Marker URL for the inline `身体与运动` link (handled locally, never opened).
    private static let bodyLink = URL(string: "nutrilog-today://body")!

    var body: some View {
        let a = day.activity
        Card {
            if readOnly {
                CardHeader("活动与身体", icon: "figure.walk")
            } else {
                TodayCardHeader("活动与身体", icon: "figure.walk") {
                    HStack(spacing: 6) {
                        Button { onRecognize(.manual) } label: { Label("填写", systemImage: "pencil") }
                            .buttonStyle(.nl(.plain, size: .sm))
                        Button { onRecognize(.ai) } label: { Label("AI 识别截图", systemImage: "sparkles") }
                            .buttonStyle(.nl(.primary, size: .sm))
                    }
                }
            }
            EqualHeightGridLayout(columns: 2, spacing: Theme.Metrics.tileGap) {
                TodayStat(label: "步数", value: a?.steps.map { fmt($0) } ?? "—")
                TodayStat(label: "活动能量", value: a?.active_kcal.map { fmt($0) } ?? "—", unit: "kcal")
                TodayStat(label: "运动消耗", value: fmt(day.score.energy.exerciseKcal), unit: "kcal")
                TodayStat(label: "睡眠", value: a?.sleep_hours.map { fmt($0, 1) } ?? "—", unit: "小时")
            }
            if !day.exercises.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(day.exercises.enumerated()), id: \.element.id) { i, e in
                        exerciseRow(e)
                        if i < day.exercises.count - 1 { TodayListDivider() }
                    }
                }
                .padding(.top, -4)
            }
            if !day.body.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(day.body.enumerated()), id: \.element.id) { i, b in
                        bodyRow(b)
                        if i < day.body.count - 1 { TodayListDivider() }
                    }
                }
                .padding(.top, -8)
            }
            if a == nil && day.exercises.isEmpty && day.body.isEmpty {
                Text(hint)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .tint(Theme.accentText)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url == Self.bodyLink else { return .systemAction }
                        onShowBody()
                        return .handled
                    })
            }
        }
    }

    /// The empty hint; in the own view the web's Shortcuts sentence is replaced by Apple Health sync wording.
    private var hint: AttributedString {
        var s = AttributedString("点“填写”直接录入今天的步数、活动能量、睡眠、体重；或点“AI 识别截图”上传“健康”App / 手表截图，或者说一句“今天走了 8000 步，游泳 5km”。")
        if !readOnly && !healthSyncEnabled {
            s += AttributedString(" 也可以在 ")
            var link = AttributedString("身体与运动")
            link.link = Self.bodyLink
            link.foregroundColor = Theme.accentText
            s += link
            s += AttributedString(" 里开启 Apple 健康同步，自动同步步数、睡眠和体重。")
        }
        return s
    }

    /// Web: flame (series-2) · `{description} {min} 分钟 · MET {met}` … `{kcal} kcal`（已含在设备数据中）.
    private func exerciseRow(_ e: Exercise) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "flame")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.s2)
                .frame(width: 18)
                .accessibilityHidden(true)
            (Text(verbatim: e.description).foregroundStyle(Theme.ink1)
                + Text(verbatim: " ")
                + Text(verbatim: "\(fmt(e.duration_min)) 分钟 · MET \(DSFormat.js(e.met))").font(Theme.Font.small).foregroundStyle(Theme.ink3))
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: "\(fmt(e.kcal)) kcal")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink1)
                if e.inDevice {
                    Text("（已含在设备数据中）")
                        .font(Theme.Font.foot)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .monospacedDigit()
            .fixedSize()
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// Web: scale (series-1) · `{time} 称重` … `{kg} kg · 体脂 {x}% · 血压 {s}/{d}`.
    private func bodyRow(_ b: BodyMetric) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "scalemass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.s1)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: "\(b.time) 称重")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink1)
                .monospacedDigit()
                .fixedSize()
            Spacer(minLength: 8)
            Text(verbatim: TodayText.bodyRow(b))
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink1)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
