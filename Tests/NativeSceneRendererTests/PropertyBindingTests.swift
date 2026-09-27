import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct PropertyBindingTests {
    @Test func userPropertiesOverrideAuthoredSnapshots() throws {
        let (root, scene) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try #require(scene.nodes.first?.image)
        let defaults = evaluator(scene)
        #expect(defaults.scalarDouble(for: image.alpha, default: -1) == 0.75)
        #expect(defaults.boolValue(for: image.visible, default: true) == false)
        let changed = evaluator(scene, properties: ["opacity": .double(0.2), "visible": .bool(true)])
        #expect(changed.scalarDouble(for: image.alpha, default: -1) == 0.2)
        #expect(changed.boolValue(for: image.visible, default: false) == true)
    }

    @Test func runtimeOverridesHavePriorityAndUnknownBindingsKeepLiteral() throws {
        let (root, scene) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try #require(scene.nodes.first?.image)
        let changed = evaluator(scene, properties: ["opacity": .double(0.2)], runtime: ["scene.node.1.alpha": .double(0.9)])
        #expect(changed.scalarDouble(for: image.alpha, default: -1) == 0.9)
        #expect(changed.vector3Value(for: image.scale, default: .zero) == RuntimeVector3(x: 2, y: 3, z: 1))
    }

    @Test func conditionalSettingsKeepTheirOwnLiteral() throws {
        let (root, scene) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try #require(scene.nodes.last?.image)
        let hidden = evaluator(scene, properties: ["visible": .bool(false)])
        let shown = evaluator(scene, properties: ["visible": .bool(true)])
        #expect(hidden.boolValue(for: image.visible, default: true) == false)
        #expect(shown.boolValue(for: image.visible, default: false) == true)
        #expect(shown.scalarDouble(for: image.alpha, default: -1) == 0.6)
    }

    private func evaluator(_ scene: SceneDescription, properties: [String: FrameValue] = [:], runtime: [String: FrameValue] = [:]) -> PropertyEvaluator {
        PropertyEvaluator(scene: scene, context: PropertyEvaluationContext(elapsedTime: 0, deltaTime: 0, frameIndex: 0, propertyOverrides: properties, runtimeOverrides: runtime))
    }

    private func fixture() throws -> (URL, SceneDescription) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEProperties-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project: [String: Any] = ["type": "scene", "file": "scene.json", "general": ["properties": [
            "opacity": ["type": "slider", "value": 0.75], "visible": ["type": "bool", "value": false]
        ]]]
        let scene: [String: Any] = ["camera": [:], "general": [:], "objects": [
            ["id": 1, "image": "missing.json", "alpha": ["user": "opacity", "value": 1],
             "visible": ["user": "visible", "value": true], "scale": ["user": "missing", "value": "2 3 1"]],
            ["id": 2, "image": "missing.json", "alpha": ["user": ["name": "visible", "condition": "true"], "value": 0.6],
             "visible": ["user": ["name": "visible", "condition": "true"], "value": true]]
        ]]
        try JSONSerialization.data(withJSONObject: project).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
        return (root, try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path))
    }
}
