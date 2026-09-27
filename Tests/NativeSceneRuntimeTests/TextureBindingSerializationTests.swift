import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct TextureBindingSerializationTests {
    @Test func olderTextureBindingsDecodeWithoutACategory() throws {
        let old = Data(#"{"slot":2,"path":"preview.png"}"#.utf8)
        let descriptor = try JSONDecoder().decode(TextureReference.self, from: old)
        let frame = try JSONDecoder().decode(FrameTextureBinding.self, from: old)
        #expect(descriptor.sourceType == nil)
        #expect(frame.sourceType == nil)
        #expect(descriptor.slot == 2 && frame.slot == 2)
        #expect(descriptor.path == "preview.png" && frame.path == "preview.png")
        let named = Data(#"{"slot":1,"path":"$mediaThumbnail","sourceType":"system"}"#.utf8)
        let system = try JSONDecoder().decode(FrameTextureBinding.self, from: named)
        let restored = try JSONDecoder().decode(FrameTextureBinding.self, from: JSONEncoder().encode(system))
        #expect(restored == system)
        #expect(restored.sourceType == "system")
    }
}
