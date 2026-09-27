import Compression
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import NativeSceneCore

/// A decoded Wallpaper Engine texture plus the metadata shaders need.
struct DecodedWETexture {
    let texture: MTLTexture
    /// WE `g_TextureNResolution` semantics: (storage width, storage height,
    /// real image width, real image height). Storage is usually
    /// power-of-two padded, so shaders scale UVs by zw/xy.
    let resolution: SIMD4<Float>
    /// TextureFlags bit 1: sample with clamp-to-edge instead of repeat.
    let clampUVs: Bool
    /// TextureFlags bit 0: sample with nearest filtering.
    let pointSampling: Bool
}

/// An animated `.tex` whose payload is an embedded MP4 movie; the caller
/// plays it back frame-by-frame instead of uploading static pixels.
struct WETexVideoPayload {
    let data: Data
    /// Real image size from the TEXV header (0 when unspecified).
    let imageWidth: Int
    let imageHeight: Int
    let clampUVs: Bool
    let pointSampling: Bool
}

enum WETexContents {
    case texture(DecodedWETexture)
    case video(WETexVideoPayload)
}

/// Decodes Wallpaper Engine's proprietary `.tex` texture format
/// (TEXV0005/TEXI0001 header, TEXB0001–0004 containers), matching the
/// reference parser in linux-wallpaperengine's TextureParser.
///
/// Supports LZ4-compressed payloads, embedded image files (PNG/JPEG/GIF),
/// embedded MP4 movies (animated textures), and the common raw GPU formats
/// (RGBA8888, DXT1/3/5, RG88, R8).
enum WETexDecoder {

    // MARK: - Public API

    static func decode(url: URL, device: MTLDevice) -> DecodedWETexture? {
        guard case .texture(let decoded)? = contents(url: url, device: device) else {
            return nil
        }
        return decoded
    }

