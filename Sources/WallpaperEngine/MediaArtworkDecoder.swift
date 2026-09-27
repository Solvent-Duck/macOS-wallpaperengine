import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import NativeSceneRuntime

/// Bounded local normalization for encoded media artwork. Palette extraction is
/// deliberately deterministic rather than an attempt to reproduce Wallpaper
/// Engine's Windows color extraction.
enum MediaArtworkDecoder {
    static let maximumInputBytes = 8 * 1024 * 1024
    static let maximumSourcePixels = 64 * 1024 * 1024
    static let maximumSourceDimension = 32 * 1024
    static let maximumDimension = 1024

    static func decode(_ encoded: Data) -> SceneMediaState.Thumbnail? {
        guard !encoded.isEmpty, encoded.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              sourceDimensionsAreBounded(source),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let artwork = normalize(image)
        else { return nil }

        var thumbnail = SceneMediaState.Thumbnail()
        thumbnail.identifier = identifier(for: artwork)
        thumbnail.hasThumbnail = true
        thumbnail.artwork = artwork
        let palette = palette(for: artwork)
        thumbnail.primaryColor = palette.primary
        thumbnail.secondaryColor = palette.secondary
        thumbnail.tertiaryColor = palette.tertiary
        thumbnail.textColor = palette.text
        thumbnail.highContrastColor = palette.highContrast
        return thumbnail
    }

    private static var thumbnailOptions: [CFString: Any] {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode the bounded thumbnail, never a caller-requested full-size image.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
    }

    private static func sourceDimensionsAreBounded(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return false }
        let w = width.int64Value
        let h = height.int64Value
        guard w > 0, h > 0, w <= Int64(maximumSourceDimension), h <= Int64(maximumSourceDimension) else { return false }
        return w <= Int64(maximumSourcePixels) / h
    }

    private static func normalize(_ image: CGImage) -> SceneMediaArtwork? {
        let width = image.width
        let height = image.height
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              width <= Int.max / 4 / height
        else { return nil }
        let byteCount = width * height * 4
        var premultiplied = Data(count: byteCount)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rendered = premultiplied.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: colorSpace, bitmapInfo: bitmapInfo.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            // ImageIO has already applied EXIF orientation. Drawing a CGImage
            // directly into a bitmap preserves its top row in the first bytes;
            // applying an NSView-style Y flip here would invert the artwork.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        // CGContext stores premultiplied alpha. Consumers receive straight RGBA8;
        // transparent pixels have canonical zero RGB so identifiers are stable.
        var straight = premultiplied
        straight.withUnsafeMutableBytes { raw in
            let pixel = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: pixel.count, by: 4) {
                let alpha = Int(pixel[offset + 3])
                guard alpha > 0 else {
                    pixel[offset] = 0; pixel[offset + 1] = 0; pixel[offset + 2] = 0
                    continue
                }
                if alpha < 255 {
                    for component in 0..<3 {
                        pixel[offset + component] = UInt8(min(255, (Int(pixel[offset + component]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
        return SceneMediaArtwork(width: width, height: height, rgba8: straight)
    }

    private static func identifier(for artwork: SceneMediaArtwork) -> String {
        var input = Data()
        var width = UInt32(artwork.width).bigEndian
        var height = UInt32(artwork.height).bigEndian
        withUnsafeBytes(of: &width) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: &height) { input.append(contentsOf: $0) }
        input.append(artwork.rgba8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private struct Palette {
        let primary: RuntimeVector3
        let secondary: RuntimeVector3
        let tertiary: RuntimeVector3
        let text: RuntimeVector3
        let highContrast: RuntimeVector3
    }

    /// Samples at most 64x64 locations, ignores nearly transparent pixels, and
    /// ranks 4-bit RGB bins by population with numeric-bin tie breaking.
    private static func palette(for artwork: SceneMediaArtwork) -> Palette {
        struct Bin { var count = 0; var red = 0; var green = 0; var blue = 0 }
        var bins = Array(repeating: Bin(), count: 4096)
        let xStep = max(1, (artwork.width + 63) / 64)
        let yStep = max(1, (artwork.height + 63) / 64)
        artwork.rgba8.withUnsafeBytes { raw in
            let pixel = raw.bindMemory(to: UInt8.self)
            for y in stride(from: 0, to: artwork.height, by: yStep) {
                for x in stride(from: 0, to: artwork.width, by: xStep) {
                    let offset = (y * artwork.width + x) * 4
                    guard pixel[offset + 3] >= 16 else { continue }
                    let index = (Int(pixel[offset]) >> 4) << 8 | (Int(pixel[offset + 1]) >> 4) << 4 | (Int(pixel[offset + 2]) >> 4)
                    bins[index].count += 1
                    bins[index].red += Int(pixel[offset])
                    bins[index].green += Int(pixel[offset + 1])
                    bins[index].blue += Int(pixel[offset + 2])
                }
            }
        }
        let ranked = bins.indices.filter { bins[$0].count > 0 }.sorted {
            bins[$0].count == bins[$1].count ? $0 < $1 : bins[$0].count > bins[$1].count
        }
        func color(_ index: Int?) -> RuntimeVector3 {
            guard let index, bins[index].count > 0 else { return .zero }
            let bin = bins[index]
            let divisor = Float(bin.count * 255)
            return RuntimeVector3(x: Float(bin.red) / divisor, y: Float(bin.green) / divisor, z: Float(bin.blue) / divisor)
        }
        let primary = color(ranked.first)
        func separated(after selected: [RuntimeVector3]) -> Int? {
            ranked.first { candidate in
                let value = color(candidate)
                return selected.allSatisfy { other in
                    let dx = value.x - other.x, dy = value.y - other.y, dz = value.z - other.z
                    return dx * dx + dy * dy + dz * dz >= 0.0225
                }
            }
        }
        let secondary = color(separated(after: [primary]) ?? ranked.first)
        let tertiary = color(separated(after: [primary, secondary]) ?? ranked.first)
        // WCAG relative luminance requires linear sRGB, not gamma-encoded
        // channel averaging. Choose the actual higher contrast of black/white.
        let luminance = relativeLuminance(primary)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        let contrast: RuntimeVector3 = blackContrast >= whiteContrast ? .zero : .one
        return Palette(primary: primary, secondary: secondary, tertiary: tertiary, text: contrast, highContrast: contrast)
    }

    private static func relativeLuminance(_ color: RuntimeVector3) -> Double {
        func linear(_ channel: Float) -> Double {
            let value = min(1, max(0, Double(channel)))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }
}
