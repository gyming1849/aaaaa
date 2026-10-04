import SwiftUI

// MARK: - Seg (web2 §3.3 `.seg`): surface-2 track, radius 10, padding 3, 2 pt gaps; items 13.5 pt weight 550 ink-2,
// padding 6×12, radius 8; the selected item is surface with a shadow and ink text. Stays on one line when it fits (item
// padding 12, then 8 on a narrow phone, so the 7 Trends ranges do not leave 自定义 alone on a second row) and only
// then wraps onto several lines, so it is a custom control, not `Picker(.segmented)`.

struct SegOption<T: Hashable>: Hashable {
    let value: T
    let label: String
    var icon: String? = nil
}

struct Seg<T: Hashable>: View {
    let options: [SegOption<T>]
    @Binding var selection: T

    init(_ options: [SegOption<T>], selection: Binding<T>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            track(HStack(spacing: 2) { segments(horizontalPadding: 12) })
            track(HStack(spacing: 2) { segments(horizontalPadding: 8) })
            track(FlowLayout(spacing: 2, lineSpacing: 2) { segments(horizontalPadding: 12) })
        }
        .animation(.easeOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
    }

    private func track(_ content: some View) -> some View {
        content
            .padding(3)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
    }

    private func segments(horizontalPadding: CGFloat) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            segment(option, horizontalPadding: horizontalPadding)
        }
    }

    private func segment(_ option: SegOption<T>, horizontalPadding: CGFloat) -> some View {
        let on = option.value == selection
        return Button {
            selection = option.value
        } label: {
            HStack(spacing: 5) {
                if let icon = option.icon {
                    Image(systemName: icon).font(.system(size: 13)).accessibilityHidden(true)
                }
                Text(option.label).lineLimit(1)
            }
            .font(Theme.Font.segment)
            .foregroundStyle(on ? Theme.ink : Theme.ink2)
            .padding(.vertical, 6)
            .padding(.horizontal, horizontalPadding)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surface)
                        .shadow(color: Theme.shadow1, radius: 1, x: 0, y: 1)
                        .shadow(color: Theme.shadow2, radius: 8, x: 0, y: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

private struct SegPreview: View {
    @State private var range = "30"
    @State private var kind = "week"
    @State private var theme = ThemePreference.system
    var body: some View {
        Seg([("7", "7 天"), ("30", "30 天"), ("90", "90 天"), ("year", "今年"), ("365", "一年"), ("all", "全部"), ("custom", "自定义")]
                .map { SegOption(value: $0.0, label: $0.1) }, selection: $range)
        Seg([SegOption(value: "week", label: "周报"), SegOption(value: "month", label: "月报")], selection: $kind)
        Seg(ThemePreference.allCases.map { SegOption(value: $0, label: $0.title, icon: $0.symbol) }, selection: $theme)
    }
}

#Preview("Seg") {
    DSPreviewSchemes { SegPreview() }
}
