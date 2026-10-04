import SwiftUI

// MARK: - Card (web2 §3.3 `.card`): surface background, 1 pt border, radius 14, padding 16 on phones, soft shadow.

/// A content card. Children are stacked vertically (leading, 14 pt apart, the web's card-head margin);
/// wrap them in your own `VStack` when you need different spacing.
struct Card<Content: View>: View {
    let padding: CGFloat
    let content: Content
    /// Background fill. `ImpactPreviewCard` uses `surface-2` (`card flat`).
    var background: Color = Theme.surface
    /// `card flat`: no shadow.
    var flat: Bool = false

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                if flat {
                    shape.fill(background)
                } else {
                    shape.fill(background)
                        .shadow(color: Theme.shadow1, radius: 1, x: 0, y: 1)
                        .shadow(color: Theme.shadow2, radius: 8, x: 0, y: 4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }

    /// Returns a copy with another background and/or without shadow (`card flat`).
    func cardStyle(background: Color = Theme.surface, flat: Bool = false) -> Card {
        var copy = self
        copy.background = background
        copy.flat = flat
        return copy
    }
}

// MARK: - CardHeader (`.card-head`): title (h2/h3 with optional leading icon) on the left; hint on the right,
// or wrapped under the title when it does not fit (12.5 pt, ink-3); optional trailing controls.

struct CardHeader<Trailing: View>: View {
    enum Level: Sendable { case h2, h3 }

    let title: String
    let icon: String?
    let hint: String?
    let trailing: Trailing
    /// Heading size; `.h2` (18) by default, `.h3` (15) for chart cards and the merge preview.
    var level: Level = .h2

    init(_ title: String, icon: String? = nil, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.hint = hint
        self.trailing = trailing()
    }

    /// Returns a copy using another heading level.
    func headingLevel(_ level: Level) -> CardHeader {
        var copy = self
        copy.level = level
        return copy
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Wide: title … hint trailing
            HStack(alignment: .center, spacing: 12) {
                titleView.fixedSize()
                Spacer(minLength: 6)
                if let hint { hintView(hint).fixedSize() }
                trailing
            }
            // Narrow: hint wraps under the title
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    titleView
                    Spacer(minLength: 6)
                    trailing
                }
                if let hint { hintView(hint) }
            }
        }
    }

    private var titleView: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: level == .h2 ? 17 : 14, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(level == .h2 ? Theme.Font.h2 : Theme.Font.h3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func hintView(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.hint)
            .foregroundStyle(Theme.ink3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, hint: String? = nil) {
        self.init(title, icon: icon, hint: hint) { EmptyView() }
    }
}

// MARK: - Previews

#Preview("Card") {
    DSPreviewSchemes {
        Card {
            CardHeader("心血管健康 Life's Essential 8", icon: "heart.text.square", hint: "美国心脏协会 2022 · 近 7 天")
            Text(verbatim: "卡片内容，正文 15 pt。").font(Theme.Font.body).foregroundStyle(Theme.ink1)
        }
        Card {
            CardHeader("能量平衡", icon: "flame", hint: "静息 来自设备 · 活动：手机/手表活动能量") {
                Button("填写") {}.buttonStyle(.nl(.plain, size: .sm))
            }
            Text(verbatim: "1,568 kcal").font(Theme.Font.statValue).foregroundStyle(Theme.ink)
        }
        Card {
            CardHeader("合并预览", hint: "确认前不会写入；数值随修改实时更新").headingLevel(.h3)
            Text(verbatim: "flat · surface-2").font(Theme.Font.small).foregroundStyle(Theme.ink2)
        }
        .cardStyle(background: Theme.surface2, flat: true)
    }
}
