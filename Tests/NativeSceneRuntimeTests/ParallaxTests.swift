import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ParallaxTests {
    @Test func layersAtTheSameDepthShiftEquallyRegardlessOfSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEParallax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json"])
            .write(to: root.appendingPathComponent("project.json"))
        func image(_ id: Int, size: String?) -> [String: Any] {
            var object: [String: Any] = ["id": id, "image": "missing.json", "origin": "0 0 0", "parallaxDepth": "1 1"]
            if let size { object["size"] = size }
            return object
        }
        try JSONSerialization.data(withJSONObject: [
            "camera": [:],
            "general": [
                "orthogonalprojection": ["width": 1000, "height": 500],
                "cameraparallax": true,
                "cameraparallaxamount": 0.5,
                "cameraparallaxdelay": 0,
                "cameraparallaxmouseinfluence": 0.5,
            ],
            "objects": [image(1, size: "1000 500"), image(2, size: "50 50"), image(3, size: nil)],
        ]).write(to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)

        let frame = SceneRuntime(scene: scene).step(deltaTime: 1, cursorPosition: .init(x: 1, y: 0.5))
        let xs = frame.nodes.map(\.worldPosition.x)
        #expect(xs.count == 3)
        // displacement 0.5 * 0.5 = 0.25 of the 1000-wide scene
        for x in xs { #expect(abs(x - 250) < 0.001) }
    }
}
