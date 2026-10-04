import SwiftUI

// MARK: - Tab `hazards` 致癌物与风险物 (web2 §5.10, rep §9.3; data `meta.hazards` / `meta.hazardsInfoOnly`)
// Info banner, one card per hazard (2-column grid on the web, single column on iPhone), then the
// `已知但不警示的项目` table.

struct StandardsHazardsTab: View {
    let meta: Meta

    static let bannerText = "IARC 分级表示“证据强度”而不是“危险程度”：加工肉与吸烟同属 1 类，意味着致癌证据同样充分，而不是危害同样大。没有权威机构发布过把这些分级换算成扣分的方法，所以本站只按剂量给出警示、不另设扣分；其中加工肉、红肉、酒精、含糖饮料按 WCRF/AICR 标准化评分计分。"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            Banner(Self.bannerText)
            ForEach(meta.hazards) { hazard in
                StandardsHazardCard(hazard: hazard, sources: meta.sources)
            }
            infoOnlyCard
        }
    }

    // MARK: 已知但不警示的项目

    /// Web columns `项目 | 分级 | 常见来源 | 原因`. On an iPhone 常见来源 and 原因 sit under each row, labelled with their
    /// column titles.
    private var infoOnlyCard: some View {
        let items = meta.hazardsInfoOnly
        return Card {
            CardHeader("已知但不警示的项目").headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    StandardsTableHead("项目")
                    StandardsTableHead("分级")
                }
                StandardsHairline()
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    GridRow(alignment: .center) {
                        StandardsNameCell(item.zh)
                        grade(item.iarc)
                            .gridColumnAlignment(.leading)
                    }
                    .padding(.top, 9)
                    .padding(.bottom, 6)
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            StandardsInlineField(label: "常见来源", value: item.examples, color: Theme.ink1)
                            StandardsInlineField(label: "原因", value: item.why, color: Theme.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridCellColumns(2)
                    }
                    .padding(.bottom, 9)
                    if index < items.count - 1 { StandardsHairline() }
                }
            }
        }
    }

    /// `iarc == "3"` → plain chip `IARC 3 类`; otherwise `IarcChip`.
    @ViewBuilder
    private func grade(_ iarc: String) -> some View {
        if iarc == "3" {
            Chip("IARC 3 类")
        } else {
            IarcChip(iarc)
        }
    }
}

/// One hazard card: `zh` (h3) + IarcChip + muted `en`; 风险 / 判定 / 例 / 建议 lines; `依据：` sources.
struct StandardsHazardCard: View {
    let hazard: HazardDef
    let sources: [SourceDef]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    Text(hazard.zh)
                        .font(Theme.Font.h3)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    IarcChip(hazard.iarc)
                    Text(hazard.en)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                }
                line("风险：", hazard.risk, color: Theme.ink1)
                line("判定：", hazard.detect, color: Theme.ink1)
                line("例：", hazard.examples, color: Theme.ink2)
                line("建议：", hazard.advice, color: Theme.accentText)
                SourceLinks(ids: hazard.sources, sources: sources)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ label: String, _ text: String, color: Color) -> some View {
        Text(StandardsText.labeled(label, text))
            .font(Theme.Font.small)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
