import Foundation
@testable import NativeSceneRenderer
import Testing

struct ParticleTextureAtlasTests {
    @Test func readsAtlasAfterImagePayloadAndMipLevels() throws {
        let data = makeAtlasTestTexture()
        let atlas = try #require(ParticleTextureAtlas.decode(data))
        #expect(atlas.columns == 2)
        #expect(atlas.rows == 1)
        #expect(atlas.frameCount == 2)
        #expect(atlas.renderUniform == SIMD4<Float>(0.5, 1, 2, 1))
        #expect(atlas.duration == 1)
        for count in [0, 8, 18, 55, 68, data.count - 1] {
            #expect(ParticleTextureAtlas.decode(data.prefix(count)) == nil)
        }
        var malformed = data
        // A packed second image is not a grid on the first texture.
        let lastFrame = malformed.count - 32
        malformed[lastFrame] = 1
        #expect(ParticleTextureAtlas.decode(malformed) == nil)
        var oversized = data
        // Stored dimensions must not overflow the inferred grid capacity.
        oversized.replaceSubrange(63..<71, with: Data(repeating: 255, count: 8))
        for frame in [oversized.count - 64, oversized.count - 32] {
            for offset in [16, 28] {
                var one = Float(1).bitPattern.littleEndian
                withUnsafeBytes(of: &one) { oversized.replaceSubrange(frame + offset..<frame + offset + 4, with: $0) }
            }
        }
        #expect(ParticleTextureAtlas.decode(oversized) == nil)
    }

    @Test func framesAreLaidOutAgainstTheStoredImageNotThePaddedHeader() throws {
        // 10x5 stored image in a 16x8 header: 2 frames of 5x5, plus a 4px-aligned overshoot.
        var data = makeAtlasTestTexture()
        func put(_ value: UInt32, at offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        func putFloat(_ value: Float, at offset: Int) { put(value.bitPattern, at: offset) }
        put(16, at: 26); put(8, at: 30)
        put(10, at: 63); put(5, at: 67)
        let frames = data.count - 64
        for index in 0..<2 {
            putFloat(Float(index) * 5, at: frames + index * 32 + 8)
            putFloat(5, at: frames + index * 32 + 16)
            putFloat(5, at: frames + index * 32 + 28)
        }
        let atlas = try #require(ParticleTextureAtlas.decode(data))
        #expect(atlas.columns == 2 && atlas.rows == 1 && atlas.frameCount == 2)
        // One extra pixel row/column of alignment padding is tolerated.
        put(11, at: 63); put(6, at: 67)
        #expect(ParticleTextureAtlas.decode(data)?.columns == 2)
    }

    @Test func sequenceOnceAndRandomFrameKeepTheirPlaybackSemantics() throws {
        let atlas = try #require(ParticleTextureAtlas.decode(makeAtlasTestTexture()))
        func position(_ mode: String, _ lifetime: Float = 0.2, _ speed: Float = 1) -> Float {
            atlas.animationPosition(mode: mode, lifetimePosition: lifetime, random: 0.75, multiplier: speed)
        }
        #expect(abs(position("sequence", 0.75, 3) - 0.25) < 0.00001)
        #expect(position("sequence", 0.25, 2) == 0.5)
        #expect(position("once", 0.8) == 0.5)
        #expect(position("once", 0.2) == 0.2)
        #expect(position("randomframe", 0) == 0.75)
        #expect(position("randomframe", 0.9) == 0.75)
    }
}

/// Original 8x4 RG atlas: two 4x4 gray frames with full alpha. Includes a
/// second mip so metadata cannot be found by assuming a single payload.
func makeAtlasTestTexture() -> Data {
    var data = Data()
    func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func float(_ value: Float) { word(value.bitPattern) }
    data.append(contentsOf: "TEXV0005\0TEXI0001\0".utf8)
    [8, 4, 8, 4, 8, 4, 0].forEach { word(UInt32($0)) }
    data.append(contentsOf: "TEXB0001\0".utf8)
    word(1); word(2)
    word(8); word(4); word(64)
    for _ in 0..<4 {
        for x in 0..<8 { data.append(contentsOf: [x < 4 ? UInt8(64) : UInt8(192), 255]) }
    }
    word(4); word(2); word(16)
    data.append(Data(repeating: 0, count: 16))
    data.append(contentsOf: "TEXS0003\0".utf8)
    word(2); word(4); word(4)
    for index in 0..<2 {
        word(0)
        [Float(0.5), Float(index * 4), 0, 4, 0, 0, 4].forEach { float($0) }
    }
    return data
}
