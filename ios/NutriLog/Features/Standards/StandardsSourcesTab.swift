import SwiftUI

// MARK: - Tab `sources` 资料来源 (web2 §5.10, rep §9.7; data `meta.sources`, 36 entries)
// A list: `year` chip (min width 60, centred), the title in weight 600 (a link when `url` is non-empty, opened in
// Safari), then `org` (small, muted). Linked rows are tappable as a whole. The chip column is as wide as the widest
// chip (e.g. `1997–2023`), so every title starts at the same x.

struct StandardsSourcesTab: View {
    let meta: Meta

    var body: some View {
        let sources = meta.sources
        let widestYear = sources.map(\.year).max { $0.count < $1.count } ?? ""
        Card {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    StandardsSourceRow(source: source, widestYear: widestYear)
                    if index < sources.count - 1 {
                        Rectangle().fill(Theme.hair).frame(height: 1).accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

private struct StandardsSourceRow: View {
    let source: SourceDef
    let widestYear: String

    private var url: URL? {
        guard !source.url.isEmpty else { return nil }
        return URL(string: source.url)
    }

    var body: some View {
        if let url {
            Link(destination: url) {
                content(linked: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: source.url))
        } else {
            content(linked: false)
        }
    }

    private func content(linked: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .leading) {
                yearChip(widestYear).hidden().accessibilityHidden(true)
                yearChip(source.year)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(linked ? Theme.accentText : Theme.ink1)
                Text(source.org)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if linked {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func yearChip(_ year: String) -> some View {
        Text(year)
            .font(Theme.Font.chip)
            .foregroundStyle(Theme.ink2)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .frame(minWidth: 60)
            .background(Theme.surface2, in: Capsule())
            .fixedSize()
    }
}
