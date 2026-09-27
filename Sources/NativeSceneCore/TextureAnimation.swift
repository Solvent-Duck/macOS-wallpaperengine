import Foundation

/// TEXS frames can occupy arbitrary, rotated rectangles on multiple image pages.
public struct TextureAnimationFrame: Equatable, Sendable {
    public let imageIndex: Int
    public let duration: Double
    public let translation: SIMD2<Float>
    public let rotation: SIMD4<Float>
}

public struct TextureAnimation: Equatable, Sendable {
    public let frames: [TextureAnimationFrame]
    public let imageSizes: [SIMD2<Float>]
    public let duration: Double

    public func frameIndex(at time: Double) -> Int {
        guard time.isFinite, duration > 0 else { return 0 }
        var phase = time.truncatingRemainder(dividingBy: duration)
        if phase < 0 { phase += duration }
        for (index, frame) in frames.enumerated() {
            if phase < frame.duration { return index }
            phase -= frame.duration
        }
        return frames.count - 1
    }

    public func time(atFrame frame: Double) -> Double {
        guard frame.isFinite else { return 0 }
        let clamped = min(max(0, frame), Double(frames.count - 1))
        let index = Int(clamped)
        return frames.prefix(index).reduce(0) { $0 + $1.duration } + (clamped - Double(index)) * frames[index].duration
    }

    public func frame(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        var phase = time.truncatingRemainder(dividingBy: duration)
        if phase < 0 { phase += duration }
        let index = frameIndex(at: phase)
        let start = frames.prefix(index).reduce(0) { $0 + $1.duration }
        return Double(index) + (phase - start) / frames[index].duration
    }

    public static func decode(_ data: Data) -> Self? {
        var reader = TextureAnimationReader(data: data)
        guard reader.tag() == "TEXV0005", reader.tag() == "TEXI0001", reader.words(7) != nil,
              let container = reader.tag(), let count = reader.word(), count > 0, count <= reader.remaining / 4 else { return nil }
        let version: Int
        switch container {
        case "TEXB0001": version = 1
        case "TEXB0002": version = 2
        case "TEXB0003": version = 3; guard reader.word() != nil else { return nil }
        case "TEXB0004": version = 3; guard reader.words(2) != nil else { return nil }
        default: return nil
        }
        var imageSizes: [SIMD2<Float>] = []
        for _ in 0..<count {
            guard let mips = reader.word(), mips > 0, mips <= reader.remaining / 12 else { return nil }
            for mip in 0..<mips {
                guard let fields = reader.words(version >= 2 ? 4 : 2), fields[0] > 0, fields[1] > 0,
                      let length = reader.word(), reader.skip(Int(length)) else { return nil }
                if mip == 0 { imageSizes.append(SIMD2(Float(fields[0]),Float(fields[1]))) }
            }
        }
        guard let tag = reader.tag(), ["TEXS0002","TEXS0003"].contains(tag),
              let count = reader.word(), count > 0 else { return nil }
        if tag == "TEXS0003", reader.words(2) == nil { return nil }
        guard count <= reader.remaining / 32 else { return nil }
        var frames: [TextureAnimationFrame] = []
        for _ in 0..<count {
            guard let fields = reader.words(8), fields[0] < imageSizes.count else { return nil }
            let values = fields.dropFirst().map { Float(bitPattern: $0) }
            guard values.allSatisfy(\.isFinite), values[0] > 0 else { return nil }
            // Pixel vectors (width1,width2) and (height2,height1) allow
            // rotated packed frames; normalize each component by its axis.
            let size = imageSizes[Int(fields[0])]
            frames.append(TextureAnimationFrame(imageIndex: Int(fields[0]), duration: Double(values[0]),
                translation: SIMD2(values[1],values[2]) / size,
                rotation: SIMD4(values[3]/size.x,values[4]/size.y,values[5]/size.x,values[6]/size.y)))
        }
        let duration = frames.reduce(0) { $0 + $1.duration }
        guard duration.isFinite, duration > 0 else { return nil }
        return Self(frames: frames, imageSizes: imageSizes, duration: duration)
    }
}

/// Metadata is shared between script playback and the renderer. Failed lookups
/// are cached too; a non-animated image does not trigger a file read every frame.
public final class TextureAnimationLibrary: @unchecked Sendable {
    private let roots: [URL]
    private let lock = NSLock()
    private var cache: [String: TextureAnimation?] = [:]

    public init(assetRoots: [URL]) { roots = assetRoots }

    public func animation(for path: String) -> TextureAnimation? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        let result = assetURL(for: path)
            .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.flatMap(TextureAnimation.decode)
        cache[path] = .some(result)
        return result
    }

    /// Share the renderer/runtime asset search order with other texture clocks.
    public func assetURL(for path: String) -> URL? {
        Self.candidateURLs(for: path, roots: roots)
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    public static func candidateURLs(for path: String, roots: [URL]) -> [URL] {
        if (path as NSString).isAbsolutePath {
            let url = URL(fileURLWithPath: path); return [url,url.appendingPathExtension("tex")]
        }
        let hasExtension = !URL(fileURLWithPath: path).pathExtension.isEmpty
        return roots.flatMap { root in [path,"materials/\(path)"].flatMap { name in
            hasExtension ? [root.appendingPathComponent(name),root.appendingPathComponent(name + ".tex")]
                : ["png","tga","jpg","jpeg","tex"].map { root.appendingPathComponent(name).appendingPathExtension($0) }
        } }
    }
}

private struct TextureAnimationReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        offset += count; return true
    }
    mutating func word() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let result = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4; return UInt32(littleEndian: result)
    }
    mutating func words(_ count: Int) -> [UInt32]? {
        guard count >= 0, count <= remaining / 4 else { return nil }
        return (0..<count).map { _ in word()! }
    }
    mutating func tag() -> String? {
        guard remaining >= 9, data[offset+8] == 0 else { return nil }
        defer { offset += 9 }
        return String(decoding: data[offset..<offset+8], as: UTF8.self)
    }
}
