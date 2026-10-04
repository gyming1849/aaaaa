import SwiftUI

// MARK: - Tab `met` 运动 MET (web2 §5.10, rep §9.5; data `meta.activities`)
// Card `运动代谢当量（2024 Adult Compendium）`; table `活动 | MET | 强度 | 典型速度`. MET and speed are printed raw.

struct StandardsMetTab: View {
    let meta: Meta

    var body: some View {
        let rows = meta.activities
        Card {
            CardHeader("运动代谢当量（2024 Adult Compendium）", hint: "净消耗 = (MET − 1) × 体重 × 小时，扣除静息部分避免与基础代谢重复")
                .headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    StandardsTableHead("活动")
                    StandardsTableHead("MET", trailing: true)
                    StandardsTableHead("强度")
                    StandardsTableHead("典型速度", trailing: true)
                }
                StandardsHairline()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, a in
                    GridRow(alignment: .center) {
                        StandardsNameCell(a.zh)
                        StandardsNumberCell(StandardsText.raw(a.met))
                        StandardsNumberCell(Self.intensityZh(a.intensity), trailing: false)
                        StandardsNumberCell(Self.speedText(a.speedKmh))
                    }
                    .padding(.vertical, 9)
                    if index < rows.count - 1 { StandardsHairline() }
                }
            }
        }
    }

    /// `vigorous` → 高强度, `moderate` → 中等, anything else → 轻度.
    static func intensityZh(_ intensity: String) -> String {
        switch intensity {
        case "vigorous": "高强度"
        case "moderate": "中等"
        default: "轻度"
        }
    }

    /// `"{speedKmh} km/h"`, or `—` when absent (or 0, which is falsy on the web).
    static func speedText(_ speed: Double?) -> String {
        guard let speed, speed != 0 else { return "—" }
        return "\(StandardsText.raw(speed)) km/h"
    }
}
