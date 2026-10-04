import SwiftUI

// MARK: - Meter (web1 §3.1, web2 §3.4): progress / limit bar.
// scale = max(max, value, all mark.at) × 1.08 (0 → 1); fill = min(100, value/scale × 100) %, statusColor(status);
// marks are 2 pt ticks extending 3 pt above and below the 8 pt track at at/scale (offset −1 pt);
// ideal marks ink-3, limit marks ink-2. Mark labels are accessibility-only.

struct MeterMark: Hashable, Sendable {
    enum Kind: Sendable { case ideal, limit }
    let at: Double
    let label: String
    let kind: Kind
}

extension MeterMark {
    /// Web default kind is `limit`.
    init(_ at: Double, _ label: String, _ kind: Kind = .limit) {
        self.init(at: at, label: label, kind: kind)
    }
}

/// A tappable suffix after the foot text, e.g. LE8 diet ` · 查看 16 题`.
struct MeterFootLink {
    let title: String
    let action: @MainActor () -> Void
}

struct Meter: View {
    let name: String
    let value: Double
    let unit: String
    let max: Double
    let marks: [MeterMark]
    let status: ScoreStatus
    let decimals: Int
    let foot: String?
    let footLink: MeterFootLink?

    init(name: String, value: Double, unit: String, max: Double, marks: [MeterMark] = [], status: ScoreStatus, decimals: Int = 0, foot: String? = nil, footLink: MeterFootLink? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
        self.max = max
        self.marks = marks
        self.status = status
        self.decimals = decimals
        self.foot = foot
        self.footLink = footLink
    }

    /// `max(max, value, …marks.at) × 1.08`, or 1 when that is 0 (or not finite).
    static func scale(max: Double, value: Double, marks: [MeterMark]) -> Double {
        let m = ([max, value] + marks.map(\.at)).filter(\.isFinite).max() ?? 0
        let s = m * 1.08
        return s == 0 || !s.isFinite ? 1 : s
    }

    /// Fill fraction 0…1 (`min(100, value/scale × 100) %`, never negative).
    static func fraction(value: Double, scale: Double) -> Double {
        guard value.isFinite, scale.isFinite, scale != 0 else { return 0 }
        return Swift.min(1, Swift.max(0, value / scale))
    }

    var body: some View {
        let scale = Self.scale(max: max, value: value, marks: marks)
        VStack(alignment: .leading, spacing: marks.isEmpty ? 5 : 7) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(name)
                        .font(Theme.Font.meterName)
                        .foregroundStyle(Theme.ink1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    (Text(fmt(value, decimals)).fontWeight(.bold).foregroundStyle(Theme.ink)
                        + Text(verbatim: unit.isEmpty ? "" : " \(unit)").foregroundStyle(Theme.ink2))
                        .font(Theme.Font.meter)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                MeterTrack(fraction: Self.fraction(value: value, scale: scale), color: status.fill, marks: marks, scale: scale)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(name) \(fmt(value, decimals)) \(unit)"))
            .accessibilityValue(Text(verbatim: accessibilityMarks))

            if foot != nil || footLink != nil {
                footView
            }
        }
    }

    private var accessibilityMarks: String {
        let parts = marks.map { "\($0.label) \(fmt($0.at, decimals))" }
        return ([status.label] + parts).joined(separator: "，")
    }

    @ViewBuilder private var footView: some View {
        let text = Text(verbatim: foot ?? "").font(Theme.Font.foot).foregroundStyle(Theme.ink3)
        if let footLink {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    text.fixedSize()
                    link(footLink, prefix: foot == nil ? "" : " · ")
                }
                VStack(alignment: .leading, spacing: 2) {
                    text
                    link(footLink, prefix: "")
                }
            }
        } else {
            text.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link(_ l: MeterFootLink, prefix: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: prefix).font(Theme.Font.foot).foregroundStyle(Theme.ink3)
            Button(action: l.action) {
                Text(l.title).font(Theme.Font.foot).foregroundStyle(Theme.accentText)
            }
            .buttonStyle(.plain)
        }
        .fixedSize()
    }
}

/// The 8 pt capsule track with its fill and marks.
private struct MeterTrack: View {
    let fraction: Double
    let color: Color
    let marks: [MeterMark]
    let scale: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface3)
                Capsule().fill(color).frame(width: w * fraction)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    let x = Meter.fraction(value: m.at, scale: scale) * w - 1
                    RoundedRectangle(cornerRadius: 1)
                        .fill(m.kind == .ideal ? Theme.ink3 : Theme.ink2)
                        .frame(width: 2, height: 14)
                        .offset(x: x)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: fraction)
        }
        .frame(height: 8)
    }
}

#Preview("Meter") {
    DSPreviewSchemes {
        Card {
            Meter(name: "钠", value: 2875, unit: "mg", max: 2300,
                  marks: [MeterMark(1500, "理想", .ideal), MeterMark(2300, "上限")],
                  status: .bad, foot: "≈ 食盐 7.3 g · 上限 2,300 mg，理想 ≤ 1,500 mg")
            Meter(name: "添加糖", value: 18.4, unit: "g", max: 50,
                  marks: [MeterMark(25, "AHA", .ideal), MeterMark(50, "上限")],
                  status: .good, decimals: 1, foot: "上限 50 g，AHA 建议 ≤ 25 g；DGA 2025：每餐 ≤ 10 g")
            Meter(name: "HEI-2020 膳食质量", value: 64.2, unit: "/ 100", max: 100, status: .warn, decimals: 1)
            Meter(name: "饮食（MEPA）", value: 50, unit: "/ 100", max: 100, status: .warn,
                  foot: "MEPA 9/16（近 7 天记录推算）", footLink: MeterFootLink(title: "查看 16 题") {})
            Meter(name: "胆固醇", value: 0, unit: "mg", max: 300, status: .info)
        }
    }
}
