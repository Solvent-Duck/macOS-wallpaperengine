import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers

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
    static func writePNG(from texture: MTLTexture, using commandQueue: MTLCommandQueue, to url: URL) throws {
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
            let flippedRow = height - 1 - row
            let srcRow = source.advanced(by: row * bytesPerRow)
            let dstRow = rgba.advanced(by: flippedRow * bytesPerRow)

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
    }
}
