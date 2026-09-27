import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct LightFalloffTests {
    @Test func exponentTimelinePausesAndOldSerializedLightsStillDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELightFalloff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 128, "height": 128]],
            "objects": [["id": 1, "light": "lpoint", "exponent": [
            "value": 2, "animation": ["c0": [["frame": 0, "value": 2], ["frame": 10, "value": 6]],
                "options": ["fps": 10, "length": 10, "mode": "single"]]
        ]]]]
        try JSONSerialization.data(withJSONObject: raw).write(to: root.appendingPathComponent("scene.json"))
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene)
        #expect(runtime.step(deltaTime: 0).lights.first?.exponent == 2)
        #expect(runtime.step(deltaTime: 0.5).lights.first?.exponent == 4)
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 3).lights.first?.exponent == 4)
        runtime.setPaused(false)
        let frame = try #require(runtime.step(deltaTime: 0.5).lights.first)
        #expect(frame.exponent == 6)
        let restored = try JSONDecoder().decode(FrameLight.self, from: JSONEncoder().encode(frame))
        #expect(restored == frame)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        json.removeValue(forKey: "exponent")
        let old = try JSONDecoder().decode(FrameLight.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.exponent == nil)
        #expect(old.intensity == frame.intensity)
        let descriptor = try #require(scene.nodes.first?.light)
        var rawDescriptor = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
        rawDescriptor.removeValue(forKey: "exponent")
        let oldDescriptor = try JSONDecoder().decode(LightDescriptor.self, from: JSONSerialization.data(withJSONObject: rawDescriptor))
        #expect(oldDescriptor.exponent == nil)
    }
}
