import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct EffectAccessTests {
    @Test(arguments: [false, true])
    func namedAndIndexedEffectsControlTheRenderedChain(text: Bool) throws {
        let fixture = try Fixture(text: text, script: """
            const target = thisScene.getLayer('Target');
            const effect = target.getEffect('Tint');
            export function update() {
                if (effect !== target.getEffect(0) || target.getEffectCount() !== 2 ||
                    target.getEffect(-1) !== undefined || target.getEffect(0.5) !== undefined ||
                    target.getEffect('missing') !== undefined) throw new Error('effect lookup mismatch');
                effect.name = 'Renamed';
                if (target.getEffect('Renamed') !== effect) throw new Error('name not live');
                effect.visible = engine.userProperties.shown;
                return new Vec3(target.getEffectCount(), 0, 0);
            }
            """)
        let hidden = fixture.runtime.step(deltaTime: 0)
        #expect(hidden.nodes[0].worldPosition.x == 2)
        #expect(hidden.nodes[1].imageEffects.map(\.sourceIndex) == [1])
        let visible = fixture.runtime.step(deltaTime: 0, propertyOverrides: ["shown": .bool(true)])
        #expect(visible.nodes[1].imageEffects.map(\.sourceIndex) == [0, 1])
    }

    @Test func materialWritesUseOverridesAndSkipCommandPasses() throws {
        let fixture = try Fixture(script: """
            const effect = thisScene.getLayer('Target').getEffect('Tint');
            const material = effect.getMaterial();
            export function update() {
                if (effect.getMaterialCount() !== 2 || effect.getMaterial(0) !== material ||
                    effect.getMaterial(-1) !== undefined || effect.getMaterial(2) !== undefined ||
                    material.gain !== 0.7 || material.baseOnly !== 3) throw new Error('material defaults mismatch');
                material.gain = 0.2;
                material.tint.y = 0.75;
                effect.setMaterialProperty('baseOnly', 9);
                effect.setMaterialProperty('absent', 5);
                if ('absent' in material || effect.getMaterial(1).baseOnly !== 9) throw new Error('broadcast mismatch');
                return new Vec3(material.gain, material.tint.y, 1);
            }
            """)
        let frame = fixture.runtime.step(deltaTime: 0)
        #expect(frame.nodes[0].worldPosition == RuntimeVector3(x: 0.2, y: 0.75, z: 1))
        let passes = frame.materials.filter { $0.sourceFile == "first.json" }.flatMap(\.passes)
        #expect(passes.first?.constants["gain"] == .double(0.2))
        #expect(passes.first?.constants["tint"] == .vec3([0.1, 0.75, 0.3]))
        #expect(passes.first?.constants["baseOnly"] == .int(9))
        #expect(frame.materials.first { $0.sourceFile == "second.json" }?.passes.first?.constants["baseOnly"] == .int(9))
    }

    @Test func materialScriptsAndRetainedLookupsShareTimelineAndObjectIdentity() throws {
        let animated: [String: Any] = ["value": 0, "animation": [
            "c0": [["frame": 0, "value": 0], ["frame": 20, "value": 1]],
            "options": ["fps": 10, "length": 20, "mode": "single", "name": "fade", "startpaused": true],
        ], "script": """
            export function init(value) {
                const material = thisLayer.getEffect('Tint').getMaterial();
                if (thisObject !== material || thisObject.getAnimation() !== material.getAnimation('fade'))
                    throw new Error('material script identity mismatch');
                shared.materialIdentityChecked = true;
                return value;
            }
            export function update(value) { return value; }
            """]
        let fixture = try Fixture(gain: animated, script: """
            const material = thisScene.getLayer('Target').getEffect(0).getMaterial();
            export function update() {
                if (!shared.materialIdentityChecked) throw new Error('material initializer failed');
                const animation = material.getAnimation('fade');
                animation.setFrame(10);
                return new Vec3(material.gain, animation.getFrame(), 1);
            }
            """)
        for _ in 0..<2 {
            let frame = fixture.runtime.step(deltaTime: 0)
            #expect(frame.nodes[0].worldPosition == RuntimeVector3(x: 0.5, y: 10, z: 1))
            #expect(frame.materials.first { $0.sourceFile == "first.json" }?.passes.first?.constants["gain"] == .double(0.5))
        }
    }

    @Test func createdEffectsAndMaterialsAreIndependentOfTheirTemplate() throws {
        let fixture = try Fixture(script: """
            let created, retained;
            export function init() {
                const config = thisScene.getInitialLayerConfig('Target');
                config.name = 'Created';
                created = thisScene.createLayer(config);
                retained = created.getEffect('Tint').getMaterial();
                retained.gain = 0.3;
                return new Vec3(0);
            }
            export function update() {
                if (created.getEffect(0).getMaterial() !== retained ||
                    thisScene.getLayer('Target').getEffect(0).getMaterial().gain !== 0.7)
                    throw new Error('material references leaked');
                retained.gain += 0.1;
                return new Vec3(retained.gain, 0, 1);
            }
            """)
        let first = fixture.runtime.step(deltaTime: 0)
        #expect(first.nodes.count == 3)
        #expect(abs(first.nodes[0].worldPosition.x - 0.4) < 0.00001)
        #expect(abs(fixture.runtime.step(deltaTime: 0).nodes[0].worldPosition.x - 0.5) < 0.00001)
    }

    @Test func materialVectorComponentsReachEveryUnderlyingShaderPass() throws {
        let fixture = try Fixture(materialPassCount: 2, script: """
            export function update() {
                const effect = thisScene.getLayer('Target').getEffect(0);
                const material = effect.getMaterial();
                material.tint = new Vec3(0.2, 0.3, 0.4);
                material.tint.y = 0.8;
                material.baseOnly = 7;
                return new Vec3(material.tint.y, effect.getMaterialCount(), 1);
            }
            """)
        let frame = fixture.runtime.step(deltaTime: 0)
        #expect(frame.nodes[0].worldPosition == RuntimeVector3(x: 0.8, y: 2, z: 1))
        let passes = try #require(frame.materials.first { $0.sourceFile == "first.json" }).passes
        #expect(passes.count == 2)
        #expect(passes.allSatisfy { $0.constants["tint"] == .vec3([0.2, 0.8, 0.4]) && $0.constants["baseOnly"] == .int(7) })
    }

    @Test func retainedMaterialsReceiveLiveAuthoredPropertyChanges() throws {
        let fixture = try Fixture(gain: ["value": 0.7, "user": "amount"], script: """
            const material = thisScene.getLayer('Target').getEffect(0).getMaterial();
            export function update() { return new Vec3(material.gain, 0, 1); }
            """)
        for value in [0.25, 0.8, 0.1] {
            let frame = fixture.runtime.step(deltaTime: 0, propertyOverrides: ["amount": .double(value)])
            #expect(abs(Double(frame.nodes[0].worldPosition.x) - value) < 0.00001)
            #expect(frame.materials.first { $0.sourceFile == "first.json" }?.passes.first?.constants["gain"] == .double(value))
        }
    }

    private final class Fixture {
        let root: URL
        let runtime: SceneRuntime

        init(text: Bool = false, gain: Any = 0.7, materialPassCount: Int = 1, script: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("WEEffectAccess-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var target: [String: Any] = ["id": 1, "name": "Target", "image": "model.json", "effects": [
                ["file": "effect.json", "name": "Tint", "id": 100, "passes": [
                    ["id": 800, "constantshadervalues": ["gain": gain]],
                ]],
                ["file": "empty-effect.json", "name": "Other", "id": 101],
            ]]
            if text { target.removeValue(forKey: "image"); target["text"] = "Test" }
            let files: [String: Any] = [
                "project.json": ["type": "scene", "file": "scene.json", "general": ["properties": [
                    "shown": ["type": "bool", "value": false], "amount": ["type": "slider", "value": 0.7],
                ]]],
                "scene.json": ["camera": [:], "general": [:], "objects": [
                    ["id": 90, "name": "Controller", "image": "missing.json", "origin": ["value": "0 0 0", "script": script]], target,
                ]],
                "model.json": ["material": "base.json", "width": 32, "height": 32],
                "base.json": ["passes": [["shader": "unused"]]],
                "effect.json": ["passes": [["command": "copy", "source": "previous", "target": "copy"], ["material": "first.json"], ["material": "second.json"]]],
                "empty-effect.json": ["passes": []],
                "first.json": ["passes": Array(repeating: ["shader": "unused", "constantshadervalues": ["gain": 0.1, "baseOnly": 3, "tint": "0.1 0.2 0.3"]] as [String: Any], count: materialPassCount)],
                "second.json": ["passes": [["shader": "unused", "constantshadervalues": ["baseOnly": 4]]]],
            ]
            for (name, value) in files {
                try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
            }
            runtime = SceneRuntime(scene: try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path), assetRoots: [root])
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
