import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct PropertyAnimationTests {
    @Test(arguments: ["single", "loop", "mirror"])
    func playbackUsesAuthoredFramesAndSeconds(mode: String) throws {
        let scene = try fixture(alpha: animated(0, channels: ["c0": [key(0, 0), key(20, 1)]], mode: mode))
        let alpha = try #require(scene.nodes.first?.image?.alpha)
        #expect(scalar(alpha, scene, time: 0) == 0)
        #expect(scalar(alpha, scene, time: 1) == 0.5)
        #expect(scalar(alpha, scene, time: 2) == (mode == "loop" ? 0 : 1))
        #expect(scalar(alpha, scene, time: 3) == (mode == "single" ? 1 : 0.5))
        #expect(scalar(alpha, scene, time: 4) == (mode == "single" ? 1 : 0))
    }

    @Test func relativeChannelsPreserveUnanimatedComponents() throws {
        let scene = try fixture(origin: animated("10 20 30", channels: ["c0": [key(0, 0), key(20, 40)]], relative: true))
        let origin = try #require(scene.nodes.first?.origin)
        #expect(evaluator(scene, time: 1).vector3Value(for: origin, default: .zero) == RuntimeVector3(x: 30, y: 20, z: 30))
        #expect(evaluator(scene, time: 2).vector3Value(for: origin, default: .zero) == RuntimeVector3(x: 50, y: 20, z: 30))
    }

    @Test func bezierAndOneSidedHandlesEaseValues() throws {
        let eased = try fixture(alpha: animated(0, channels: ["c0": [key(0, 0, front: true), key(20, 1, back: true)]]))
        let alpha = try #require(eased.nodes.first?.image?.alpha)
        #expect(abs(scalar(alpha, eased, time: 0.5) - 0.15625) < 0.000001)
        #expect(abs(scalar(alpha, eased, time: 1.5) - 0.84375) < 0.000001)
        let oneSided = try fixture(alpha: animated(0, channels: ["c0": [key(0, 0, front: true), key(20, 1)]]))
        let oneAlpha = try #require(oneSided.nodes.first?.image?.alpha)
        #expect(abs(scalar(oneAlpha, oneSided, time: 1) - 0.375) < 0.000001)
    }

    @Test func wrappedLoopInterpolatesAcrossTheSeam() throws {
        let scene = try fixture(alpha: animated(0, channels: ["c0": [key(5, 0), key(15, 1)]], mode: "loop", wrap: true))
        let alpha = try #require(scene.nodes.first?.image?.alpha)
        #expect(scalar(alpha, scene, time: 0) == 0.5)
        #expect(scalar(alpha, scene, time: 0.5) == 0)
        #expect(scalar(alpha, scene, time: 1.75) == 0.75)
        #expect(scalar(alpha, scene, time: 2.25) == 0.25)
    }

    @Test func runtimePauseFreezesTimelineAndFrameRateDoesNotChangeSpeed() throws {
        let scene = try fixture(origin: animated("0 20 0", channels: ["c0": [key(0, 0), key(20, 40)]]))
        let runtime = SceneRuntime(scene: scene)
        #expect(runtime.step(deltaTime: 0.5).nodes.first?.worldPosition.x == 10)
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 20).nodes.first?.worldPosition.x == 10)
        runtime.setPaused(false)
        let resumed = runtime.step(deltaTime: 0.5)
        let direct = SceneRuntime(scene: scene).step(deltaTime: 1)
        #expect(resumed.nodes.first?.worldPosition == direct.nodes.first?.worldPosition)
    }

    @Test func startPausedAndEmptyCurvesKeepTheirInitialValues() throws {
        let paused = try fixture(alpha: animated(0.8, channels: ["c0": [key(0, 0.2), key(20, 1)]], paused: true))
        let alpha = try #require(paused.nodes.first?.image?.alpha)
        #expect(scalar(alpha, paused, time: 100) == 0.2)
        let empty = try fixture(alpha: animated(0.8, channels: ["c0": []]))
        #expect(scalar(try #require(empty.nodes.first?.image?.alpha), empty, time: 100) == 0.8)
    }

    @Test func duplicateAndUnsortedKeysAreNormalizedAndSerializationPreservesAnimation() throws {
        let scene = try fixture(alpha: animated(0, channels: ["c0": [key(20, 1), key(0, 0.25), key(0, 0)]]))
        let value = try #require(scene.nodes.first?.image?.alpha?.value)
        let decoded = try JSONDecoder().decode(DynamicValueDescriptor.self, from: JSONEncoder().encode(value))
        #expect(value == decoded)
        #expect(evaluator(scene, time: 1).evaluate(dynamicValue: decoded).doubleValue == 0.5)
        let legacy = try JSONDecoder().decode(DynamicValueDescriptor.self, from: Data(#"{"kind":"static","valueType":"float","value":0.5}"#.utf8))
        #expect(legacy.animation == nil)
        #expect(evaluator(scene, time: 1).evaluate(dynamicValue: legacy).doubleValue == 0.5)
    }

    private func evaluator(_ scene: SceneDescription, time: Double) -> PropertyEvaluator {
        PropertyEvaluator(scene: scene, context: PropertyEvaluationContext(elapsedTime: time, deltaTime: 0, frameIndex: 0))
    }

    private func scalar(_ setting: UserSettingDescriptor, _ scene: SceneDescription, time: Double) -> Double {
        evaluator(scene, time: time).scalarDouble(for: setting, default: -1)
    }

    private func key(_ frame: Double, _ value: Double, front: Bool = false, back: Bool = false) -> [String: Any] {
        ["frame": frame, "value": value, "front": ["enabled": front, "x": 1, "y": 0], "back": ["enabled": back, "x": -1, "y": 0]]
    }

    private func animated(_ value: Any, channels: [String: Any], mode: String = "single", relative: Bool = false, wrap: Bool = false, paused: Bool = false) -> [String: Any] {
        var animation = channels
        animation["options"] = ["fps": 10, "length": 20, "mode": mode, "wraploop": wrap, "startpaused": paused]
        animation["relative"] = relative
        return ["value": value, "animation": animation]
    }

    private func fixture(alpha: Any = 1, origin: Any = "0 0 0") throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WETimeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene: [String: Any] = ["camera": [:], "general": [:], "objects": [["id": 1, "image": "missing.json", "alpha": alpha, "origin": origin]]]
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json"]).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
