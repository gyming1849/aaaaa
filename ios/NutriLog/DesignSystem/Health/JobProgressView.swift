import SwiftUI

// MARK: - JobProgressView (web1 §5.2 "Analyzing card"): spinner; semibold `排队中…` while the last polled status is
// `queued`, otherwise `title`; muted `{elapsed}s` (whole seconds since start, `Math.round`, refreshed every 0.5 s);
// below it a pulsing small muted hint chosen by the caller from the elapsed seconds.

struct JobProgressView: View {
    let title: String
    let phase: JobPhase?
    let startedAt: Date
    let hint: (Int) -> String

    init(title: String, phase: JobPhase?, startedAt: Date, hint: @escaping (Int) -> String) {
        self.title = title
        self.phase = phase
        self.startedAt = startedAt
        self.hint = hint
    }

    /// Whole seconds since `startedAt` (web `Math.round((now − t0) / 1000)`), never negative.
    static func elapsed(since start: Date, now: Date) -> Int {
        let s = now.timeIntervalSince(start)
        guard s.isFinite, s > 0 else { return 0 }
        return Int((s + 0.5).rounded(.down))
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.5)) { ctx in
            let elapsed = Self.elapsed(since: startedAt, now: ctx.date)
            HStack(alignment: .center, spacing: 14) {
                Spinner()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(phase == .queued ? "排队中…" : title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink1)
                        Text(verbatim: "\(elapsed)s")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.ink3)
                            .monospacedDigit()
                    }
                    let h = hint(elapsed)
                    if !h.isEmpty {
                        Text(h)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .nlPulse()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension JobProgressView {
    /// Log Meal staged hints (web1 §5.2): <8 s, <30 s, <70 s, then the last message.
    static func mealHint(_ elapsed: Int) -> String {
        elapsed < 8 ? "识别食物与份量…"
            : elapsed < 30 ? "估算 40+ 种营养素、食物组与加工程度…"
            : elapsed < 70 ? "查询品牌产品的营养成分表…"
            : "快好了，正在核对致癌物与风险项…"
    }

    /// ActivityRecognizer busy hint (web1 §6), independent of the elapsed time.
    static func activityHint(_ elapsed: Int) -> String { "正在识别… 读取截图通常需要 20–60 秒" }

    /// Foods AI lookup busy hint (web2 §5.9.3): label photos vs. web search.
    static func foodHint(hasPhotos: Bool) -> (Int) -> String {
        { _ in (hasPhotos ? "正在读取标签…" : "正在联网查找营养成分表…") + " 一般需要 30–120 秒" }
    }
}

#Preview("JobProgressView") {
    DSPreviewSchemes {
        Card { JobProgressView(title: "Claude 正在分析", phase: .running, startedAt: Date().addingTimeInterval(-12), hint: JobProgressView.mealHint) }
        Card { JobProgressView(title: "Claude 正在分析", phase: .queued, startedAt: Date(), hint: JobProgressView.mealHint) }
        Card { JobProgressView(title: "AI 识别", phase: .running, startedAt: Date().addingTimeInterval(-41), hint: JobProgressView.activityHint) }
    }
}
