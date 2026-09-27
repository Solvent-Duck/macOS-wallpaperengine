import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct SoundTransportTests {
    @Test func parserPreservesStartSilentAndObjectVolumeThroughCodable() throws {
        let scene = try fixture(sound: ["id": 4, "type": "sound", "sound": ["a.ogg"], "startsilent": true,
            "volume": ["value": 0.35, "user": "mix"]])
        let sound = try #require(scene.nodes.first?.sound)
        #expect(sound.startSilent)
        #expect(sound.volume == 0.35)
        #expect(sound.volumeSetting?.runtimeKey == "scene.node.4.volume")
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(scene))
        #expect(restored.nodes[0].sound?.startSilent == true)
        #expect(restored.nodes[0].sound?.volume == 0.35)
        let legacy = try JSONDecoder().decode(SoundDescriptor.self, from: Data(#"{"playbackMode":"loop","sounds":["a.ogg"],"volume":0.4,"minTime":0,"maxTime":0}"#.utf8))
        #expect(!legacy.startSilent && legacy.volumeSetting == nil && legacy.volume == 0.4)
    }

    @Test func soundTransportHasRunIdentityOverridesAndTerminalState() throws {
        let runtime = SceneRuntime(scene: try fixture(sound: ["id": 5, "type": "sound", "sound": ["a.ogg"], "startsilent": true,
            "origin": ["value": "0 0 0", "script": """
            export function init() { thisLayer.play(); thisLayer.pause(); thisLayer.play(); thisLayer.volume = 0.75; }
            export function update() { return new Vec3(thisLayer.isPlaying() ? 1 : 0, thisLayer.volume, 0); }
            """]]))
        var packet = runtime.step(deltaTime: 0)
        #expect(packet.soundTransports[0].state == .playing)
        #expect(packet.soundTransports[0].runID == 1)
        #expect(packet.soundTransports[0].gain == 0.75)
        #expect(packet.nodes[0].worldPosition == RuntimeVector3(x: 1, y: 0.75, z: 0))
        runtime.updateSoundPlaybackStatus(nodeID: NodeID(rawValue: 5), runID: 0, finished: true)
        #expect(runtime.step(deltaTime: 0).soundTransports[0].state == .playing)
        runtime.updateSoundPlaybackStatus(nodeID: NodeID(rawValue: 5), runID: 1, finished: true)
        packet = runtime.step(deltaTime: 0)
        #expect(packet.soundTransports[0].state == .stopped)
        #expect(packet.nodes[0].worldPosition == RuntimeVector3(x: 0, y: 0.75, z: 0))
    }

    @Test func stopThenPlayCreatesNewRunWhilePauseThenPlayDoesNotAndFailureLatches() throws {
        let runtime = SceneRuntime(scene: try fixture(sound: ["id": 8, "type": "sound", "sound": ["a.ogg"], "startsilent": false,
            "origin": ["value": "0 0 0", "script": """
            let calls = 0;
            export function update() {
              calls++;
              if (calls === 1) { thisLayer.pause(); thisLayer.play(); }
              else if (calls === 2) { thisLayer.stop(); thisLayer.play(); }
              else { thisLayer.play(); }
            }
            """]]))
        #expect(runtime.step(deltaTime: 0).soundTransports[0].runID == 1)
        #expect(runtime.step(deltaTime: 0).soundTransports[0].runID == 2)
        runtime.updateSoundPlaybackStatus(nodeID: NodeID(rawValue: 8), runID: 2, finished: false)
        #expect(runtime.step(deltaTime: 0).soundTransports[0].state == .failed)
        #expect(runtime.step(deltaTime: 0).soundTransports[0].runID == 2)
    }

    @Test func pausingAStoppedOrCompletedSoundDoesNotReuseItsRun() throws {
        let scene = try fixture(sound: ["id": 8, "sound": ["a.ogg"], "startsilent": true,
            "origin": ["value": "0 0 0", "script": """
            export function update() { thisLayer.pause(); thisLayer.play(); }
            """]])
        let runtime = SceneRuntime(scene: scene)
        #expect(runtime.step(deltaTime: 0).soundTransports[0].runID == 1)
        runtime.updateSoundPlaybackStatus(nodeID: NodeID(rawValue: 8), runID: 1, finished: true)
        let restarted = runtime.step(deltaTime: 0).soundTransports[0]
        #expect(restarted.state == .playing)
        #expect(restarted.runID == 2)
    }

    @Test func liveUserAndScriptVolumeDrivePacketGainAndNonSoundHasNoAPI() throws {
        let scene = try fixture(sound: ["id": 6, "name": "Sound", "type": "sound", "sound": ["a.ogg"],
            "volume": ["value": 0.2, "user": "mix", "script": "export function update(value) { return 0.2 + engine.userProperties.mix; }"]],
            properties: ["mix": ["type": "slider", "value": 0.3]], extra: [["id": 7, "origin": ["value": "0 0 0", "script": "export function update(value) { return new Vec3(typeof thisLayer.play === 'undefined' ? 9 : -1, thisScene.getLayer('Sound').volume, 0); }"]]])
        let runtime = SceneRuntime(scene: scene)
        let first = runtime.step(deltaTime: 0)
        #expect(first.soundTransports[0].gain == 0.5)
        #expect(first.nodes.first(where: { $0.nodeID == NodeID(rawValue: 7) })?.worldPosition.x == 9)
        #expect(first.nodes.first(where: { $0.nodeID == NodeID(rawValue: 7) })?.worldPosition.y == 0.5)
        let second = runtime.step(deltaTime: 0, propertyOverrides: ["mix": .double(0.4)])
        #expect(second.soundTransports[0].gain == 0.6)
        #expect(second.nodes.first(where: { $0.nodeID == NodeID(rawValue: 7) })?.worldPosition.y == 0.6)
    }

    @Test func userBoundVolumeWithoutAScriptUpdatesTheLayerGetterAndPacket() throws {
        let scene = try fixture(sound: ["id": 6, "name": "Sound", "sound": ["a.ogg"],
            "volume": ["value": 0.2, "user": "mix"]],
            properties: ["mix": ["type": "slider", "value": 0.3]],
            extra: [["id": 7, "origin": ["value": "0 0 0", "script": "export function update() { return new Vec3(thisScene.getLayer('Sound').volume, 0, 0); }"]]])
        let runtime = SceneRuntime(scene: scene)
        for gain in [0.3, 0.4] {
            let packet = runtime.step(deltaTime: 0, propertyOverrides: ["mix": .double(gain)])
            #expect(packet.soundTransports[0].gain == Float(gain))
            #expect(packet.nodes.first(where: { $0.nodeID == NodeID(rawValue: 7) })?.worldPosition.x == Float(gain))
        }
    }

    @Test func aLaterSetterDoesNotHideTheNextUnchangedVolumeScriptResult() throws {
        let scene = try fixture(sound: ["id": 6, "name": "Sound", "sound": ["a.ogg"],
            "volume": ["value": 0.5, "script": "export function update() { return 0.5; }"]],
            extra: [["id": 7, "origin": ["value": "0 0 0", "script": """
            let calls = 0;
            export function update() {
                if (++calls === 1) thisScene.getLayer('Sound').volume = 0.8;
                return new Vec3(thisScene.getLayer('Sound').volume, 0, 0);
            }
            """]]])
        let runtime = SceneRuntime(scene: scene)
        let written = runtime.step(deltaTime: 0)
        #expect(written.soundTransports[0].gain == 0.8)
        #expect(written.nodes.first(where: { $0.nodeID == NodeID(rawValue: 7) })?.worldPosition.x == 0.8)
        let next = runtime.step(deltaTime: 0)
        #expect(next.soundTransports[0].gain == 0.5)
        #expect(next.nodes.first(where: { $0.nodeID == NodeID(rawValue: 7) })?.worldPosition.x == 0.5)
    }

    private func fixture(sound: [String: Any], properties: [String: Any] = [:], extra: [[String: Any]] = []) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WESoundTransport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": properties]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": [sound] + extra])
            .write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
