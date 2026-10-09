import Foundation

/// A regular, row-major particle atlas. Packed GIF frames and rotated or
/// irregular frame layouts require a different sampler and are not grids.
struct ParticleTextureAtlas: Equatable {
    let columns: Int
    let rows: Int
    let frameCount: Int
    let frameWidth: Float
    let frameHeight: Float
    let duration: Float

    var renderUniform: SIMD4<Float> {
        SIMD4(1 / Float(columns), 1 / Float(rows), Float(frameCount), frameHeight / frameWidth)
    }

    func animationPosition(mode: String, lifetimePosition: Float, random: Float, multiplier: Float) -> Float {
        guard lifetimePosition.isFinite, random.isFinite, multiplier.isFinite else { return 0 }
        switch mode.lowercased() {
        case "randomframe":
            return (floor(min(max(random, 0), 0.99999994) * Float(frameCount)) + 0.5) / Float(frameCount)
        case "once":
            return min(max(lifetimePosition * multiplier, 0), Float(frameCount - 1) / Float(frameCount))
        default:
            // WE stretches a particle sequence over its lifetime. Import
            // duration applies to image animations, not particle atlases.
            let position = max(lifetimePosition * multiplier, 0)
            guard position.isFinite else { return 0 }
            return position - floor(position)
        }
    }

    /// Authoring tools round stored sheets up to a multiple of 4 or 16 pixels
    /// (1603x616 for 8x3 frames of 200x205, 528x112 for 5x1 of 105), so the
    /// grid may overshoot slightly.
    private static let alignmentSlack: Float = 16

    static func decode(_ data: Data) -> Self? {
        var reader = AtlasReader(data: data)
        guard reader.tag() == "TEXV0005", reader.tag() == "TEXI0001",
              reader.words(7) != nil else { return nil }
        guard let container = reader.tag(),
              let images = reader.word(), images > 0, images <= data.count / 4 else { return nil }
        let version: Int
        switch container {
        case "TEXB0001": version = 1
        case "TEXB0002": version = 2
        case "TEXB0003":
            version = 3
            guard reader.word() != nil else { return nil }
        case "TEXB0004":
            version = 3
            guard reader.words(2) != nil else { return nil }
        default: return nil
        }
        // Walk lengths instead of searching for magic inside compressed data.
        // The header holds the power-of-two storage size; frames are laid out
        // against the stored image, which is usually smaller (516x516 in 1024x1024).
        var width = 0, height = 0
        for image in 0..<images {
            guard let mips = reader.word(), mips > 0, mips <= data.count / 12 else { return nil }
            for mip in 0..<mips {
                guard let fields = reader.words(version >= 2 ? 4 : 2),
                      let bytes = reader.word(), reader.skip(Int(bytes)) else { return nil }
                if image == 0, mip == 0 { width = Int(fields[0]); height = Int(fields[1]) }
            }
        }
        guard width > 0, height > 0 else { return nil }
        guard let tag = reader.tag(), ["TEXS0002", "TEXS0003"].contains(tag),
              let count = reader.word(), count > 1, count <= reader.remaining / 32 else { return nil }
        if tag == "TEXS0003", reader.words(2) == nil { return nil }
        var frames: [[Float]] = []
        for _ in 0..<count {
            guard let words = reader.words(8), words[0] == 0 else { return nil }
            let values = words.dropFirst().map { Float(bitPattern: $0) }
            guard values.allSatisfy(\.isFinite), values[0] > 0 else { return nil }
            frames.append(values)
        }
        let first = frames[0], frameWidth = first[3], frameHeight = first[6]
        guard frameWidth >= 1, frameHeight >= 1,
              frameWidth <= Float(width), frameHeight <= Float(height) else { return nil }
        let columns = Int((Float(width) / frameWidth).rounded())
        let rows = Int((Float(height) / frameHeight).rounded())
        let capacity = columns.multipliedReportingOverflow(by: rows)
        guard !capacity.overflow, capacity.partialValue >= count,
              abs(Float(columns) * frameWidth - Float(width)) <= Self.alignmentSlack,
              abs(Float(rows) * frameHeight - Float(height)) <= Self.alignmentSlack else { return nil }
        // The particle shader derives each cell from the frame size and index
        // alone, so stored x/y offsets are not validated: stock sheets such as
        // leaves6 (a 6x5 grid) carry offsets for a different column count.
        for frame in frames {
            guard frame[3] == frameWidth, frame[6] == frameHeight,
                  frame[4] == 0, frame[5] == 0 else { return nil }
        }
        let duration = frames.reduce(Float(0)) { $0 + $1[0] }
        guard duration.isFinite, duration > 0 else { return nil }
        return Self(columns: columns, rows: rows, frameCount: Int(count),
                    frameWidth: frameWidth, frameHeight: frameHeight,
                    duration: duration)
    }
}

private struct AtlasReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        offset += count
        return true
    }

    mutating func word() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func words(_ count: Int) -> [UInt32]? {
        guard count <= remaining / 4 else { return nil }
        return (0..<count).map { _ in word()! }
    }

    mutating func tag() -> String? {
        guard remaining >= 9, data[offset + 8] == 0 else { return nil }
        defer { offset += 9 }
        return String(decoding: data[offset..<offset + 8], as: UTF8.self)
    }
}
