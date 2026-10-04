import SwiftUI

// MARK: - SourceLinks (web1 §3.3, web2 §3.4): small muted `依据：` followed by each resolved source's `org`, joined by `、`.
// Each name links to `source.url` (opened in Safari) when it has one. Unknown ids are dropped; nothing renders if none resolve.

struct SourceLinks: View {
    let ids: [String]
    let sources: [SourceDef]

    init(ids: [String], sources: [SourceDef]) {
        self.ids = ids
        self.sources = sources
    }

    /// The `meta.sources` entries for `ids`, in `ids` order.
    static func resolve(_ ids: [String], in sources: [SourceDef]) -> [SourceDef] {
        ids.compactMap { id in sources.first { $0.id == id } }
    }

    var body: some View {
        let list = Self.resolve(ids, in: sources)
        if !list.isEmpty {
            Text(Self.attributed(list))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink3)
                .tint(Theme.accentText)
                .multilineTextAlignment(.leading)
        }
    }

    static func attributed(_ list: [SourceDef]) -> AttributedString {
        var s = AttributedString("依据：")
        for (i, src) in list.enumerated() {
            if i > 0 { s += AttributedString("、") }
            var part = AttributedString(src.org)
            if !src.url.isEmpty, let url = URL(string: src.url) {
                part.link = url
                part.foregroundColor = Theme.accentText
            }
            s += part
        }
        return s
    }
}

#Preview("SourceLinks") {
    DSPreviewSchemes {
        SourceLinks(ids: ["iarc_mono", "wcrf2018", "unknown", "system"], sources: DSPreviewData.sources)
        SourceLinks(ids: ["nope"], sources: DSPreviewData.sources)
    }
}
