import CoreGraphics
import Foundation
import ImageIO
import NativeSceneRuntime
import Testing
import UniformTypeIdentifiers
@testable import WallpaperEngine

struct MediaArtworkDecoderTests {
    @Test func normalizesOrientationAlphaAndTopRowOrder() throws {
        // The source is asymmetric: rotating it must change 2x3 into 3x2.
        // The translucent red source pixel is premultiplied (128, 0, 0, 128).
        let source = try encodedImage(
            width: 2, height: 3,
            rgba: [
                128, 0, 0, 128, 0, 255, 0, 255,
                0, 0, 255, 255, 255, 255, 0, 255,
                0, 255, 255, 255, 255, 0, 255, 255,
            ],
            type: .tiff,
            orientation: 6
        )
        let thumbnail = try #require(MediaArtworkDecoder.decode(source))
        let artwork = try #require(thumbnail.artwork)
        #expect((artwork.width, artwork.height) == (3, 2))
        #expect(thumbnail.hasThumbnail)
        // Source orientation 6 rotates clockwise, so the original bottom-left
        // cyan pixel is now the first top-row pixel.
        #expect(Array(artwork.rgba8.prefix(4)) == [0, 255, 255, 255])
        // The original translucent red top-left pixel rotates to the top-right.
        // Its RGB is straight (not premultiplied) in the decoder output.
        let translucentRed = Array(artwork.rgba8[8..<12])
        #expect(translucentRed[3] == 128)
        #expect(abs(Int(translucentRed[0]) - 255) <= 1)
        #expect(translucentRed[1] == 0 && translucentRed[2] == 0)
        #expect(artwork.rgba8.count == artwork.width * artwork.height * 4)
    }

    @Test func acceptsColorProfileAndExtractsDeterministicSolidPalette() throws {
        let input = try encodedImage(
            width: 16, height: 16,
            rgba: Array(repeating: [32, 96, 224, 255], count: 256).flatMap { $0 },
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            type: .png
        )
        let first = try #require(MediaArtworkDecoder.decode(input))
        let second = try #require(MediaArtworkDecoder.decode(input))
        #expect(first.identifier == second.identifier)
        #expect(first.artwork == second.artwork)
        let expected = try expectedSRGB(displayP3: [32, 96, 224])
        let tolerance = Float(2.5 / 255.0) // color-management and RGBA8 rounding
        #expect(abs(first.primaryColor.x - expected.x) <= tolerance)
        #expect(abs(first.primaryColor.y - expected.y) <= tolerance)
        #expect(abs(first.primaryColor.z - expected.z) <= tolerance)
        #expect(first.textColor == .one)
        #expect(first.highContrastColor == .one)
    }

    @Test func textColorsUseHigherLinearSRGBContrastForMidgrayAndRed() throws {
        let midgray = try #require(MediaArtworkDecoder.decode(try encodedImage(
            width: 8, height: 8, rgba: Array(repeating: [128, 128, 128, 255], count: 64).flatMap { $0 }
        )))
        let red = try #require(MediaArtworkDecoder.decode(try encodedImage(
            width: 8, height: 8, rgba: Array(repeating: [220, 0, 0, 255], count: 64).flatMap { $0 }
        )))
        #expect(midgray.textColor == .zero && midgray.highContrastColor == .zero)
        #expect(red.textColor == .one && red.highContrastColor == .one)
        #expect(contrastRatio(midgray.primaryColor, midgray.textColor) >= 4.5)
        #expect(contrastRatio(red.primaryColor, red.textColor) >= 4.5)
    }

    @Test func boundsAmodestOversizedArtworkWhilePreservingAspect() throws {
        let width = 1301
        let height = 651
        let input = try encodedImage(
            width: width, height: height,
            rgba: Array(repeating: [20, 120, 220, 255], count: width * height).flatMap { $0 }
        )
        let artwork = try #require(MediaArtworkDecoder.decode(input)?.artwork)
        #expect(max(artwork.width, artwork.height) <= MediaArtworkDecoder.maximumDimension)
        #expect(abs(Double(artwork.width) / Double(artwork.height) - Double(width) / Double(height)) < 0.01)
    }

    @Test func rejectsMalformedAndOversizedEncodedInput() {
        #expect(MediaArtworkDecoder.decode(Data([0, 1, 2, 3])) == nil)
        #expect(MediaArtworkDecoder.decode(Data(repeating: 0, count: MediaArtworkDecoder.maximumInputBytes + 1)) == nil)
    }

    @Test func identityDependsOnNormalizedPixelsAndDimensions() throws {
        let blue = try encodedImage(width: 3, height: 2, rgba: Array(repeating: [0, 0, 220, 255], count: 6).flatMap { $0 })
        let red = try encodedImage(width: 3, height: 2, rgba: Array(repeating: [220, 0, 0, 255], count: 6).flatMap { $0 })
        let sameBlue = try #require(MediaArtworkDecoder.decode(blue))
        let againBlue = try #require(MediaArtworkDecoder.decode(blue))
        let decodedRed = try #require(MediaArtworkDecoder.decode(red))
        #expect(sameBlue.identifier == againBlue.identifier)
        #expect(sameBlue.identifier != decodedRed.identifier)
        #expect(sameBlue.artwork?.rgba8 != decodedRed.artwork?.rgba8)
    }

    private func expectedSRGB(displayP3 components: [CGFloat]) throws -> RuntimeVector3 {
        let source = try #require(CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            components: [components[0] / 255, components[1] / 255, components[2] / 255, 1]
        ))
        let converted = try #require(source.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ))
        let channels = try #require(converted.components)
        func clamp(_ index: Int) -> Float { Float(min(1, max(0, channels[index]))) }
        return RuntimeVector3(x: clamp(0), y: clamp(1), z: clamp(2))
    }

    private func contrastRatio(_ color: RuntimeVector3, _ foreground: RuntimeVector3) -> Double {
        func linear(_ value: Float) -> Double {
            let channel = Double(value)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let background = 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
        let foregroundLuminance = foreground == .one ? 1.0 : 0.0
        return (max(background, foregroundLuminance) + 0.05) / (min(background, foregroundLuminance) + 0.05)
    }

    private func encodedImage(
        width: Int,
        height: Int,
        rgba: [UInt8],
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        type: UTType = .png,
        orientation: Int? = nil
    ) throws -> Data {
        #expect(rgba.count == width * height * 4)
        let bytes = Data(rgba)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
