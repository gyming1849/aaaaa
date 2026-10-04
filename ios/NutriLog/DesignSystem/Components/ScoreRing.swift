import SwiftUI

// MARK: - ScoreRing (web1 §3.2, web2 §3.4)
// radius = size/2 − 9, stroke 10, track surface-3; arc from 12 o'clock clockwise with round caps, length score/100
// (null → 0), animated 0.6 s. Colour: null → axis; ≥70 good; ≥55 warning; ≥40 serious; else critical (same for LE8).
// Centre: round(score) or "—" at 48 pt bold (32 pt when size < 120), `grade` below in 13 pt ink-2.

struct ScoreRing: View {
    let score: Double?
    let grade: String?
    let size: CGFloat

    init(score: Double?, grade: String? = nil, size: CGFloat = 148) {
        self.score = score
        self.grade = grade
        self.size = size
    }

    static func color(for score: Double?) -> Color {
        guard let v = score, v.isFinite else { return Theme.axis }
        return v >= 70 ? Theme.good : v >= 55 ? Theme.warning : v >= 40 ? Theme.serious : Theme.critical
    }

    /// Centre text: `Math.round(score)` or `—`.
    static func numberText(_ score: Double?) -> String {
        guard let v = score, v.isFinite else { return "—" }
        return String(Int((v + 0.5).rounded(.down)))   // JS Math.round (half up)
    }

    private var progress: Double {
        guard let v = score, v.isFinite else { return 0 }
        return min(1, max(0, v / 100))
    }

    var body: some View {
        let diameter = max(0, size - 18)
        ZStack {
            Circle()
                .stroke(Theme.surface3, lineWidth: 10)
                .frame(width: diameter, height: diameter)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Self.color(for: score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .animation(.easeInOut(duration: 0.6), value: progress)
            VStack(spacing: 4) {
                Text(verbatim: Self.numberText(score))
                    .font(size < 120 ? Theme.Font.ringSmall : Theme.Font.ringBig)
                    .tracking(-0.02 * (size < 120 ? 32 : 48))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let grade {
                    Text(grade)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }
}

#Preview("ScoreRing") {
    DSPreviewSchemes {
        FlowLayout(spacing: 16) {
            ScoreRing(score: 82.4, grade: "满分 100")
            ScoreRing(score: 61, grade: "满分 100")
            ScoreRing(score: 47, grade: "中（6/8 项）", size: 132)
            ScoreRing(score: 22, grade: "满分 100", size: 110)
            ScoreRing(score: nil, grade: "暂无记录")
        }
    }
}
