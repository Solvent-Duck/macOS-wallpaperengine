import Foundation
import NativeSceneRuntime
import Testing

struct EffectTargetSerializationTests {
    @Test func olderPacketsDefaultToRGBA8Targets() throws {
        let old = Data(#"{"name":"history","scale":2,"unique":true}"#.utf8)
        let target = try JSONDecoder().decode(FrameRenderTargetDescriptor.self, from: old)
        #expect(target == FrameRenderTargetDescriptor(name: "history", scale: 2, unique: true))
        #expect(target.format == "rgba8888")
    }

    @Test func authoredTargetFormatSurvivesPacketRoundTrip() throws {
        let target = FrameRenderTargetDescriptor(name: "velocity", scale: 4, unique: true, format: "rg1616f")
        let restored = try JSONDecoder().decode(FrameRenderTargetDescriptor.self, from: JSONEncoder().encode(target))
        #expect(restored == target)
        #expect(restored.format == "rg1616f")
    }
}
