import SwiftUI

// MARK: - Tab `mine` 我的个性化目标 (web2 §5.10, rep §17.7; data `GET /profile/targets` + meta)
// 4 stat tiles (2×2), then the intake card and the limits card (single column on iPhone).

struct StandardsMineTab: View {
    let targets: Targets
    let meta: Meta

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            tiles
            intakeCard
            limitsCard
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let t = targets
        return StatTileGrid {
            StatTile(label: "适用人群", value: t.lifeStageZh, delta: "\(t.age) 岁\(t.sensitive ? " · 敏感人群" : "")",
                     valueFont: .system(size: 20, weight: .semibold))
            StatTile(label: "BMI", value: fmt(t.bmi, 1), delta: bmiDelta)
            StatTile(label: "基础代谢 / 能量需求", value: fmt(t.bmr), unit: "/ \(fmt(t.eer)) kcal", delta: t.eerMethod)
            StatTile(label: "每日能量目标（无活动数据时）", value: fmt(t.energyTarget), unit: "kcal",
                     delta: t.goalDeltaKcal != 0 ? "含目标调整 \(Fmt.signed(t.goalDeltaKcal))" : "维持")
        }
    }

    private var bmiDelta: String {
        let t = targets
        let corrected = t.referenceWeightKg != t.weightKg ? " · 按体重的目标使用校正体重 \(fmt(t.referenceWeightKg, 1)) kg" : ""
        return t.bmiCategory.zh + corrected
    }

    // MARK: 推荐摄入量

    /// `meta.nutrients` (meta order) that have an intake target.
    private var intakeRows: [(def: NutrientDef, target: IntakeTarget)] {
        meta.nutrients.compactMap { n in targets.intake[n.key].map { (n, $0) } }
    }

    private var intakeCard: some View {
        let rows = intakeRows
        return Card {
            CardHeader("推荐摄入量（下限，越接近越好）", hint: "RDA = 推荐膳食供给量；AI = 适宜摄入量").headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    StandardsTableHead("营养素")
                    StandardsTableHead("目标", trailing: true)
                    StandardsTableHead("类型")
                    StandardsTableHead("UL 上限", trailing: true)
                }
                StandardsHairline()
                ForEach(Array(rows.enumerated()), id: \.element.def.key) { index, row in
                    GridRow(alignment: .center) {
                        StandardsNameCell(row.def.zh, detail: row.target.note)
                        StandardsNumberCell("\(fmt(row.target.value, row.def.decimals)) \(row.def.unit)")
                        StandardsNumberCell(row.target.kind, trailing: false)
                        StandardsNumberCell(upperText(row.def), font: Theme.Font.small)
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if index < rows.count - 1 { StandardsHairline() }
                }
            }
            Text(verbatim: "* 该 UL 只针对补充剂/强化食品或特定形式（如预制维生素 A、合成叶酸），食物总量不参与 UL 评分。")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `"{fmt(upper, decimals)}{appliesToTotal ? "" : "*"}"`, or `—` without a UL.
    private func upperText(_ n: NutrientDef) -> String {
        guard let u = targets.upper[n.key] else { return "—" }
        return fmt(u.value, n.decimals) + (u.appliesToTotal ? "" : "*")
    }

    // MARK: 限量标准

    /// `Object.values(limits)` in server order (`Targets.limitOrder`); unknown keys (newer servers) follow.
    private var limitRows: [LimitTarget] {
        let known = targets.orderedLimits
        let extra = targets.limits.keys.filter { !Targets.limitOrder.contains($0) }.sorted().compactMap { targets.limits[$0] }
        return known + extra
    }

    private var limitsCard: some View {
        let t = targets
        let rows = limitRows
        return Card {
            CardHeader("限量标准（上限，越少越好）").headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    StandardsTableHead("项目")
                    StandardsTableHead("理想", trailing: true)
                    StandardsTableHead("上限", trailing: true)
                }
                StandardsHairline()
                ForEach(rows, id: \.key) { l in
                    limitRow(name: l.zh, note: l.note,
                             ideal: "\(fmt(l.ideal, 1)) \(l.unit)",
                             limit: "\(fmt(l.limit, 1)) \(l.unit)",
                             sources: uniqueIds([l.idealSource, l.limitSource]))
                    StandardsHairline()
                }
                limitRow(name: "每餐添加糖", note: nil, ideal: "0",
                         limit: "\(StandardsText.raw(t.addedSugarPerMealG)) g", sources: ["dga_2025"])
                StandardsHairline()
                limitRow(name: "阿斯巴甜 ADI（按体重）", note: nil, ideal: "—",
                         limit: "\(fmt(t.aspartameAdiMg)) mg", sources: ["iarc_aspartame"])
            }
            Rectangle().fill(Theme.hair).frame(height: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "宏量营养素可接受范围（AMDR）")
                    .font(Theme.Font.h3)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                StandardsKeyValueList(items: amdrItems)
            }
        }
    }

    /// One limits row: item | ideal | limit, with the `依据：` source links underneath (the web's 4th column).
    @ViewBuilder
    private func limitRow(name: String, note: String?, ideal: String, limit: String, sources: [String]) -> some View {
        GridRow(alignment: .center) {
            StandardsNameCell(name, detail: note)
            StandardsNumberCell(ideal)
            StandardsNumberCell(limit)
        }
        .padding(.top, 9)
        .padding(.bottom, SourceLinks.resolve(sources, in: meta.sources).isEmpty ? 9 : 4)
        .accessibilityElement(children: .combine)
        if !SourceLinks.resolve(sources, in: meta.sources).isEmpty {
            GridRow {
                SourceLinks(ids: sources, sources: meta.sources)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridCellColumns(3)
            }
            .padding(.bottom, 9)
        }
    }

    /// `[...new Set(ids)]`: duplicates removed, first occurrence kept.
    private func uniqueIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: AMDR

    private var amdrItems: [StandardsKeyValue] {
        let t = targets
        func range(_ r: [Double]) -> String { r.map(StandardsText.raw).joined(separator: "–") }
        return [
            StandardsKeyValue(key: "蛋白质",
                              value: "\(range(t.amdr.protein))% 能量（RDA \(fmt(t.protein.rdaG)) g；DGA 2025–2030 建议 \(fmt(t.protein.idealLowG))–\(fmt(t.protein.idealHighG)) g）"),
            StandardsKeyValue(key: "碳水化合物", value: "\(range(t.amdr.carb))% 能量"),
            StandardsKeyValue(key: "脂肪", value: "\(range(t.amdr.fat))% 能量"),
        ]
    }
}
