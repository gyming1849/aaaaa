import SwiftUI

// MARK: - HazardResultRow (web1 §4.3 D, Today `HazardsCard`): one top-aligned list row per hazard:
// 1. bold zh + IarcChip(iarc) + small muted `来自：{foods.join("、")}` (when foods is not empty), wrapping;
// 2. small ink-2 message; 3. small muted `{def.risk}。建议：{def.advice}` when a meta definition exists;
// 4. SourceLinks(h.sources). Rows are separated by hairlines by the caller (or use `HazardResultList`).

struct HazardResultRow: View {
    let hazard: HazardResult
    let def: HazardDef?
    let sources: [SourceDef]

    init(hazard: HazardResult, def: HazardDef?, sources: [SourceDef]) {
        self.hazard = hazard
        self.def = def
        self.sources = sources
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 10, lineSpacing: 6) {
                Text(hazard.zh)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink1)
                IarcChip(hazard.iarc)
                if !hazard.foods.isEmpty {
                    Text(verbatim: "来自：\(hazard.foods.joined(separator: "、"))")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                }
            }
            if !hazard.message.isEmpty {
                Text(hazard.message)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let def {
                Text(verbatim: "\(def.risk)。建议：\(def.advice)")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SourceLinks(ids: hazard.sources, sources: sources)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }
}

/// A hairline-separated list of hazard rows (web `.list`), resolving definitions from `defs` (usually `app.meta?.hazards`).
struct HazardResultList: View {
    let hazards: [HazardResult]
    let defs: [HazardDef]
    let sources: [SourceDef]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hazards.enumerated()), id: \.offset) { i, h in
                HazardResultRow(hazard: h, def: defs.first { $0.key == h.key }, sources: sources)
                if i < hazards.count - 1 {
                    Rectangle().fill(Theme.hair).frame(height: 1)
                }
            }
        }
    }
}

#Preview("HazardResultRow") {
    DSPreviewSchemes {
        Card {
            CardHeader("致癌物与风险物警示", icon: "exclamationmark.shield", hint: "IARC 分级表示证据强度；加工肉、红肉、酒精、含糖饮料计入 WCRF 防癌评分")
            HazardResultList(hazards: [DSPreviewData.processedMeat, DSPreviewData.highTempMeat],
                             defs: [DSPreviewData.processedMeatDef], sources: DSPreviewData.sources)
        }
    }
}
