import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct CursorInputTests {
    @Test(arguments: [1.0, 2.0])
    func worldPositionUsesTheTwoDimensionalCamera(zoom: Double) throws {
        let scene = try fixture(script: """
        export function update() {
            if (!(input.cursorWorldPosition instanceof Vec3)) return new Vec3(-1);
            return input.cursorWorldPosition.copy();
        }
        """, zoom: zoom)
        let frame = SceneRuntime(scene: scene).step(deltaTime: 0, cursorPosition: .init(x: 0.75, y: 0.25))
        let point = try #require(frame.nodes.first).worldPosition
        #expect(abs(point.x - Float(100 + 50 / zoom)) < 0.001)
        #expect(abs(point.y - Float(50 - 25 / zoom)) < 0.001)
        #expect(point.z == 0)
    }

    @Test func screenCoordinatesStartAtTheTopLeft() throws {
        let scene = try fixture(script: """
        export function update() {
            const p = input.cursorScreenPosition;
            return new Vec3(p.x, p.y, input.cursorLeftDown ? 1 : 0);
        }
        """)
        let frame = SceneRuntime(scene: scene).step(deltaTime: 0, cursorPosition: .init(x: 0.75, y: 0.25))
        #expect(frame.nodes.first?.worldPosition == RuntimeVector3(x: 150, y: 75, z: 0))
    }

    @Test func displaySizeAndButtonChangesReachScripts() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function update() {
            if (engine.canvasSize.x !== 200 || engine.canvasSize.y !== 100) return new Vec3(-1);
            if (engine.screenResolution.x !== 400 || engine.screenResolution.y !== 300) return new Vec3(-2);
            return new Vec3(input.cursorScreenPosition.x, input.cursorScreenPosition.y, input.cursorLeftDown ? 1 : 0);
        }
        """))
        for pressed in [true, true, false] {
            let frame = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.75, y: 0.25),
                cursorLeftDown: pressed, viewportSize: .init(x: 400, y: 300))
            #expect(frame.nodes.first?.worldPosition == RuntimeVector3(x: 300, y: 225, z: pressed ? 1 : 0))
        }
    }

    @Test func worldCoordinatesIncludeCameraRollAndEyeTranslation() throws {
        let runtime = SceneRuntime(scene: try fixture(script: "export function update() { return input.cursorWorldPosition; }",
            camera: ["eye": "23 -9 1", "center": "23 -9 0", "up": "1 0 0"]))
        let frame = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.75, y: 0.25))
        let point = try #require(frame.nodes.first).worldPosition
        // Inverting the rolled view also retains the projection's eye offset.
        #expect(abs(point.x - 107) < 0.001)
        #expect(abs(point.y - 14) < 0.001)
    }

    @Test func scriptedZoomPublishesBeforeLayerInputWithoutRecursiveEvaluation() throws {
        let runtime = SceneRuntime(scene: try fixture(script: "export function update() { return input.cursorWorldPosition; }",
            zoom: ["value": 1, "script": "export function update() { return input.cursorLeftDown ? 4 : 2; }"]))
        for (pressed, expected) in [(false, Float(125)), (true, Float(112.5))] {
            let frame = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.75, y: 0.5), cursorLeftDown: pressed)
            #expect(abs(try #require(frame.nodes.first).worldPosition.x - expected) < 0.001)
        }
    }

    @Test func pointerHistoryFollowsRenderedFramesAndResetsAfterAbsentInput() throws {
        let runtime = SceneRuntime(scene: try fixture(script: "export function update(v) { return v; }"))
        let a = RuntimeVector2(x: 0.2, y: 0.3), b = RuntimeVector2(x: 0.8, y: 0.6)
        #expect(runtime.step(deltaTime: 0, cursorPosition: a).cursor?.previousNormalized == a)
        #expect(runtime.step(deltaTime: 0, cursorPosition: b).cursor?.previousNormalized == a)
        #expect(runtime.step(deltaTime: 0, cursorPosition: b).cursor?.previousNormalized == b)
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 1, cursorPosition: a, cursorLeftDown: true).cursor?.leftDown == true)
        #expect(runtime.step(deltaTime: 1, cursorPosition: b).cursor?.previousNormalized == a)
        #expect(runtime.step(deltaTime: 0).cursor == nil)
        #expect(runtime.step(deltaTime: 0, cursorPosition: a).cursor?.previousNormalized == a)
        runtime.shutdown()
        #expect(runtime.step(deltaTime: 0, cursorPosition: b).cursor?.previousNormalized == b)
    }

    @Test func absentInputHasTypedDefaultsAndOffscreenInputKeepsItsCoordinates() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function update() {
            if (!(input.cursorWorldPosition instanceof Vec3) || !(input.cursorScreenPosition instanceof Vec2)) return new Vec3(-1);
            return input.cursorWorldPosition;
        }
        """))
        #expect(runtime.step(deltaTime: 0).nodes.first?.worldPosition == .zero)
        let point = runtime.step(deltaTime: 0, cursorPosition: .init(x: -0.25, y: 1.5)).nodes.first?.worldPosition
        #expect(abs(try #require(point).x + 50) < 0.001)
        #expect(abs(try #require(point).y - 150) < 0.001)
    }

    @Test func oldCursorPacketsDecodeWithStationaryReleasedDefaults() throws {
        let state = try JSONDecoder().decode(RuntimeCursorState.self, from: Data("""
        {"normalized":{"x":0.2,"y":0.3},"parallaxDisplacement":{"x":0,"y":0}}
        """.utf8))
        #expect(state.previousNormalized == state.normalized)
        #expect(!state.leftDown)
        #expect(try JSONDecoder().decode(RuntimeCursorState.self, from: JSONEncoder().encode(state)) == state)
    }

    private func fixture(script: String, zoom: Any = 1, camera: [String: Any] = [:]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WECursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json"])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: [
            "camera": camera,
            "general": ["orthogonalprojection": ["width": 200, "height": 100], "zoom": zoom],
            "objects": [["id": 1, "origin": ["value": "0 0 0", "script": script]]],
        ]).write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
