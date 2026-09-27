import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing
import simd

struct ParticleControlPointTests {
    @Test(arguments: [0, 2])
    func authoredControlPointsRespectTheirCoordinateSpace(flags: Int) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 0, "instantaneous": 1]],
            controlPoints: [["id": 1, "flags": flags, "offset": "120 80 0"]],
            nodeSettings: ["origin": "100 50 0"]))
        let point = try #require(runtime.step(deltaTime: 0.1).particleSystems.first?.instances.first).position
        #expect(point == (flags == 2 ? RuntimeVector3(x: 20, y: 30, z: 0) : RuntimeVector3(x: 120, y: 80, z: 0)))
    }

    @Test(arguments: [false, true])
    func scriptsCanReplaceAndEditControlPointVectors(worldSpace: Bool) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 4]],
            controlPoints: [["id": 1, "flags": worldSpace ? 2 : 0, "offset": "0 0 0"]],
            nodeSettings: ["origin": ["value": "100 50 0", "script": """
            const instance = thisLayer.instance;
            export function init(value) { instance.controlpoint1 = new Vec3(120, 80, 0); return value; }
            export function update(value) {
                if (!(instance.controlpoint1 instanceof Vec3)) throw new Error('control point is not a vector');
                instance.controlpoint1.x += 4;
                return value;
            }
            """]]))
        let offset: Float = worldSpace ? 100 : 0
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.last?.position.x == 124 - offset)
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.last?.position.x == 128 - offset)
    }

    @Test func omittedControlPointsStillHaveWritableDefaults() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 7, "rate": 0, "instantaneous": 1]],
            nodeSettings: ["origin": ["value": "0 0 0", "script": """
            export function init(value) {
                for (let i = 0; i < 8; ++i) {
                    const point = thisLayer.instance['controlpoint' + i];
                    if (!(point instanceof Vec3) || point.length() !== 0) throw new Error('missing default point');
                }
                thisLayer.instance.controlpoint7.y = 25;
                return value;
            }
            """]]))
        #expect(runtime.step(deltaTime: 0.1).particleSystems.first?.instances.first?.position.y == 25)
    }

    @Test(arguments: [0, 1, 2, 3])
    func controlPointZeroStaysAtTheSystemOrigin(flags: Int) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 0, "rate": 0, "instantaneous": 1]],
            controlPoints: [["id": 0, "flags": flags, "offset": "40 60 0"]],
            nodeSettings: ["origin": "100 50 0"]))
        let frame = runtime.step(deltaTime: 0.1, cursorPosition: RuntimeVector2(x: 0.5, y: 0.5))
        #expect(frame.particleSystems.first?.instances.first?.position == .zero)
    }

    @Test(arguments: [false, true])
    func worldAndPointerPointsUseTheFullLayerTransform(pointer: Bool) throws {
        let scene = try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 0, "instantaneous": 1]],
            controlPoints: [["id": 1, "flags": pointer ? 1 : 2, "offset": pointer ? "0 0 0" : "120 80 0"]],
            nodeSettings: ["origin": "100 50 0", "angles": "0 0 \(Double.pi / 2)", "scale": "2 3 1", "parent": 99],
            general: ["orthogonalprojection": ["width": 640, "height": 480]],
            additionalNodes: [["id": 99, "name": "Parent", "origin": "20 -10 0", "scale": "2 1 1"]])
        let projection = try #require(scene.scene?.camera.projection)
        let cursor = RuntimeVector2(x: 120 / Float(projection.width), y: 80 / Float(projection.height))
        let frame = SceneRuntime(scene: scene).step(deltaTime: 0.1, cursorPosition: cursor)
        let local = try #require(frame.particleSystems.first?.instances.first).position.simdValue
        let world = try #require(frame.nodes.first { $0.nodeID.rawValue == 1 }).worldTransform.simdValue * SIMD4(local, 1)
        #expect(abs(world.x - 120) < 0.0001 && abs(world.y - 80) < 0.0001)
    }

    @Test func userBindingsAndValueScriptsDriveControlPoints() throws {
        let scene = try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 4]],
            controlPoints: [["id": 1, "offset": ["value": "10 20 0", "script": """
            export function update(value) {
                if (thisObject !== thisLayer.instance) throw new Error('wrong control point owner');
                return new Vec3(engine.userProperties.target, value.y, 0);
            }
            """]]], properties: ["target": ["type": "slider", "value": 30]])
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(scene))
        #expect(restored == scene)
        let runtime = SceneRuntime(scene: restored)
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.last?.position == RuntimeVector3(x: 30, y: 20, z: 0))
        #expect(runtime.step(deltaTime: 0.25, propertyOverrides: ["target": .double(70)]).particleSystems.first?.instances.last?.position.x == 70)
    }

    @Test func controlPointTimelinesAdvanceAndCanBePausedFromScripts() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 4]],
            controlPoints: [["id": 1, "offset": ["value": "0 20 0", "animation": [
                "options": ["name": "Path", "fps": 4, "length": 4, "mode": "single"],
                "c0": [["frame": 0, "value": 0], ["frame": 4, "value": 40]],
            ]]]], nodeSettings: ["origin": ["value": "0 0 0", "script": """
            export function update(value) {
                if (engine.runtime >= 0.5) thisLayer.instance.getAnimation('Path').pause();
                return value;
            }
            """]]))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.last?.position == RuntimeVector3(x: 10, y: 20, z: 0))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.last?.position.x == 20)
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.last?.position.x == 20)
    }

    @Test func legacyOffsetsRemainWritableAfterDecoding() throws {
        let scene = try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 0, "instantaneous": 1]],
            controlPoints: [["id": 1, "offset": "40 60 0"]],
            nodeSettings: ["origin": ["value": "0 0 0", "script": """
            export function init(value) { thisLayer.instance.controlpoint1.x += 10; return value; }
            """]])
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as? [String: Any])
        var graph = try #require(encoded["scene"] as? [String: Any])
        var nodes = try #require(graph["nodes"] as? [[String: Any]])
        var particle = try #require(nodes[0]["particle"] as? [String: Any])
        var points = try #require(particle["controlPoints"] as? [[String: Any]])
        points = points.filter { $0["id"] as? Int == 1 }
        points[0].removeValue(forKey: "offsetSetting")
        particle["controlPoints"] = points; nodes[0]["particle"] = particle
        graph["nodes"] = nodes; encoded["scene"] = graph
        let legacy = try JSONDecoder().decode(SceneDescription.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(legacy.nodes[0].particle?.controlPoints[0].offsetSetting == nil)
        #expect(SceneRuntime(scene: legacy).step(deltaTime: 0.1).particleSystems.first?.instances.first?.position == RuntimeVector3(x: 50, y: 60, z: 0))
    }

    @Test func singularLayerTransformsKeepWorldControlPointsFinite() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "controlpoint": 1, "rate": 0, "instantaneous": 1]],
            controlPoints: [["id": 1, "flags": 2, "offset": "120 80 0"]],
            nodeSettings: ["origin": "100 50 0", "scale": "0 0 0"]))
        let point = try #require(runtime.step(deltaTime: 0.1).particleSystems.first?.instances.first).position
        #expect(point.x.isFinite && point.y.isFinite && point.z.isFinite)
    }
}
