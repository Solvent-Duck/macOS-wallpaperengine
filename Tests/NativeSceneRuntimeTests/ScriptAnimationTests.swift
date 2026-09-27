import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct ScriptAnimationTests {
    @Test func seekingUpdatesLayerReadsWithinTheSameScriptCall() throws {
        let script = """
        const target = thisScene.getLayer('Animated');
        const animation = target.getAnimation('move');
        export function update() {
            animation.pause();
            target.origin.x = 99;
            animation.setFrame(15);
            const sought = target.origin.x;
            animation.stop();
            return new Vec3(sought, target.origin.x, animation.getFrame());
        }
        """
        let runtime = SceneRuntime(scene: try fixture(controller: script))
        let packet = runtime.step(deltaTime: 0.5)
        #expect(packet.nodes[0].worldPosition == RuntimeVector3(x: 15, y: 0, z: 0))
        #expect(position(packet) == 0)
    }

    private let controller = """
    const animation = thisScene.getLayer('Animated').getAnimation('move');
    export function update() {
        switch (engine.userProperties.command) {
        case 'pause': animation.pause(); break;
        case 'play': animation.play(); break;
        case 'stop': animation.stop(); break;
        case 'seek': animation.setFrame(15); break;
        case 'double': animation.rate = 2; animation.play(); break;
        case 'reverse': animation.rate = -1; animation.play(); break;
        }
        return new Vec3(animation.getFrame(), animation.isPlaying() ? 1 : 0, animation.rate);
    }
    """

    @Test func namedTimelineControlsChangeRenderedValuesAndRetainTheirHandles() throws {
        let runtime = SceneRuntime(scene: try fixture(controller: controller))
        func step(_ delta: Double, _ command: String = "") -> FramePacket {
            runtime.step(deltaTime: delta, propertyOverrides: ["command": .string(command)])
        }
        #expect(position(step(0.5)) == 5)
        #expect(position(step(0.5, "pause")) == 10)
        #expect(position(step(10)) == 10)
        let sought = step(0, "seek")
        #expect(position(sought) == 15)
        #expect(sought.nodes[0].worldPosition == RuntimeVector3(x: 15, y: 0, z: 1))
        #expect(position(step(0, "double")) == 15)
        let ended = step(0.25)
        #expect(position(ended) == 20)
        #expect(ended.nodes[0].worldPosition.y == 0)
        #expect(position(step(0, "stop")) == 0)
        #expect(position(step(0, "play")) == 0)
        #expect(position(step(0.25)) == 5)
    }

    @Test func defaultAnimationLookupUsesTheCurrentPropertyAndMetadata() throws {
        let script = """
        const animation = thisObject.getAnimation();
        export function init(value) {
            if (!animation || animation !== thisObject.getAnimation('move') ||
                animation.fps !== 10 || animation.frameCount !== 20 || animation.duration !== 2 ||
                animation.name !== 'move' || thisObject.getAnimation('missing') !== undefined)
                throw new Error('timeline metadata mismatch');
            animation.pause();
            animation.setFrame(12);
            return value;
        }
        export function update(value) { return value; }
        """
        let runtime = SceneRuntime(scene: try fixture(animatedScript: script))
        #expect(position(runtime.step(deltaTime: 0.5)) == 12)
        #expect(position(runtime.step(deltaTime: 5)) == 12)
    }

    @Test func startPausedAndGlobalPauseKeepIndependentPlaybackState() throws {
        let runtime = SceneRuntime(scene: try fixture(controller: controller, startPaused: true))
        #expect(position(runtime.step(deltaTime: 1)) == 0)
        #expect(position(runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("play")])) == 0)
        #expect(position(runtime.step(deltaTime: 0.5)) == 5)
        runtime.setPaused(true)
        #expect(position(runtime.step(deltaTime: 100)) == 5)
        runtime.setPaused(false)
        #expect(position(runtime.step(deltaTime: 0.5)) == 10)
    }

    @Test(arguments: ["loop", "mirror"])
    func controlledTimelinesPreserveWrappingAndReversePlayback(mode: String) throws {
        let runtime = SceneRuntime(scene: try fixture(controller: controller, mode: mode))
        #expect(position(runtime.step(deltaTime: 1.5)) == 15)
        #expect(position(runtime.step(deltaTime: 1)) == (mode == "loop" ? 5 : 15))
        _ = runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("reverse")])
        #expect(position(runtime.step(deltaTime: 1)) == 15)
    }

    @Test func animationControlsDoNotLeakBetweenSceneInstances() throws {
        let scene = try fixture(controller: controller)
        let first = SceneRuntime(scene: scene), second = SceneRuntime(scene: scene)
        _ = first.step(deltaTime: 0, propertyOverrides: ["command": .string("seek")])
        #expect(position(first.step(deltaTime: 0.1)) == 16)
        #expect(position(second.step(deltaTime: 0.1)) == 1)
    }

    private func position(_ packet: FramePacket) -> Float {
        packet.nodes.first(where: { $0.nodeID.rawValue == 10 })!.worldPosition.x
    }

    private func fixture(controller: String? = nil, animatedScript: String? = nil,
                         mode: String = "single", startPaused: Bool = false) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEScriptTimeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var property: [String: Any] = ["value": "0 0 0", "animation": [
            "c0": [["frame": 0, "value": 0], ["frame": 20, "value": 20]],
            "options": ["fps": 10, "length": 20, "mode": mode, "name": "move", "startpaused": startPaused],
        ]]
        property["script"] = animatedScript
        var objects: [[String: Any]] = []
        if let controller { objects.append(["id": 90, "image": "missing.json", "origin": ["value": "0 0 0", "script": controller]]) }
        objects.append(["id": 10, "name": "Animated", "image": "missing.json", "origin": property])
        let scene: [String: Any] = ["camera": [:], "general": [:], "objects": objects]
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": [
            "command": ["type": "textinput", "value": ""],
        ]]]).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
