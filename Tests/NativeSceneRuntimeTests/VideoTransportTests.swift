import Foundation
@testable import NativeSceneRuntime
import Testing

struct VideoTransportTests {
    @Test func pauseSeekRateAndStopPreserveIndependentClocks() {
        var video = SceneVideoTexture(duration: 4)
        #expect(video.advance(1) == 0 && video.time == 1)
        video.apply(["action": "pause"])
        #expect(video.advance(2) == 0 && video.time == 1)
        video.apply(["action": "setCurrentTime", "value": 2.0])
        video.apply(["action": "rate", "value": 2.0])
        video.apply(["action": "play"])
        #expect(video.advance(0.5) == 0 && video.time == 3)
        #expect(video.advance(1) == 1 && video.time == 1)
        video.apply(["action": "stop"])
        #expect(video.time == 0 && !video.playing)
        video.apply(["action": "setCurrentTime", "value": 100.0])
        #expect(video.time == 4 && !video.playing)
        video.apply(["action": "setCurrentTime", "value": -2.0])
        #expect(video.time == 0)
    }

    @Test func finiteCompletionReversePlaybackAndInvalidInputs() {
        var video = SceneVideoTexture(duration: 2)
        video.apply(["action": "loop", "value": false])
        #expect(video.advance(3) == 1 && video.time == 2 && !video.playing)
        #expect(video.advance(10) == 0 && video.time == 2)
        video.apply(["action": "rate", "value": -1.0])
        video.apply(["action": "play"])
        #expect(video.advance(0.5) == 0 && video.time == 1.5)
        #expect(video.advance(2) == 1 && video.time == 0 && !video.playing)
        video.apply(["action": "setCurrentTime", "value": Double.nan])
        video.apply(["action": "rate", "value": Double.infinity])
        #expect(video.time == 0 && video.rate == -1)
        video.apply(["action": "loop", "value": true])
        video.apply(["action": "play"])
        #expect(video.advance(4.5) == 3 && video.time == 1.5)
        #expect(video.advance(.infinity) == 0 && video.time == 1.5)
    }

    @Test func textureMetadataRejectsTruncatedAndInvalidPayloads() {
        #expect(SceneVideoTextureLibrary.moviePayload(Data()) == nil)
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        for _ in 0..<7 { word(1) }
        data.append(Data("TEXB0003\0".utf8)); word(1); word(UInt32.max)
        word(1); word(16); word(16); word(0); word(12); word(12)
        data.append(Data([0, 0, 0, 12])); data.append(Data("ftypisom".utf8))
        #expect(SceneVideoTextureLibrary.moviePayload(data)?.count == 12)
        for length in 0..<data.count { #expect(SceneVideoTextureLibrary.moviePayload(data.prefix(length)) == nil) }
        data[data.count - 8] = 0
        #expect(SceneVideoTextureLibrary.moviePayload(data) == nil)
    }
}