    static func contents(url: URL, device: MTLDevice, imageIndex: Int = 0) -> WETexContents? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return contents(data: data, device: device, imageIndex: imageIndex)
    }

    static func contents(data: Data, device: MTLDevice, imageIndex: Int = 0) -> WETexContents? {
        var reader = BinaryReader(data: data)

        guard reader.readString(length: 9) == "TEXV0005",
              reader.readString(length: 9) == "TEXI0001",
              reader.canRead(28) else {
            return nil
        }

        let format = reader.readUInt32()
        let flags = reader.readUInt32()
        let clampUVs = (flags & 2) != 0
        let pointSampling = (flags & 1) != 0
        let textureWidth = Int(reader.readUInt32())
        let textureHeight = Int(reader.readUInt32())
        let imageWidth = Int(reader.readUInt32())
        let imageHeight = Int(reader.readUInt32())
        _ = reader.readUInt32()                 // unused

        guard let containerMagic = reader.readString(length: 9) else {
            return nil
        }

        var containerVersion = 0
        var freeImageFormat: Int32 = -1
        var declaredVideo = false
        let imageCount = reader.readUInt32()
        guard imageIndex >= 0, imageIndex < imageCount else { return nil }

        switch containerMagic {
        case "TEXB0004":
            freeImageFormat = Int32(bitPattern: reader.readUInt32())
            declaredVideo = reader.readUInt32() == 1
            // Non-video TEXB0004 uses the TEXB0003 mipmap layout (no extra
            // editor fields), matching the reference parser.
            containerVersion = 3
        case "TEXB0003":
            containerVersion = 3
            freeImageFormat = Int32(bitPattern: reader.readUInt32())
        case "TEXB0002":
            containerVersion = 2
        case "TEXB0001":
            containerVersion = 1
        default:
            return nil
        }

        // Every page contains its own mip chain. Select by the frame's image
        // index instead of always uploading page zero of a packed animation.
        for _ in 0..<imageIndex {
            guard reader.canRead(4) else { return nil }
            let count = reader.readUInt32()
            guard count > 0, count <= data.count / 12 else { return nil }
            for _ in 0..<count {
                guard reader.canRead(containerVersion >= 2 ? 20 : 12) else { return nil }
                _ = reader.readBytes(count: containerVersion >= 2 ? 16 : 8)
                let length = Int(reader.readUInt32())
                guard reader.canRead(length) else { return nil }
                _ = reader.readBytes(count: length)
            }
        }
        guard reader.canRead(containerVersion >= 2 ? 24 : 16) else { return nil }
        let mipmapCount = reader.readUInt32()
        guard mipmapCount > 0 else { return nil }

        let mipWidth = Int(reader.readUInt32())
        let mipHeight = Int(reader.readUInt32())

        var compression: UInt32 = 0
        var uncompressedSize = 0
        if containerVersion >= 2 {
            compression = reader.readUInt32()
            uncompressedSize = Int(reader.readInt32())
        }

        let compressedSize = Int(reader.readInt32())
        guard compressedSize > 0, reader.canRead(compressedSize) else {
            return nil
        }
        let payload = reader.readBytes(count: compressedSize)

        let imageBytes: Data
        if compression == 1 {
            guard uncompressedSize > 0,
                  let decompressed = lz4Decompress(payload, uncompressedSize: uncompressedSize) else {
                return nil
            }
            imageBytes = decompressed
        } else {
            imageBytes = payload
        }

        // Animated textures embed a whole MP4 movie as the payload. The
        // TEXB0004 isVideo flag is unreliable (real workshop files carry
        // MP4 data with the flag clear, in TEXB0003 too), so sniff the
        // container magic instead.
        if looksLikeMP4File(imageBytes) {
            return .video(WETexVideoPayload(
                data: imageBytes,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                clampUVs: clampUVs,
                pointSampling: pointSampling
            ))
        }
        if declaredVideo {
            return nil                           // video container without recognizable MP4 payload
        }

        // Embedded image file (JPEG/PNG/GIF/...) when a FreeImage format is
        // declared or the payload carries a known magic.
        if freeImageFormat != -1 || looksLikeImageFile(imageBytes) {
            guard let texture = textureFromImageData(imageBytes, device: device) else {
                return nil
            }
            return .texture(DecodedWETexture(
                texture: texture,
                resolution: SIMD4<Float>(
                    Float(texture.width),
                    Float(texture.height),
                    Float(imageWidth > 0 ? imageWidth : texture.width),
                    Float(imageHeight > 0 ? imageHeight : texture.height)
                ),
                clampUVs: clampUVs,
                pointSampling: pointSampling
            ))
        }

        // Raw GPU pixel data in the header-declared format. Storage is
        // power-of-two padded; crop to the real image so plain 0..1 UVs
        // sample content instead of padding (matching file-image textures).
        let animated = TextureAnimation.decode(data) != nil
        let realWidth = !animated && imageWidth > 0 ? min(imageWidth, mipWidth) : mipWidth
        let realHeight = !animated && imageHeight > 0 ? min(imageHeight, mipHeight) : mipHeight
        guard let texture = textureFromRawPixels(
            imageBytes,
            format: format,
            width: mipWidth,
            height: mipHeight,
            cropWidth: realWidth,
            cropHeight: realHeight,
            device: device
        ) else {
            return nil
        }
        return .texture(DecodedWETexture(
            texture: texture,
            resolution: SIMD4<Float>(
                Float(texture.width),
                Float(texture.height),
                Float(realWidth),
                Float(realHeight)
            ),
            clampUVs: clampUVs,
            pointSampling: pointSampling
        ))
    }

    // MARK: - Payload decoding

    private static func lz4Decompress(_ data: Data, uncompressedSize: Int) -> Data? {
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { outputPointer -> Int in
            data.withUnsafeBytes { inputPointer -> Int in
                guard let src = inputPointer.bindMemory(to: UInt8.self).baseAddress,
                      let dst = outputPointer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                // WE stores raw LZ4 blocks (no frame header).
                return compression_decode_buffer(
                    dst, uncompressedSize,
                    src, data.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written == uncompressedSize else {
            return nil
        }
        return output
    }

    private static func looksLikeMP4File(_ data: Data) -> Bool {
        // ISO base media files start with a box header whose type at
        // bytes 4..7 is "ftyp".
        guard data.count >= 12 else { return false }
        let start = data.startIndex
        return data[start + 4] == 0x66     // f
            && data[start + 5] == 0x74     // t
            && data[start + 6] == 0x79     // y
            && data[start + 7] == 0x70     // p
    }

    private static func looksLikeImageFile(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 { return true }          // JPEG
        if data[data.startIndex] == 0x89, data[data.startIndex + 1] == 0x50 { return true }          // PNG
        if data[data.startIndex] == 0x47, data[data.startIndex + 1] == 0x49 { return true }          // GIF
        if data[data.startIndex] == 0x42, data[data.startIndex + 1] == 0x4D { return true }          // BMP
        return false
    }

    private static func textureFromImageData(_ data: Data, device: MTLDevice) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(cgImage: cgImage, options: [.SRGB: false])
    }

    private static func textureFromRawPixels(
        _ data: Data,
        format: UInt32,
        width: Int,
        height: Int,
        cropWidth: Int,
        cropHeight: Int,
        device: MTLDevice
    ) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }

        let pixelFormat: MTLPixelFormat
        let bytesPerPixel: Int
        let blockCompressed: Bool
        let blockBytes: Int

        switch format {
        case 0:   // "ARGB8888" — stored as RGBA byte order
            pixelFormat = .rgba8Unorm
            bytesPerPixel = 4
            blockCompressed = false
            blockBytes = 0
        case 4:   // DXT5
            pixelFormat = .bc3_rgba
            bytesPerPixel = 0
            blockCompressed = true
            blockBytes = 16
        case 6:   // DXT3
            pixelFormat = .bc2_rgba
            bytesPerPixel = 0
            blockCompressed = true
            blockBytes = 16
        case 7:   // DXT1
            pixelFormat = .bc1_rgba
            bytesPerPixel = 0
            blockCompressed = true
            blockBytes = 8
        case 8:   // RG88
            pixelFormat = .rg8Unorm
            bytesPerPixel = 2
            blockCompressed = false
            blockBytes = 0
        case 9:   // R8
            pixelFormat = .r8Unorm
            bytesPerPixel = 1
            blockCompressed = false
            blockBytes = 0
        default:
            print("[WETexDecoder] Unsupported raw texture format \(format)")
            return nil
        }

        let sourceBytesPerRow = blockCompressed
            ? max(width / 4, 1) * blockBytes
            : width * bytesPerPixel
        let sourceRows = blockCompressed ? max(height / 4, 1) : height
        guard data.count >= sourceBytesPerRow * sourceRows else {
            print("[WETexDecoder] Raw payload too small: have \(data.count), need \(sourceBytesPerRow * sourceRows) (format \(format), \(width)x\(height))")
            return nil
        }

        // Compressed textures crop on 4-pixel block boundaries.
        let finalWidth: Int
        let finalHeight: Int
        if blockCompressed {
            finalWidth = min(max((cropWidth + 3) / 4 * 4, 4), width)
            finalHeight = min(max((cropHeight + 3) / 4 * 4, 4), height)
        } else {
            finalWidth = min(max(cropWidth, 1), width)
            finalHeight = min(max(cropHeight, 1), height)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: finalWidth,
            height: finalHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            // Upload the top-left crop; the source row stride stays the full
            // padded width so rows advance correctly.
            texture.replace(
                region: MTLRegionMake2D(0, 0, finalWidth, finalHeight),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: sourceBytesPerRow
            )
        }
        return texture
    }

    // MARK: - Binary reader

    private struct BinaryReader {
        let data: Data
        var offset: Int = 0

        mutating func readUInt32() -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            let value = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4
            return CFSwapInt32LittleToHost(value)
        }

        mutating func readInt32() -> Int32 {
            Int32(bitPattern: readUInt32())
        }

        mutating func readString(length: Int) -> String? {
            guard offset + length <= data.count else { return nil }
            let slice = data[offset..<(offset + length)]
            offset += length
            return slice.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return nil }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
        }

        mutating func readNullTerminatedString() -> String {
            var bytes: [UInt8] = []
            while offset < data.count {
                let byte = data[data.startIndex + offset]
                offset += 1
                if byte == 0 {
                    break
                }
                bytes.append(byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        mutating func readBytes(count: Int) -> Data {
            guard offset + count <= data.count else { return Data() }
            let result = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
            offset += count
            return result
        }

        func canRead(_ count: Int) -> Bool {
            offset + count <= data.count
        }
    }
}
