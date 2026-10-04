import SwiftUI

// MARK: - ImpactPreview "合并预览" (web1 §3.7; `ActivityRecognizer.tsx` ImpactPreview), shared by Log Meal and ActivityRecognizer.
// A flat card on surface-2: h3 `合并预览`, hint `确认前不会写入；数值随修改实时更新`, a 指标 | 合并前 | → | 合并后 table,
// then `状态变化：`, `LE8 分项：` and `新增风险物：` lines.

struct ImpactPreviewCard: View {
    let preview: DayPreview

    init(preview: DayPreview) {
        self.preview = preview
    }

    enum Better: Sendable { case up, down }

    struct Row: Identifiable {
        let label: String
        let before: Double?
        let after: Double?
        let unit: String
        let decimals: Int
        let better: Better?
        let always: Bool
        var id: String { label }
    }

    /// Candidate rows in web order, filtered to `|after − before| > 0.05` (nil counts as 0) or `always`.
    static func rows(_ p: DayPreview) -> [Row] {
        let b = p.before, a = p.after, ib = p.indices.before, ia = p.indices.after
        let all: [Row] = [
            Row(label: "膳食质量 HEI-2020", before: b.score, after: a.score, unit: "", decimals: 1, better: .up, always: true),
            Row(label: "微量营养素 MAR", before: b.mar?.value, after: a.mar?.value, unit: "", decimals: 0, better: .up, always: false),
            Row(label: "心血管健康 LE8（近 7 天）", before: ib.le8.score, after: ia.le8.score, unit: "", decimals: 0, better: .up, always: true),
            Row(label: "防癌 WCRF/AICR（近 7 天）", before: ib.wcrf.score, after: ia.wcrf.score, unit: "/ \(DSFormat.js(ia.wcrf.max))", decimals: 2, better: .up, always: false),
            Row(label: "摄入能量", before: b.energy.intake, after: a.energy.intake, unit: "kcal", decimals: 0, better: nil, always: false),
            Row(label: "当日消耗", before: b.energy.tdee, after: a.energy.tdee, unit: "kcal", decimals: 0, better: nil, always: false),
            Row(label: "能量差额", before: b.energy.intake - b.energy.tdee, after: a.energy.intake - a.energy.tdee, unit: "kcal", decimals: 0, better: nil, always: false),
            Row(label: "钠", before: b.totals["sodium_mg"], after: a.totals["sodium_mg"], unit: "mg", decimals: 0, better: .down, always: false),
            Row(label: "添加糖", before: b.totals["added_sugars_g"], after: a.totals["added_sugars_g"], unit: "g", decimals: 1, better: .down, always: false),
            Row(label: "饱和脂肪", before: b.totals["sat_fat_g"], after: a.totals["sat_fat_g"], unit: "g", decimals: 1, better: .down, always: false),
            Row(label: "蛋白质", before: b.totals["protein_g"], after: a.totals["protein_g"], unit: "g", decimals: 1, better: .up, always: false),
            Row(label: "膳食纤维", before: b.totals["fiber_g"], after: a.totals["fiber_g"], unit: "g", decimals: 1, better: .up, always: false),
        ]
        return all.filter { abs(($0.after ?? 0) - ($0.before ?? 0)) > 0.05 || $0.always }
    }

    /// After-cell colour: ink unless both values exist, the row has a direction and |Δ| > 0.05;
    /// then good-text when it moved the better way, critical-text otherwise.
    static func tone(_ r: Row) -> Color {
        guard let a = r.after, let b = r.before, let better = r.better, abs(a - b) > 0.05 else { return Theme.ink }
        let up = a > b
        return (better == .up) == up ? Theme.goodText : Theme.criticalText
    }

    /// `状态变化：` entries: after items with status ≠ info whose key exists before and whose status word changed.
    static func statusChanges(_ p: DayPreview) -> [String] {
        var before: [String: ScoreStatus] = [:]
        for item in p.before.items where before[item.key] == nil { before[item.key] = item.status }
        return p.after.items.compactMap { i in
            guard i.status != .info, let old = before[i.key], old.label != i.status.label else { return nil }
            return "\(i.category == "hei" ? "HEI·" : "")\(i.zh)（\(old.label) → \(i.status.label)）"
        }
    }

    /// `LE8 分项：` entries: components whose points differ, as `{zh} {old ?? "—"} → {new ?? "—"}`.
    static func le8Changes(_ p: DayPreview) -> [String] {
        let old = p.indices.before.le8.components
        return p.indices.after.le8.components.compactMap { c in
            let o = old.first { $0.key == c.key }?.points
            guard o != c.points else { return nil }
            return "\(c.zh) \(o.map { DSFormat.js($0) } ?? "—") → \(c.points.map { DSFormat.js($0) } ?? "—")"
        }
    }

    /// `新增风险物：` entries: after hazards whose key is not in before, as `{zh}（IARC {iarc}）`.
    static func newHazards(_ p: DayPreview) -> [String] {
        let keys = Set(p.before.hazards.map(\.key))
        return p.after.hazards.filter { !keys.contains($0.key) }.map { "\($0.zh)（IARC \($0.iarc)）" }
    }

    var body: some View {
        let rows = Self.rows(preview)
        let flips = Self.statusChanges(preview)
        let le8 = Self.le8Changes(preview)
        let hazards = Self.newHazards(preview)
        Card {
            CardHeader("合并预览", hint: "确认前不会写入；数值随修改实时更新").headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    Text("指标")
                    Text("合并前").gridColumnAlignment(.trailing)
                    Color.clear.frame(width: 24, height: 1)
                    Text("合并后").gridColumnAlignment(.trailing)
                }
                .font(Theme.Font.tableHead)
                .foregroundStyle(Theme.ink3)
                .padding(.vertical, 8)
                Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    GridRow(alignment: .center) {
                        Text(r.label)
                            .foregroundStyle(Theme.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: DSFormat.value(r.before, r.decimals, unit: r.unit))
                            .foregroundStyle(Theme.ink3)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(verbatim: DSFormat.value(r.after, r.decimals, unit: r.unit))
                            .fontWeight(.semibold)
                            .foregroundStyle(Self.tone(r))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(Theme.Font.meter)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if i < rows.count - 1 {
                        Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            if !flips.isEmpty || !le8.isEmpty || !hazards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !flips.isEmpty { footLine("状态变化：", flips.joined(separator: "；"), color: Theme.ink1) }
                    if !le8.isEmpty { footLine("LE8 分项：", le8.joined(separator: "；"), color: Theme.ink1) }
                    if !hazards.isEmpty { footLine("新增风险物：", hazards.joined(separator: "、"), color: Theme.criticalText) }
                }
                .padding(.top, -4)
            }
        }
        .cardStyle(background: Theme.surface2, flat: true)
    }

    private func footLine(_ label: String, _ text: String, color: Color) -> some View {
        var s = AttributedString(label)
        s.inlinePresentationIntent = .stronglyEmphasized
        s += AttributedString(text)
        return Text(s)
            .font(Theme.Font.small)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("ImpactPreviewCard") {
    DSPreviewSchemes {
        ImpactPreviewCard(preview: DSPreviewData.preview)
        ImpactPreviewCard(preview: DayPreview(date: "2026-09-30", before: DSPreviewData.before, after: DSPreviewData.before,
                                              indices: PreviewIndices(before: DSPreviewData.indices, after: DSPreviewData.indices)))
    }
}
