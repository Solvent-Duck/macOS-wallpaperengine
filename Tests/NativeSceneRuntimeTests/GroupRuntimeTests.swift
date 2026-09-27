import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct GroupRuntimeTests {
    @Test func nestedGroupsPreserveTransformsAndUserControlledVisibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEGroupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project: [String: Any] = ["type": "scene", "file": "scene.json", "general": ["properties": [
            "shown": ["type": "bool", "value": false],
        ]]]
        let objects: [[String: Any]] = [
            // Child appears before its parents in paint order.
            ["id": 3, "parent": 2, "image": "missing.json", "origin": "1 0 0"],
            ["id": 2, "parent": 1, "origin": "2 0 0", "scale": "3 3 1"],
            ["id": 1, "origin": "10 20 0", "scale": "2 2 1", "angles": "0 0 \(Double.pi / 2)",
             "visible": ["value": true, "user": "shown"]],
            ["id": 4, "image": "missing.json", "origin": "5 6 0"],
        ]
        try JSONSerialization.data(withJSONObject: project).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": objects])
            .write(to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        #expect(scene.nodes[2].group?.angles != nil)
        // Group fields survive the adapter's serializable scene format.
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(scene))
        #expect(restored == scene)
        let runtime = SceneRuntime(scene: restored)
        let first = runtime.step(deltaTime: 1 / 60)
        #expect(first.nodes.map(\.visible) == [false, false, false, true])
        #expect(abs(first.nodes[0].worldPosition.x - 10) < 0.0001)
        #expect(abs(first.nodes[0].worldPosition.y - 30) < 0.0001)
        let shown = runtime.step(deltaTime: 1 / 60, propertyOverrides: ["shown": .bool(true)])
        #expect(shown.nodes.allSatisfy { $0.visible })
        #expect(shown.nodes[3].worldPosition == RuntimeVector3(x: 5, y: 6, z: 0))
    }
}
