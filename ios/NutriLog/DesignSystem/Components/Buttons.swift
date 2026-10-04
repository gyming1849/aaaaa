import SwiftUI

// MARK: - Web `.btn` styles (web2 §3.3): height 38 / sm 30 / lg 46, radius 10 (sm 8), 14 pt (sm 13, lg 15), weight 550.
// Variants: plain (surface + border), primary (accent), ghost (transparent), danger (critical-text). Disabled = 50 % opacity.

struct NLButtonStyle: ButtonStyle {
    enum Kind: Sendable { case plain, primary, ghost, danger }
    enum Size: Sendable { case sm, md, lg }

    var kind: Kind = .plain
    var size: Size = .md
    /// Stretch to the full available width (`.btn.block`).
    var block: Bool = false
    /// Square icon-only button (`.btn.icon`): width = height.
    var iconOnly: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        NLButtonBody(configuration: configuration, style: self)
    }

    var height: CGFloat { switch size { case .sm: 30; case .md: 38; case .lg: 46 } }
    var radius: CGFloat { size == .sm ? 8 : 10 }
    var font: Font { switch size { case .sm: Theme.Font.buttonSmall; case .md: Theme.Font.button; case .lg: Theme.Font.buttonLarge } }
    var horizontalPadding: CGFloat { switch size { case .sm: 11; case .md: 16; case .lg: 22 } }
}

private struct NLButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: NLButtonStyle
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        HStack(spacing: 7) { configuration.label }
            .font(style.font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, style.iconOnly ? 0 : style.horizontalPadding)
            .frame(minWidth: style.iconOnly ? style.height : nil, maxWidth: style.block ? .infinity : nil)
            .frame(minHeight: style.height)     // grows with Dynamic Type instead of clipping the label
            .background(background(pressed: pressed), in: shape)
            .overlay { shape.strokeBorder(borderColor, lineWidth: 1) }
            // Icon-only `.sm` buttons look 30 × 30 but take touches in 40 × 40 (no overlap with a neighbour 10 pt away).
            .padding(hitOutset)
            .contentShape(Rectangle())
            .padding(-hitOutset)
            .opacity(isEnabled ? 1 : 0.5)
    }

    private var hitOutset: CGFloat { style.iconOnly && style.size == .sm ? 5 : 0 }

    private var foreground: Color {
        switch style.kind {
        case .plain, .ghost: Theme.ink1
        case .primary: Theme.accentInk
        case .danger: Theme.criticalText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch style.kind {
        case .plain, .danger: pressed ? Theme.surface2 : Theme.surface
        case .primary: pressed ? Theme.accentHover : Theme.accent
        case .ghost: pressed ? Theme.surface2 : Color.clear
        }
    }

    private var borderColor: Color {
        switch style.kind {
        case .plain, .danger: Theme.border
        case .primary: Theme.accent
        case .ghost: Color.clear
        }
    }
}

extension ButtonStyle where Self == NLButtonStyle {
    /// `.buttonStyle(.nl(.primary, size: .lg))`.
    static func nl(_ kind: NLButtonStyle.Kind = .plain, size: NLButtonStyle.Size = .md, block: Bool = false, iconOnly: Bool = false) -> NLButtonStyle {
        NLButtonStyle(kind: kind, size: size, block: block, iconOnly: iconOnly)
    }
}

// MARK: - Spinner (web `.spinner`): 18 pt ring, 2 pt `hair` track with an `accent` head, one turn per 0.8 s.

struct Spinner: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2
    var track: Color = Theme.hair
    var head: Color = Theme.accent

    init(size: CGFloat = 18, lineWidth: CGFloat = 2, track: Color = Theme.hair, head: Color = Theme.accent) {
        self.size = size
        self.lineWidth = lineWidth
        self.track = track
        self.head = head
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let turn = t.truncatingRemainder(dividingBy: 0.8) / 0.8
            ZStack {
                Circle().stroke(track, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(head, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360 - 135))
            }
            .padding(lineWidth / 2)
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pulse (web `.pulse`): opacity 1 → 0.45 → 1 over 1.6 s, repeating. Disabled with Reduce Motion.

private struct NLPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim && !reduceMotion ? 0.45 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

extension View {
    /// Pulsing opacity for "working…" hints (AI job progress, `正在识别…`).
    func nlPulse() -> some View { modifier(NLPulseModifier()) }
}

// MARK: - Previews

#Preview("Buttons") {
    DSPreviewSchemes {
        FlowLayout(spacing: 10) {
            Button("保存") {}.buttonStyle(.nl(.primary))
            Button("取消") {}.buttonStyle(.nl())
            Button("删除") {}.buttonStyle(.nl(.danger))
            Button {} label: { Label("表格", systemImage: "tablecells") }.buttonStyle(.nl(.ghost, size: .sm))
            Button {} label: { Image(systemName: "trash") }.buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
            Button {} label: { Label("AI 分析", systemImage: "sparkles") }.buttonStyle(.nl(.primary, size: .lg))
            Button("禁用") {}.buttonStyle(.nl(.primary)).disabled(true)
        }
        HStack(spacing: 14) {
            Spinner()
            Text(verbatim: "正在识别… 读取截图通常需要 20–60 秒").font(Theme.Font.small).foregroundStyle(Theme.ink3).nlPulse()
        }
    }
}
