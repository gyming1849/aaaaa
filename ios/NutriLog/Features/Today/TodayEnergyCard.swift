import SwiftUI

// MARK: - A2. EnergyCard `能量平衡` (web1 §4.3 A2; rep §3.8, §4, §17.2)
// Hint (EER fallback or resting/active sources), 4 stats (2×2 on phones), intake/expenditure/target bars, the target
// explanation, and — only with data — the macro energy split (stacked bar + legend).

struct TodayEnergyCard: View {
    let day: DayResponse

    private var score: DailyScore { day.score }
    private var energy: EnergyResult { day.score.energy }
    private var targets: Targets { day.targets }

    /// `无活动数据，按 {eerMethod} 估算` or `静息 {来自设备|按 BMR} · 活动：{ACTIVE_SRC}`.
    static func hint(energy: EnergyResult, targets: Targets) -> String {
        if energy.method == "eer" { return "无活动数据，按 \(targets.eerMethod) 估算" }
        let resting = energy.restingSource == "device" ? "来自设备" : "按 BMR"
        return "静息 \(resting) · 活动：\(Vocab.activeSourceZh[energy.activeSource] ?? energy.activeSource)"
    }

    /// `目标 = 当日消耗 {X}，不低于 {floor} kcal · BMR {bmr} · EER {eer}` (U+2212 minus for a negative goal delta).
    static func targetNote(_ t: Targets) -> String {
        let x: String
        if t.goalDeltaKcal != 0 {
            x = "\(t.goalDeltaKcal > 0 ? "+" : "−") \(fmt(abs(t.goalDeltaKcal)))（\(t.goal == "lose" ? "减重" : "增重")目标）"
        } else {
            x = "（维持体重）"
        }
        return "目标 = 当日消耗 \(x)，不低于 \(fmt(t.energyFloor)) kcal · BMR \(fmt(t.bmr)) · EER \(fmt(t.eer))"
    }

    /// `可接受范围：蛋白 10–35% · 碳水 45–65% · 脂肪 20–35%` (raw JS numbers joined by an en dash).
    static func amdrText(_ a: Amdr) -> String {
        func r(_ v: [Double]) -> String { v.map { DSFormat.js($0) }.joined(separator: "–") }
        return "可接受范围：蛋白 \(r(a.protein))% · 碳水 \(r(a.carb))% · 脂肪 \(r(a.fat))%"
    }

    var body: some View {
        let bal = energy.intake - energy.tdee
        Card {
            CardHeader("能量平衡", icon: "flame", hint: Self.hint(energy: energy, targets: targets))
            EqualHeightGridLayout(columns: 2, spacing: Theme.Metrics.tileGap) {
                TodayStat(label: "摄入", value: fmt(energy.intake), unit: "kcal")
                TodayStat(label: "消耗", value: fmt(energy.tdee), unit: "kcal")
                TodayStat(label: "差额", value: Fmt.signed(bal), unit: "kcal",
                          delta: "≈ \(bal > 0 ? "+" : "")\(fmt(bal / 7700 * 1000)) g 体重")
                TodayStat(label: "体重", value: weightValue, unit: "kg", delta: weightDelta)
            }
            .padding(.bottom, 2)
            bars
            Text(Self.targetNote(targets))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -6)
            if score.hasData {
                TodayListDivider()
                macros
            }
        }
    }

    private var weightValue: String {
        if let w = score.weighedToday { return fmt(w, 1) }
        return fmt(targets.weightKg, 1)
    }

    private var weightDelta: String {
        let trend = day.weightTrend.map { "趋势 \(fmt($0, 1)) kg" } ?? ""
        return trend + (score.weighedToday == nil ? "（今日未称重）" : "")
    }

    // MARK: Bars 摄入 / 消耗 / 目标

    private var bars: some View {
        let rows: [(String, Double, Color)] = [
            ("摄入", energy.intake, Theme.s1),
            ("消耗", energy.tdee, Theme.s2),
            ("目标", energy.target, Theme.s3),
        ]
        let peak = max(energy.intake, energy.target, energy.tdee) * 1.08
        let scale = peak.isFinite && peak != 0 ? peak : 1
        return VStack(spacing: 8) {
            ForEach(rows, id: \.0) { label, value, color in
                HStack(spacing: 10) {
                    Text(label)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 30, alignment: .leading)
                        .fixedSize()
                    GeometryReader { geo in
                        let f = value.isFinite ? min(1, max(0, value / scale)) : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface2)
                            Capsule().fill(color).frame(width: geo.size.width * f)
                        }
                    }
                    .frame(height: 10)
                    Text(verbatim: fmt(value))
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "摄入 \(fmt(energy.intake))，消耗 \(fmt(energy.tdee))，目标 \(fmt(energy.target)) 千卡"))
    }

    // MARK: Macro split (only with data)

    private var macros: some View {
        let mp = score.macroPct
        let showAlcohol = mp.alcohol > 0.5
        var segments: [(String, Double, Color)] = [
            ("蛋白质", mp.protein, Theme.s1),
            ("碳水", mp.carb, Theme.s3),
            ("脂肪", mp.fat, Theme.s2),
        ]
        if showAlcohol { segments.append(("酒精", mp.alcohol, Theme.s5)) }
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("宏量营养素供能比").foregroundStyle(Theme.ink2)
                    Spacer(minLength: 8)
                    Text(Self.amdrText(targets.amdr)).foregroundStyle(Theme.ink3)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("宏量营养素供能比").foregroundStyle(Theme.ink2)
                    Text(Self.amdrText(targets.amdr))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Theme.Font.small)
            TodayMacroBar(segments: segments.map { ($0.1, $0.2) })
                .frame(height: 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "蛋白质 \(fmt(mp.protein))%，碳水 \(fmt(mp.carb))%，脂肪 \(fmt(mp.fat))%"))
            FlowLayout(spacing: 14, lineSpacing: 6) {
                ForEach(segments, id: \.0) { label, value, color in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
                        Text(verbatim: "\(label) \(fmt(value))%")
                    }
                    .font(Theme.Font.hint)
                    .foregroundStyle(Theme.ink2)
                }
            }
        }
    }
}

/// The 10 pt rounded stacked bar (web `.stacked-bar`): segments sized by their raw percentages, 2 pt gaps.
private struct TodayMacroBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(max(0, segments.count - 1)) * 2
            let usable = max(0, geo.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    let pct = seg.0.isFinite ? max(0, seg.0) : 0
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: min(usable, usable * pct / 100))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .background(Theme.surface)
            .clipShape(Capsule())
        }
    }
}
