import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct LightControlPointTests {
    @Test func endpointTimelineUsesLocalAndParentTransformsAndPausesWithTheScene() throws {
        let control: [String: Any] = ["value": "8 4 2", "animation": [
            "c0": [["frame": 0, "value": 0], ["frame": 10, "value": 16]],
            "relative": true, "options": ["fps": 10, "length": 10, "mode": "single"]
        ]]
        let scene = try fixture(controlPoint: control)
        let runtime = SceneRuntime(scene: scene)
        let initial = try #require(runtime.step(deltaTime: 0).lights.first)
        expectVector(initial.position, [60, 210, 330])
        expectVector(try #require(initial.endPosition), [28, 198, 338])
        let middle = try #require(runtime.step(deltaTime: 0.5).lights.first)
        expectVector(try #require(middle.endPosition), [-4, 198, 338])
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 5).lights.first?.endPosition == middle.endPosition)
        runtime.setPaused(false)
        let final = runtime.step(deltaTime: 0.5)
        expectVector(try #require(final.lights.first?.endPosition), [-36, 198, 338])
        let restored = try JSONDecoder().decode(FramePacket.self, from: JSONEncoder().encode(final))
        #expect(restored.lights == final.lights)
    }

    @Test func olderSerializedLightsRetainTheLengthFallback() throws {
        let scene = try fixture(controlPoint: "8 4 2")
        let descriptor = try #require(scene.nodes.first(where: { $0.light != nil })?.light)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
        json.removeValue(forKey: "controlPoint")
        json.removeValue(forKey: "scale")
        let oldDescriptor = try JSONDecoder().decode(LightDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(oldDescriptor.controlPoint == nil)
        #expect(oldDescriptor.scale == nil)
        #expect(oldDescriptor.length == descriptor.length)
        let frame = try #require(SceneRuntime(scene: scene).step(deltaTime: 0).lights.first)
        var frameJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        frameJSON.removeValue(forKey: "endPosition")
        let oldFrame = try JSONDecoder().decode(FrameLight.self, from: JSONSerialization.data(withJSONObject: frameJSON))
        #expect(oldFrame.endPosition == nil)
        #expect(oldFrame.position == frame.position)
        #expect(oldFrame.length == frame.length)
        let missing = try fixture(controlPoint: nil)
        #expect(SceneRuntime(scene: missing).step(deltaTime: 0).lights.first?.endPosition == nil)
    }

    private func fixture(controlPoint: Any?) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WETubeEndpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var light: [String: Any] = ["id": 2, "parent": 1, "light": "ltube", "origin": "10 20 30",
                                   "scale": "2 3 4", "angles": "0 0 \(Double.pi / 2)", "length": 80]
        if let controlPoint { light["controlpoint"] = controlPoint }
        let raw: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                 "general": ["orthogonalprojection": ["width": 128, "height": 128]],
                                 "objects": [light, ["id": 1, "origin": "100 200 300", "scale": "1 2 1", "angles": "0 0 \(Double.pi / 2)"]]]
        try JSONSerialization.data(withJSONObject: raw).write(to: root.appendingPathComponent("scene.json"))
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }

    private func expectVector(_ actual: RuntimeVector3, _ expected: [Float]) {
        #expect(abs(actual.x - expected[0]) < 0.0001)
        #expect(abs(actual.y - expected[1]) < 0.0001)
        #expect(abs(actual.z - expected[2]) < 0.0001)
    }
}
