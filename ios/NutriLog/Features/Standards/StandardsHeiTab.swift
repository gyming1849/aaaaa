import SwiftUI

// MARK: - Tab `hei` HEI-2020 (web2 §5.10, rep §9.6; data `meta.hei`)
// Card `HEI-2020 组分与评分标准`. Web columns `组分 | 类型 | 满分 | 满分标准 | 零分标准`; on an iPhone the two criteria sit
// under each row, labelled with their column titles. Numbers are printed raw (no `fmt`), like the web.

struct StandardsHeiTab: View {
    let meta: Meta

    var body: some View {
        let rows = meta.hei
        Card {
            CardHeader("HEI-2020 组分与评分标准", hint: "满分 100；按每 1000 kcal 密度计算，两端之间线性插值").headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    StandardsTableHead("组分")
                    StandardsTableHead("类型")
                    StandardsTableHead("满分", trailing: true)
                }
                StandardsHairline()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, c in
                    GridRow(alignment: .center) {
                        StandardsNameCell(c.zh, detail: c.en)
                        Text(Self.kindText(c))
                            .font(Theme.Font.meter)
                            .foregroundStyle(Theme.ink1)
                            .fixedSize()
                        StandardsNumberCell(StandardsText.raw(c.max))
                    }
                    .padding(.top, 9)
                    .padding(.bottom, 6)
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            StandardsInlineField(label: "满分标准", value: Self.bestText(c))
                            StandardsInlineField(label: "零分标准", value: Self.worstText(c))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridCellColumns(3)
                    }
                    .padding(.bottom, 9)
                    if index < rows.count - 1 { StandardsHairline() }
                }
            }
            Text(verbatim: "豆类同时计入“蔬菜总量”“深绿色蔬菜与豆类”“蛋白质食物”“海产与植物蛋白”四个组分（HEI-2015 起的做法）。")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func isAdequacy(_ c: HeiDef) -> Bool { c.kind == "adequacy" }

    /// `充足（越多越好）` / `适度（越少越好）`.
    static func kindText(_ c: HeiDef) -> String { isAdequacy(c) ? "充足（越多越好）" : "适度（越少越好）" }

    /// `"{≥|≤} {best} {unit}"`.
    static func bestText(_ c: HeiDef) -> String {
        "\(isAdequacy(c) ? "≥" : "≤") \(StandardsText.raw(c.best)) \(c.unit)"
    }

    /// Adequacy: `≤ {worst}` (or `0` when worst is 0); moderation: `≥ {worst}`; then ` {unit}`.
    static func worstText(_ c: HeiDef) -> String {
        let head = isAdequacy(c) ? (c.worst != 0 ? "≤ \(StandardsText.raw(c.worst))" : "0") : "≥ \(StandardsText.raw(c.worst))"
        return "\(head) \(c.unit)"
    }
}
