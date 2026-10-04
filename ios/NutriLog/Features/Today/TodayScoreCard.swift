import SwiftUI

// MARK: - A1. ScoreCard `今日总分` (web1 §4.3 A1; rep §3.2, §17.2)
// Ring (composite total, `满分 100` / `暂无记录`) beside or above a column with TotalParts, the HEI-2020 and MAR meters and
// the hazard count; without HEI a muted explanation instead. A `partial` completeness note shows as a warn banner.

struct TodayScoreCard: View {
    let score: DailyScore
    /// `meta.heiUsMean` (58 when meta is not loaded yet).
    let heiUsMean: Double
    /// `评分依据` → Standards → 评分规则.
    let onShowRules: @MainActor () -> Void

    /// HEI total meter status: ≥80 good, ≥51 warn, else bad.
    static func heiStatus(_ v: Double) -> ScoreStatus { .threshold(v, good: 80, warn: 51) }
    /// MAR meter status: ≥90 good, ≥70 warn, else bad.
    static func marStatus(_ v: Double) -> ScoreStatus { .threshold(v, good: 90, warn: 70) }

    /// The 2 nutrients with the lowest NAR (stable order on ties), joined by `、`.
    static func weakest(_ mar: MarResult) -> String {
        mar.nutrients.enumerated()
            .sorted { $0.element.nar != $1.element.nar ? $0.element.nar < $1.element.nar : $0.offset < $1.offset }
            .prefix(2)
            .map(\.element.zh)
            .joined(separator: "、")
    }

    var body: some View {
        Card {
            CardHeader("今日总分") {
                if score.hasData { rulesHint }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    ring
                    details.frame(minWidth: 200)
                }
                VStack(alignment: .center, spacing: 18) {
                    ring
                    details
                }
            }
            if score.hasData && score.completeness.level == "partial" {
                Banner(score.completeness.note, icon: "info.circle", style: .warn)
            }
        }
    }

    /// `四项按权重合成 · 评分依据` (the second part is a link).
    private var rulesHint: some View {
        HStack(spacing: 0) {
            Text("四项按权重合成 · ")
                .foregroundStyle(Theme.ink3)
            Button(action: onShowRules) {
                Text("评分依据").foregroundStyle(Theme.accentText)
            }
            .buttonStyle(.plain)
        }
        .font(Theme.Font.hint)
        .fixedSize()
    }

    private var ring: some View {
        ScoreRing(score: score.total.score, grade: score.total.score != nil ? "满分 100" : "暂无记录")
            .accessibilityLabel(Text(verbatim: "今日总分 \(ScoreRing.numberText(score.total.score))，\(score.total.score != nil ? "满分 100" : "暂无记录")"))
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hei = score.hei {
                TotalPartsLine(total: score.total)
                Meter(name: "HEI-2020 膳食质量", value: hei.total, unit: "/ 100", max: 100,
                      status: Self.heiStatus(hei.total), decimals: 1,
                      foot: "13 个组分按每 1000 kcal 的密度计分，分值由 USDA 规定；美国人平均 \(DSFormat.js(heiUsMean))")
                if let mar = score.mar {
                    Meter(name: "微量营养素充足 MAR", value: mar.value, unit: "/ 100", max: 100,
                          status: Self.marStatus(mar.value),
                          foot: "11 种微量营养素达到 RDA 的平均比例（每种封顶 100%，等权）；最缺：\(Self.weakest(mar))")
                }
                if !score.hazards.isEmpty {
                    Label {
                        Text(verbatim: "\(score.hazards.count) 项致癌/风险物警示（见下方）")
                    } icon: {
                        Image(systemName: "exclamationmark.shield").font(.system(size: 14))
                    }
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.criticalText)
                }
            } else {
                Text("记录饮食后，这里显示 USDA 的 HEI-2020 膳食质量分和 11 种微量营养素的充足度（MAR）。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
