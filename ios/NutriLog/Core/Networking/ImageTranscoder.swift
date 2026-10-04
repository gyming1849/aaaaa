import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Images (meals §2.1: the server accepts JPEG/PNG/WebP/GIF only, never HEIC)

/// Converts any image to an upload-ready JPEG: long edge ≤ `maxPixel`, quality 0.8, EXIF orientation applied to the pixels,
/// metadata (GPS, camera) dropped. Pure functions, safe to call off the main actor.
enum ImageTranscoder {
    /// Any ImageIO-readable image (HEIC/PNG/JPEG…) → JPEG, long edge ≤ maxPixel, EXIF orientation applied.
    static func jpeg(from data: Data, maxPixel: Int = 2048, quality: Double = 0.8) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let image = downsampled(source, maxPixel: maxPixel) else { return nil }
        return encode(image, quality: quality)
    }

    /// Camera / in-memory image → JPEG. `imageOrientation` is baked into the pixels.
    static func jpeg(from image: UIImage, maxPixel: Int = 2048, quality: Double = 0.8) -> Data? {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let longEdge = max(pixelSize.width, pixelSize.height)
        let factor = min(1, CGFloat(max(1, maxPixel)) / longEdge)
        let target = CGSize(width: max(1, (pixelSize.width * factor).rounded()), height: max(1, (pixelSize.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let clamped = min(1, max(0, quality))
        let data = renderer.jpegData(withCompressionQuality: clamped) { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))   // draw(in:) honours imageOrientation
        }
        return data.isEmpty ? nil : data
    }

    /// Decoded, orientation-corrected thumbnail for display. `maxPixel` bounds the long edge; with `fill`, the short edge
    /// is made at least `maxPixel` instead (for aspect-fill tiles such as `RemotePhoto`), never beyond the original size.
    static func thumbnail(from data: Data, maxPixel: Int, fill: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var limit = max(1, maxPixel)
        if fill, let (w, h) = pixelSize(source), min(w, h) > 0 {
            let scaled = (Double(limit) * Double(max(w, h)) / Double(min(w, h))).rounded(.up)
            limit = Int(min(scaled, Double(max(w, h))))
        }
        return downsampled(source, maxPixel: limit)
    }

    // MARK: Internals

    private static func pixelSize(_ source: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    private static func downsampled(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        var limit = max(1, maxPixel)
        if let (w, h) = pixelSize(source) { limit = min(limit, max(w, h)) }   // never upscale
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))] as [CFString: Any] as CFDictionary
        CGImageDestinationAddImage(dest, opaque(image) ?? image, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// JPEG has no alpha: flatten transparent images (PNG screenshots, stickers) onto white instead of black.
    private static func opaque(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
