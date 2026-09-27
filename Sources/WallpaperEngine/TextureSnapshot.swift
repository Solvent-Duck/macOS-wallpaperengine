import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct ScreenshotReport: Codable {
    let width: Int
    let height: Int
    let black_frame: Bool
    /// True when the frame is effectively one solid color (catches broken
    /// renders that are white/gray instead of black).
    let flat_frame: Bool
    let luminance_mean: Double
    let luminance_stddev: Double
    let sampled_pixels: Int
    let black_pixels: Int
    let visible_pixels: Int
    /// Mean absolute per-channel difference against a second capture taken
    /// later in playback; nil when no comparison frame was captured.
    var animation_delta: Double?
    /// Runtime timeline values for the captured frame and its motion reference.
    var scene_elapsed_time: Double?
    var reference_scene_elapsed_time: Double?
    var rendered_frames: Int?
}

enum TextureSnapshotError: LocalizedError {
    case unsupportedPixelFormat(MTLPixelFormat)
    case bufferAllocationFailed
    case commandBufferFailed
    case imageCreationFailed
    case destinationCreationFailed
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let format):
            return "Unsupported screenshot pixel format: \(format.rawValue)"
        case .bufferAllocationFailed:
            return "Failed to allocate a staging buffer for screenshot capture."
        case .commandBufferFailed:
            return "Failed to create a Metal command buffer for screenshot capture."
        case .imageCreationFailed:
            return "Failed to build a CGImage from the captured Metal texture."
        case .destinationCreationFailed:
            return "Failed to create a PNG image destination."
        case .finalizeFailed:
            return "Failed to finalize the PNG screenshot."
        }
    }
}

enum TextureSnapshot {
    static func writePNG(from texture: MTLTexture, using commandQueue: MTLCommandQueue, to url: URL) throws -> ScreenshotReport {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .rgba8Unorm else {
            throw TextureSnapshotError.unsupportedPixelFormat(texture.pixelFormat)
        }

        guard let staging = texture.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw TextureSnapshotError.bufferAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw TextureSnapshotError.commandBufferFailed
        }

        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: staging,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let source = staging.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        defer { rgba.deallocate() }

        for row in 0..<height {
            let srcRow = source.advanced(by: row * bytesPerRow)
            let dstRow = rgba.advanced(by: row * bytesPerRow)

            for column in 0..<width {
                let src = srcRow.advanced(by: column * 4)
                let dst = dstRow.advanced(by: column * 4)

                if texture.pixelFormat == .bgra8Unorm {
                    dst[0] = src[2]
                    dst[1] = src[1]
                    dst[2] = src[0]
                    dst[3] = src[3]
                } else {
                    dst[0] = src[0]
                    dst[1] = src[1]
                    dst[2] = src[2]
                    dst[3] = src[3]
                }
            }
        }

        let data = Data(bytes: rgba, count: bytesPerRow * height)
        let provider = CGDataProvider(data: data as CFData)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        guard let provider,
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TextureSnapshotError.imageCreationFailed
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw TextureSnapshotError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TextureSnapshotError.finalizeFailed
        }

        return blackFrameReport(from: rgba, width: width, height: height)
    }

    private static func blackFrameReport(from rgba: UnsafePointer<UInt8>, width: Int, height: Int) -> ScreenshotReport {
        let nearBlackThreshold: UInt8 = 10
        let visibleContentThreshold: UInt8 = 32
        let visibleContentRatioThreshold = 0.0005

        var blackCount = 0
        var visibleCount = 0
        var luminanceSum = 0.0
        var luminanceSquaredSum = 0.0
        let sampleCount = width * height

        for y in 0..<height {
            for x in 0..<width {
                let pixel = rgba.advanced(by: (y * width + x) * 4)
                let maxChannel = max(pixel[0], max(pixel[1], pixel[2]))

                if pixel[0] < nearBlackThreshold && pixel[1] < nearBlackThreshold && pixel[2] < nearBlackThreshold {
                    blackCount += 1
                }

                if maxChannel >= visibleContentThreshold {
                    visibleCount += 1
                }

                let luminance = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
                luminanceSum += luminance
                luminanceSquaredSum += luminance * luminance
            }
        }

        let blackRatio = Double(blackCount) / Double(max(sampleCount, 1))
        let visibleRatio = Double(visibleCount) / Double(max(sampleCount, 1))
        let mean = luminanceSum / Double(max(sampleCount, 1))
        let variance = max(luminanceSquaredSum / Double(max(sampleCount, 1)) - mean * mean, 0)
        let stddev = variance.squareRoot()

        return ScreenshotReport(
            width: width,
            height: height,
            black_frame: blackRatio > 0.95 && visibleRatio < visibleContentRatioThreshold,
            flat_frame: stddev < 2.0,
            luminance_mean: mean,
            luminance_stddev: stddev,
            sampled_pixels: sampleCount,
            black_pixels: blackCount,
            visible_pixels: visibleCount,
            animation_delta: nil
        )
    }

    /// Mean absolute per-channel difference between two RGBA8 textures of the
    /// same size, used to prove animations advance between captures.
    static func meanAbsoluteDifference(
        _ first: MTLTexture,
        _ second: MTLTexture,
        using commandQueue: MTLCommandQueue
    ) -> Double? {
        let width = first.width
        let height = first.height
        guard width == second.width, height == second.height else {
            return nil
        }
        let bytesPerRow = width * 4
        let length = bytesPerRow * height
        guard let bufferA = first.device.makeBuffer(length: length, options: .storageModeShared),
              let bufferB = first.device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        for (texture, buffer) in [(first, bufferA), (second, bufferB)] {
            blit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: length
            )
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesA = bufferA.contents().bindMemory(to: UInt8.self, capacity: length)
        let bytesB = bufferB.contents().bindMemory(to: UInt8.self, capacity: length)
        var total = 0.0
        // Sample every 4th pixel for speed; plenty for a motion signal.
        var sampled = 0
        var offset = 0
        while offset < length {
            total += Double(abs(Int(bytesA[offset]) - Int(bytesB[offset])))
            total += Double(abs(Int(bytesA[offset + 1]) - Int(bytesB[offset + 1])))
            total += Double(abs(Int(bytesA[offset + 2]) - Int(bytesB[offset + 2])))
            sampled += 3
            offset += 16
        }
        return sampled > 0 ? total / Double(sampled) : nil
    }
}
