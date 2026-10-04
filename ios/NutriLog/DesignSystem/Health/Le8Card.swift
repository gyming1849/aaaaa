import SwiftUI

// MARK: - Le8Card (web1 §3.5, web2 §5.3.1, `HealthIndices.tsx`)
// Header: heart-pulse icon + h2 title (default `心血管健康 Life's Essential 8`); hint = subtitle ?? `美国心脏协会 2022 · 近 {windowDays} 天`.
// Hero row (wraps on phones): ScoreRing(size 132, le8.score, grade `{category.zh}（{available}/8 项）` or `数据不足`)
// and a column of the 8 components in server order: a Meter (/ 100, status ≥80 good, ≥50 warn, else bad, foot = value,
// plus ` · 查看 16 题` for `diet` when MEPA exists) or a "缺数据：{missing}" row. Footer note in small muted text.

struct Le8Card: View {
    let indices: HealthIndices
    let title: String
    let subtitle: String?
    @State private var showMepa = false

    init(indices: HealthIndices, title: String = "心血管健康 Life's Essential 8", subtitle: String? = nil) {
        self.indices = indices
        self.title = title
        self.subtitle = subtitle
    }

    /// LE8 component status: ≥80 good, ≥50 warn, else bad.
    static func status(_ points: Double) -> ScoreStatus { .threshold(points, good: 80, warn: 50) }

    /// Ring grade: `中（6/8 项）` or `数据不足`.
    static func grade(_ le8: Le8Result) -> String {
        guard let c = le8.category else { return "数据不足" }
        return "\(c.zh)（\(le8.available)/8 项）"
    }

    var body: some View {
        let le8 = indices.le8
        Card {
            CardHeader(title, icon: "heart.text.square", hint: subtitle ?? "美国心脏协会 2022 · 近 \(indices.windowDays) 天")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    ring(le8)
                    components(le8).frame(minWidth: 220)
                }
                VStack(alignment: .leading, spacing: 22) {
                    ring(le8)
                    components(le8)
                }
            }
            Text("总分 = 已有指标的等权平均（缺失指标不计入分母）；80–100 高，50–79 中，0–49 低。")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -4)
        }
        .sheet(isPresented: $showMepa) {
            if let mepa = indices.mepa {
                MepaSheet(mepa: mepa)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func ring(_ le8: Le8Result) -> some View {
        ScoreRing(score: le8.score, grade: Self.grade(le8), size: 132)
    }

    private func components(_ le8: Le8Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(le8.components) { c in
                if let points = c.points {
                    Meter(name: c.zh, value: points, unit: "/ 100", max: 100, status: Self.status(points),
                          foot: c.value,
                          footLink: c.key == "diet" && indices.mepa != nil ? MeterFootLink(title: "查看 16 题") { showMepa = true } : nil)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(c.zh)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        Text(verbatim: "缺数据：\(c.missing)")
                            .foregroundStyle(Theme.ink3)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.Font.small)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - MEPA sheet (web1 §3.5 "MEPA modal", web2 §5.3.2)

struct MepaSheet: View {
    let mepa: MepaResult

    init(mepa: MepaResult) {
        self.mepa = mepa
    }

    var body: some View {
        SheetScaffold(title: "MEPA 饮食问卷：\(mepa.score)/16") {
            Text(verbatim: "AHA Life's Essential 8 规定的个人饮食评分工具（Cerwinske 2017）。由你近 \(mepa.days) 天的饮食记录自动推算每周 / 每天份数，每满足一题得 1 分。15–16 分 → 100，12–14 → 80，8–11 → 50，4–7 → 25，0–3 → 0。")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text("题目")
                    Text("标准")
                    Text("你的记录").gridColumnAlignment(.trailing)
                    Text(verbatim: "")
                }
                .font(Theme.Font.tableHead)
                .foregroundStyle(Theme.ink3)
                .padding(.vertical, 8)
                Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(mepa.items.enumerated()), id: \.offset) { i, item in
                    GridRow(alignment: .center) {
                        Text(item.zh)
                            .font(Theme.Font.meter)
                            .foregroundStyle(Theme.ink1)
                        Text(item.criterion)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: "\(fmt(item.value, 1)) \(item.unit)")
                            .font(Theme.Font.meter)
                            .foregroundStyle(Theme.ink1)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                        if item.met {
                            StatusBadge(.good, text: "✓ 1 分", showsIcon: false)
                        } else {
                            StatusBadge(.info, text: "0 分", showsIcon: false)
                        }
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if i < mepa.items.count - 1 {
                        Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
        }
    }
}

#Preview("Le8Card") {
    DSPreviewSchemes {
        Le8Card(indices: DSPreviewData.indices)
        Le8Card(indices: DSPreviewData.emptyIndices, title: "心血管健康 LE8", subtitle: "AHA Life's Essential 8 · 1/7 天有记录")
    }
}

#Preview("MepaSheet") {
    MepaSheet(mepa: DSPreviewData.mepa)
}

#Preview("MepaSheet · 深色") {
    MepaSheet(mepa: DSPreviewData.mepa).preferredColorScheme(.dark)
}
