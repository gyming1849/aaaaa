import SwiftUI

/// Preview helper: renders the same content twice, light then dark, each on its own `page` background,
/// so every `#Preview` shows both colour schemes (WP0-C "done when").
struct DSPreviewSchemes<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                pane(.light)
                pane(.dark)
            }
        }
        .background(Theme.page)
    }

    private func pane(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) { content }
            .padding(Theme.Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.page)
            .environment(\.colorScheme, scheme)
    }
}
