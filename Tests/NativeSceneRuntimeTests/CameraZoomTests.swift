import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct CameraZoomTests {
    @Test func zoomTimelineUsesTheSceneClockAndSurvivesPacketSerialization() throws {
        let zoom: [String: Any] = ["value": 1, "animation": [
            "c0": [["frame": 0, "value": 1], ["frame": 10, "value": 2]],
            "options": ["fps": 10, "length": 10, "mode": "single"]
        ]]
        let runtime = SceneRuntime(scene: try fixture(zoom: zoom))
        #expect(runtime.step(deltaTime: 0).cameraZoom == 1)
        let middle = runtime.step(deltaTime: 0.5)
        #expect(middle.cameraZoom == 1.5)
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 10).cameraZoom == middle.cameraZoom)
        runtime.setPaused(false)
        let final = runtime.step(deltaTime: 0.5)
        #expect(final.cameraZoom == 2)
        #expect(final.nodes.first?.worldTransform == middle.nodes.first?.worldTransform)
        #expect(try JSONDecoder().decode(FramePacket.self, from: JSONEncoder().encode(final)) == final)
    }

    @Test func zoomScriptsAndUserPropertiesUpdateTheSameFrame() throws {
        let scene = try fixture(zoom: ["value": 1, "script": """
        export function update() { return engine.userProperties.magnification + engine.runtime; }
        """])
        let runtime = SceneRuntime(scene: scene)
        #expect(runtime.step(deltaTime: 0.5, propertyOverrides: ["magnification": .double(2)]).cameraZoom == 2.5)
        #expect(runtime.step(deltaTime: 0.5, propertyOverrides: ["magnification": .double(0.5)]).cameraZoom == 1.5)
        let linked = SceneRuntime(scene: try fixture(zoom: ["value": 1, "user": "magnification"]))
        #expect(linked.step(deltaTime: 0, propertyOverrides: ["magnification": .double(0.5)]).cameraZoom == 0.5)
    }

    @Test func sceneAnimationHandlesControlTheZoomTimeline() throws {
        let zoom: [String: Any] = ["value": 1, "animation": [
            "c0": [["frame": 0, "value": 1], ["frame": 10, "value": 2]],
            "options": ["name": "camera zoom", "fps": 10, "length": 10, "mode": "single"]
        ], "script": """
        export function init(value) {
            const animation = thisScene.getAnimation('camera zoom');
            if (!animation) throw new Error('camera timeline missing');
            animation.pause();
            animation.setFrame(7);
            return value;
        }
        export function update(value) { return value; }
        """]
        let runtime = SceneRuntime(scene: try fixture(zoom: zoom))
        #expect(abs(runtime.step(deltaTime: 0).cameraZoom - 1.7) < 0.0001)
        #expect(abs(runtime.step(deltaTime: 10).cameraZoom - 1.7) < 0.0001)
    }

    @Test func absentInvalidAnd3DZoomRetainUnitMagnification() throws {
        for zoom: Any? in [nil, 0, -2, ["value": 1, "script": "export function update() { return Infinity; }"]] {
            #expect(SceneRuntime(scene: try fixture(zoom: zoom)).step(deltaTime: 0).cameraZoom == 1)
        }
        #expect(SceneRuntime(scene: try fixture(zoom: 2, full3D: true)).step(deltaTime: 0).cameraZoom == 1)
        let scene = try fixture(zoom: 2)
        let camera = try #require(scene.scene?.camera)
        var cameraJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? [String: Any])
        cameraJSON.removeValue(forKey: "zoom")
        #expect(try JSONDecoder().decode(CameraDescriptor.self, from: JSONSerialization.data(withJSONObject: cameraJSON)).zoom == nil)
        let packet = SceneRuntime(scene: scene).step(deltaTime: 0)
        var packetJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any])
        packetJSON.removeValue(forKey: "cameraZoom")
        #expect(try JSONDecoder().decode(FramePacket.self, from: JSONSerialization.data(withJSONObject: packetJSON)).cameraZoom == 1)
    }

    private func fixture(zoom: Any?, full3D: Bool = false) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WECameraZoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var general: [String: Any] = ["orthogonalprojection": full3D ? NSNull() : ["width": 128, "height": 128]]
        if let zoom { general["zoom"] = zoom }
        let raw: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                 "general": general, "objects": [["id": 1, "origin": "64 64 0"]]]
        let project: [String: Any] = ["type": "scene", "file": "scene.json", "general": ["properties": [
            "magnification": ["type": "slider", "value": 1, "min": 0.1, "max": 4]
        ]]]
        try JSONSerialization.data(withJSONObject: raw).write(to: root.appendingPathComponent("scene.json"))
        try JSONSerialization.data(withJSONObject: project).write(to: root.appendingPathComponent("project.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
