import SwiftUI

// MARK: - Chip (web1 §3.3, web2 §3.3): capsule, padding 3×10, 12.5 pt, surface-2 / ink-2.
// Variants: accent (accent-soft / accent-text), selected (accent / accent-ink) and the IARC colours
// (1 critical, 2A serious, 2B warning; anything else falls back to the plain chip).

struct Chip: View {
    enum Style: Equatable {
        case plain, accent, selected, iarc(String)

        var background: Color {
            switch self {
            case .plain: Theme.surface2
            case .accent: Theme.accentSoft
            case .selected: Theme.accent
            case .iarc(let g):
                switch g {
                case "1": Theme.criticalSoft
                case "2A": Theme.seriousSoft
                case "2B": Theme.warningSoft
                default: Theme.surface2
                }
            }
        }

        var foreground: Color {
            switch self {
            case .plain: Theme.ink2
            case .accent: Theme.accentText
            case .selected: Theme.accentInk
            case .iarc(let g):
                switch g {
                case "1": Theme.criticalText
                case "2A": Theme.seriousText
                case "2B": Theme.warningText
                default: Theme.ink2
                }
            }
        }
    }

    let text: String
    let icon: String?
    let style: Style
    /// Trailing "×" (e.g. the item editor's hazard chips, aria `移除该风险标记`).
    private var removal: (label: String, action: @MainActor () -> Void)?

    init(_ text: String, icon: String? = nil, style: Style = .plain) {
        self.text = text
        self.icon = icon
        self.style = style
    }

    /// Adds a small trailing "×" button with the given accessibility label.
    func removable(label: String, action: @escaping @MainActor () -> Void) -> Chip {
        var copy = self
        copy.removal = (label, action)
        return copy
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(Theme.Font.chip)
                .lineLimit(1)
            if let removal {
                Button(action: removal.action) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(removal.label))
            }
        }
        .foregroundStyle(style.foreground)
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
        .background(style.background, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: removal == nil ? .combine : .contain)
    }
}

/// `IarcChip(group)`: `—` → neutral `非致癌`; otherwise `IARC {group} 类` in the group's colours.
struct IarcChip: View {
    let group: String
    init(_ group: String) { self.group = group }
    var body: some View {
        Chip(Vocab.iarcLabel(group), style: group == "—" ? .plain : .iarc(group))
    }
}

#Preview("Chip") {
    DSPreviewSchemes {
        FlowLayout(spacing: 8) {
            Chip("1 份 · 200 g")
            Chip("食物库", icon: "books.vertical", style: .accent)
            Chip("1 份", style: .selected)
            Chip("NOVA 4 · 超加工")
            Chip("加工肉 35 g", icon: "exclamationmark.shield", style: .iarc("1"))
            Chip("高温烹调肉类", icon: "exclamationmark.shield", style: .iarc("2A")).removable(label: "移除该风险标记") {}
            IarcChip("1")
            IarcChip("2A")
            IarcChip("2B")
            IarcChip("—")
        }
    }
}
