import SwiftUI

// MARK: - D. HazardsCard `致癌物与风险物警示` (web1 §4.3 D; rep §3.7, §17.2)
// Shown only when the day has hazards. Each row: name + IARC chip + `来自：…`, the message, `{risk}。建议：{advice}` from
// `meta.hazards`, and the source links (rendered by the shared `HazardResultRow`).

struct TodayHazardsCard: View {
    let hazards: [HazardResult]
    let meta: Meta?

    var body: some View {
        Card {
            CardHeader("致癌物与风险物警示", icon: "exclamationmark.shield",
                       hint: "IARC 分级表示证据强度；加工肉、红肉、酒精、含糖饮料计入 WCRF 防癌评分")
            HazardResultList(hazards: hazards, defs: meta?.hazards ?? [], sources: meta?.sources ?? [])
                .padding(.top, -8)
        }
    }
}
