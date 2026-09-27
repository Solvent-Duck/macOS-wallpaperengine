import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct SceneInitializationTests {
    @Test(arguments: ["0", "1", "2", "true", "false", "001", " hello "])
    func savedScalarScriptPropertiesKeepTheirStringType(saved: String) throws {
        let source = """
        const props = createScriptProperties()
            .addCombo({name:'choice',options:[{value:'0'},{value:'1'}]})
            .addText({name:'label',value:''}).finish();
        export function update() {
            return new Vec3(typeof props.choice === 'string' ? props.choice.length : -1,
                            typeof props.label === 'string' ? props.label.length : -1, 0);
        }
        """
        let original = try fixture([
            ["id": 1, "origin": ["value": "0 0 0", "script": source,
                "scriptproperties": ["choice": saved, "label": saved]]],
            ["id": 2, "origin": ["value": "0 0 0", "script": source,
                "scriptproperties": ["choice": ["value": saved], "label": ["value": saved]]]],
        ])
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(original))
        let frame = SceneRuntime(scene: restored).step(deltaTime: 0)
        for node in frame.nodes {
            #expect(node.worldPosition.x == Float(saved.count))
            #expect(node.worldPosition.y == Float(saved.count))
        }
    }

    @Test func comboPropertiesUseTheFirstOptionWhenNoDefaultIsAuthored() throws {
        let host = ScriptHost()
        let source = """
        const props = createScriptProperties()
            .addCombo({name:'language',options:[{value:'en'},{value:'ja'}]})
            .addCombo({name:'explicit',value:'ja',options:[{value:'en'},{value:'ja'}]})
            .addCombo({name:'zero',value:0,options:[{value:5},{value:0}]})
            .finish();
        const languages = {en:'Sunday',ja:'日曜日'};
        let initial;
        export function init() { initial = languages[props.language].length; }
        export function update() {
            if (props.explicit !== 'ja' || props.zero !== 0) return -1;
            return initial + languages[props.language].length;
        }
        """
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(12))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: ["language": .string("ja")]) == .int(9))
        #expect(try ScriptHost().evaluate(source: source, baseValue: .int(0), properties: ["language": .string("ja")]) == .int(6))
    }

    @Test func initialPropertyEventsWaitForEveryLayersInitialization() throws {
        let recorder = """
        export function init(value) { shared.depths.push(value.x); return value; }
        export function applyUserProperties() {
            if (shared.maximum === undefined) { thisLayer.origin.x = -1; return; }
            thisLayer.origin.x = shared.maximum * engine.userProperties.factor;
        }
        """
        let runtime = SceneRuntime(scene: try fixture([
            ["id": 90, "visible": ["value": false, "script": "shared.depths = [];"]],
            ["id": 1, "origin": ["value": "2 0 0", "script": recorder]],
            ["id": 2, "origin": ["value": "5 0 0", "script": recorder]],
            ["id": 3, "visible": ["value": false, "script": "export function init() { shared.maximum = Math.max(...shared.depths); }"]],
        ], properties: ["factor": ["type": "slider", "value": 2]]))
        #expect(runtime.step(deltaTime: 0).nodes.map(\.worldPosition.x) == [0, 10, 10, 0])
        #expect(runtime.step(deltaTime: 0, propertyOverrides: ["factor": .int(3)]).nodes.map(\.worldPosition.x) == [0, 15, 15, 0])
    }

    @Test func firstUpdateCanUseALaterComponentsInitializedLibrary() throws {
        let runtime = SceneRuntime(scene: try fixture([
            ["id": 1, "origin": ["value": "0 0 0", "script": """
            export function update() { return new Vec3(shared.componentValue ? shared.componentValue() : -1, 0, 0); }
            """]],
            ["id": 2, "image": "missing.json", "effects": [["file": "missing-effect.json", "visible": ["value": true, "script": """
            export function init() { shared.componentValue = () => 42; }
            """]]]],
        ]))
        #expect(runtime.step(deltaTime: 0).nodes[0].worldPosition.x == 42)
    }

    @Test func initialMediaEventsWaitForLaterLayerInitialization() throws {
        let runtime = SceneRuntime(scene: try fixture([
            ["id": 1, "image": "missing.json", "visible": ["value": true, "script": """
            export function mediaPlaybackChanged(e) {
                if (!shared.ready) throw new Error('media arrived before initialization');
                thisLayer.visible = e.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
            }
            """]],
            ["id": 2, "visible": ["value": false, "script": "export function init() { shared.ready = true; }"]],
        ]))
        #expect(runtime.step(deltaTime: 0).nodes[0].visible == false)
    }

    @Test func timersRunAfterSceneInitializationAndDoNotAdvanceTwice() throws {
        let runtime = SceneRuntime(scene: try fixture([
            ["id": 1, "origin": ["value": "0 0 0", "script": """
            let calls = 0, ready = false, inits = 0;
            thisScene.getLayer('Later').origin.y = 7;
            engine.setTimeout(() => { calls++; ready = !!shared.ready; }, 0);
            export function init(value) { inits++; return value; }
            export function update() { return new Vec3(ready ? calls : -1, inits, 0); }
            """]],
            ["id": 2, "name": "Later", "visible": ["value": false, "script": "export function init() { shared.ready = true; }"]],
        ]))
        for _ in 0..<2 {
            let frame = runtime.step(deltaTime: 0)
            #expect(frame.nodes[0].worldPosition == RuntimeVector3(x: 1, y: 1, z: 0))
            #expect(frame.nodes[1].worldPosition == RuntimeVector3(x: 0, y: 7, z: 0))
        }
    }

    @Test func emptyUserPropertiesStillReceiveOneInitialCallback() throws {
        let host = ScriptHost()
        let source = """
        let calls = 0;
        export function applyUserProperties(properties) {
            if (Object.keys(properties).length) throw new Error('unexpected property');
            calls++;
        }
        export function update() { return calls; }
        """
        for _ in 0..<2 {
            #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(1))
        }
    }

    @Test func pausedInitializationAndRestartPreserveThePhaseBoundary() throws {
        let runtime = SceneRuntime(scene: try fixture([
            ["id": 1, "image": "missing.json", "alpha": ["value": 1, "script": """
            export function init() {
                shared.calls = (shared.calls || 0) + 1;
                thisLayer.origin = new Vec3(0, 7, 0);
                engine.setTimeout(() => { thisLayer.origin.z = 1; }, 0);
            }
            export function applyUserProperties() { thisLayer.origin.x = shared.ready ? shared.calls : -1; }
            """]],
            ["id": 2, "visible": ["value": false, "script": "export function init() { shared.ready = true; }"]],
        ]))
        runtime.setPaused(true)
        for _ in 0..<2 {
            #expect(runtime.step(deltaTime: 10).nodes[0].worldPosition == RuntimeVector3(x: 1, y: 7, z: 0))
        }
        #expect(runtime.elapsedTime == 0)
        runtime.setPaused(false)
        #expect(runtime.step(deltaTime: 0).nodes[0].worldPosition == RuntimeVector3(x: 1, y: 7, z: 1))
        runtime.shutdown()
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 10).nodes[0].worldPosition == RuntimeVector3(x: 2, y: 7, z: 0))
    }

    @Test func soundLayersKeepLogicalTransportAndResolvedVolume() throws {
        let runtime = SceneRuntime(scene: try fixture([["id": 71, "type": "sound", "sound": ["track.ogg"],
            "playbackmode": "single", "startsilent": true,
            "volume": ["value": 0.25, "script": "export function update(value) { return value + 0.25; }"],
            "origin": ["value": "0 0 0", "script": """
            export function init() { thisLayer.play(); thisLayer.volume = 0.75; thisLayer.pause(); thisLayer.play(); }
            """]
        ]]))
        var packet = runtime.step(deltaTime: 0)
        #expect(packet.soundTransports.count == 1)
        #expect(packet.soundTransports[0].state == .playing)
        #expect(packet.soundTransports[0].runID == 1)
        #expect(packet.soundTransports[0].gain == 0.75)
        runtime.updateSoundPlaybackStatus(nodeID: NodeID(rawValue: 71), runID: 0, finished: true)
        #expect(runtime.step(deltaTime: 0).soundTransports[0].state == .playing)
        runtime.updateSoundPlaybackStatus(nodeID: NodeID(rawValue: 71), runID: 1, finished: true)
        packet = runtime.step(deltaTime: 0)
        #expect(packet.soundTransports[0].state == .stopped)
    }

    private func fixture(_ nodes: [[String: Any]], properties: [String: Any] = [:]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEInitialization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": properties]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": nodes])
            .write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
