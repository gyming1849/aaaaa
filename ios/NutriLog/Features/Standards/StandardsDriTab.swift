import SwiftUI

// MARK: - Tab `dri` DRI 总表 (web2 §5.10, rep §9.4; data `GET /standards/dri` + meta)
// Seg `RDA / AI 推荐量` / `UL 可耐受最高摄入量`; a wide table (12.5 pt) whose first column 营养素 stays pinned while the
// 20 life-stage columns scroll horizontally. Rows follow the server's key order (`Vocab.intakeOrder` / `upperOrder`).

struct StandardsDriTab: View {
    let dri: DriTables
    let meta: Meta

    enum Mode: Hashable { case intake, upper }
    /// Per visit, like the web (`useState("intake")` inside the tab).
    @State private var mode: Mode = .intake

    var body: some View {
        Card {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    seg.fixedSize()
                    Spacer(minLength: 6)
                    hint.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    seg
                    hint
                }
            }
            StandardsDriGrid(header: dri.lifeStages, rows: rows)
                .id(mode)
        }
    }

    private var seg: some View {
        Seg([SegOption(value: Mode.intake, label: "RDA / AI 推荐量"),
             SegOption(value: Mode.upper, label: "UL 可耐受最高摄入量")], selection: $mode)
    }

    private var hint: some View {
        Text(verbatim: "来源：NASEM DRI 汇总表（钠/钾为 2019 版）")
            .font(Theme.Font.hint)
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rows

    private var rows: [StandardsDriRow] {
        switch mode {
        case .intake:
            var result = Self.ordered(dri.intake, order: Vocab.intakeOrder).map { key, row in
                StandardsDriRow(id: key, name: name(key), detail: unit(key) + " · \(row.kind)",
                                values: row.values.map { $0.map { fmt($0, 2) } ?? "ND" })
            }
            result.append(StandardsDriRow(id: "__protein_per_kg", name: "蛋白质", detail: "g/kg",
                                          values: dri.proteinPerKg.map(StandardsText.raw)))
            result.append(StandardsDriRow(id: "__sodium_cdrr", name: "钠 CDRR", detail: "mg（超过即应减少）",
                                          values: dri.sodiumCdrr.map { fmt($0) }))
            return result
        case .upper:
            return Self.ordered(dri.upper, order: Vocab.upperOrder).map { key, row in
                StandardsDriRow(id: key, name: name(key), detail: unit(key) + (row.appliesToTotal ? "" : " · 仅补充剂"),
                                values: row.values.map { $0.map { fmt($0, 2) } ?? "ND" })
            }
        }
    }

    /// `meta.nutrients[key].zh ?? key`.
    private func name(_ key: String) -> String { meta.nutrients.first { $0.key == key }?.zh ?? key }
    /// `meta.nutrients[key].unit` (empty when unknown, like the web's `undefined`).
    private func unit(_ key: String) -> String { meta.nutrients.first { $0.key == key }?.unit ?? "" }

    /// Dictionary entries in the server's insertion order; keys missing from `order` (newer servers) follow, sorted.
    private static func ordered<V>(_ dict: [String: V], order: [String]) -> [(String, V)] {
        let known = order.compactMap { key in dict[key].map { (key, $0) } }
        let extra = dict.keys.filter { !order.contains($0) }.sorted().compactMap { key in dict[key].map { (key, $0) } }
        return known + extra
    }
}

/// One DRI table row: the pinned label (`zh` + muted unit/kind line) and one display string per life stage.
struct StandardsDriRow: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let values: [String]
}

// MARK: - Table with a pinned first column

/// The DRI matrix: the 营养素 column stays put; the header row and value rows scroll together horizontally.
/// Fixed row heights keep the pinned column and the scrolling part aligned.
private struct StandardsDriGrid: View {
    let header: [LifeStage]
    let rows: [StandardsDriRow]

    private let nameWidth: CGFloat = 122
    private let columnWidth: CGFloat = 66
    private let headHeight: CGFloat = 44
    private let rowHeight: CGFloat = 40
    private let cellFont = Font.system(size: 12.5)
    private let headFont = Font.system(size: 12.5, weight: .semibold)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            pinnedColumn
            ScrollView(.horizontal) {
                valueColumns
            }
            .scrollIndicators(.visible)
        }
    }

    // Pinned 营养素 column
    private var pinnedColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "营养素")
                .font(headFont)
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .frame(width: nameWidth, height: headHeight, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
            hairline
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(cellFont)
                        .foregroundStyle(Theme.ink1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 8)
                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { hairline }
            }
        }
        .frame(width: nameWidth)
        .background(Theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hair).frame(width: 1).accessibilityHidden(true)
        }
        .zIndex(1)
    }

    // Scrolling life-stage columns
    private var valueColumns: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(header) { stage in
                    Text(Self.headerLabel(stage.zh))
                        .font(headFont)
                        .foregroundStyle(Theme.ink3)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .frame(width: columnWidth, height: headHeight, alignment: .bottomTrailing)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            hairline
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.element.id) { i, stage in
                        let value = i < row.values.count ? row.values[i] : "—"
                        Text(value)
                            .font(cellFont)
                            .foregroundStyle(Theme.ink1)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 8)
                            .frame(width: columnWidth, height: rowHeight, alignment: .trailing)
                            .accessibilityLabel(Text(verbatim: "\(row.name) \(stage.zh) \(value)"))
                    }
                }
                if index < rows.count - 1 { hairline }
            }
        }
        .frame(width: columnWidth * CGFloat(header.count), alignment: .leading)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.hair).frame(height: 1).accessibilityHidden(true)
    }

    /// `儿童 1–3 岁` → `儿童` / `1–3 岁`: the two-line header breaks after the group word, never inside the age range.
    static func headerLabel(_ zh: String) -> String {
        guard let space = zh.firstIndex(of: " ") else { return zh }
        return String(zh[..<space]) + "\n" + String(zh[zh.index(after: space)...])
    }
}
