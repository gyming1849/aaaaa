import SwiftUI
import UIKit

// MARK: - Authenticated thumbnail (meals §2.2; AsyncImage cannot send the Bearer header)

/// A square, rounded thumbnail of an uploaded photo, loaded through `PhotoCache` with the app token.
/// Shows a spinner while loading and a neutral placeholder when the photo is missing (404) or unreadable.
/// Only the owner's photos resolve, so member views never render photos (rep §1).
struct RemotePhoto: View {
    @Environment(AppState.self) private var app
    @Environment(\.displayScale) private var displayScale
    let photoId: String
    let side: CGFloat
    @State private var image: UIImage?
    @State private var failed = false

    init(photoId: String, side: CGFloat = 72) { self.photoId = photoId; self.side = side }

    var body: some View {
        ZStack {
            Theme.surface2
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: max(12, side * 0.3)))
                    .foregroundStyle(Theme.ink3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已上传的照片")
        .task(id: photoId) { await load() }
    }

    private func load() async {
        image = nil
        failed = false
        do {
            let data = try await PhotoCache.shared.data(for: photoId, api: app.api)
            let pixels = Int((side * max(1, displayScale)).rounded(.up))
            guard let decoded = await Self.decode(data, maxPixel: pixels) else { failed = true; return }
            image = decoded
        } catch is CancellationError {
            // view went away
        } catch {
            failed = true
        }
    }

    /// Off the main actor: decode a downsampled, orientation-corrected bitmap.
    nonisolated private static func decode(_ data: Data, maxPixel: Int) async -> UIImage? {
        guard let cg = ImageTranscoder.thumbnail(from: data, maxPixel: max(1, maxPixel), fill: true) else { return nil }
        return UIImage(cgImage: cg)
    }
}
