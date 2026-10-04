import SwiftUI

// MARK: - Banner (web1 §3.3, web2 §3.3): padding 12×14, radius 12, 13.5 pt, optional 18 pt leading icon.
// plain: surface-2 / ink-2; warn: warning-soft / warning-text; accent: accent-soft / accent-text.

struct Banner: View {
    enum Style: Hashable, Sendable {
        case plain, warn, accent
        var background: Color { switch self { case .plain: Theme.surface2; case .warn: Theme.warningSoft; case .accent: Theme.accentSoft } }
        var foreground: Color { switch self { case .plain: Theme.ink2; case .warn: Theme.warningText; case .accent: Theme.accentText } }
    }

    let text: String
    let icon: String?
    let style: Style

    init(_ text: String, icon: String? = nil, style: Style = .plain) {
        self.text = text
        self.icon = icon
        self.style = style
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            Text(text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .nlBanner(style)
        .accessibilityElement(children: .combine)
    }
}

private struct NLBannerModifier: ViewModifier {
    let style: Banner.Style
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.meter)
            .foregroundStyle(style.foreground)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.bannerRadius, style: .continuous))
    }
}

extension View {
    /// Banner chrome for custom content (column banners such as `AI 想确认：` or `下期行动`).
    func nlBanner(_ style: Banner.Style = .plain) -> some View { modifier(NLBannerModifier(style: style)) }
}

#Preview("Banner") {
    DSPreviewSchemes {
        Banner("记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考", icon: "info.circle", style: .warn)
        Banner("离线规则解析（未配置 AI），无法识别截图", icon: "sparkles", style: .accent)
        Banner("这一项来自食物库。修改具体数值后将按你填写的数值保存，不再与食物库条目关联。")
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "下期行动").fontWeight(.semibold)
            Label { Text(verbatim: "每天至少一份深绿色蔬菜") } icon: { Image(systemName: "arrow.up.right").font(.system(size: 13)) }
        }
        .nlBanner(.accent)
    }
}
