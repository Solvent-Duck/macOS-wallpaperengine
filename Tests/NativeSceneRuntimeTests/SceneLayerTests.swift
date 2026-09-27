import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct SceneLayerTests {
    @Test func explicitVisibilityWritesOverrideComboAssociationsAndPersist() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Day", "visible": ["value": true, "user": ["name": "mode", "condition": "0"]]],
            ["id": 2, "name": "Night", "visible": ["value": false, "user": ["name": "mode", "condition": "3"]]],
            ["id": 3, "name": "OrdinaryBinding", "visible": ["value": false, "user": ["name": "mode", "condition": "3"]]],
            ["id": 4, "visible": ["value": true, "script": """
            export function update(value) {
                if (engine.userProperties.control) {
                    thisScene.getLayer('Day').visible = !engine.userProperties.night;
                    thisScene.getLayer('Night').visible = engine.userProperties.night;
                }
                return value;
            }
            """]],
        ], properties: ["mode": ["type": "combo", "value": "0"],
                        "control": ["type": "bool", "value": true],
                        "night": ["type": "bool", "value": true]]))
        defer { runtime.shutdown() }
        #expect(runtime.step(deltaTime: 0.1).nodes.map(\.visible) == [false, true, false, true])
        #expect(runtime.step(deltaTime: 0.1, propertyOverrides: ["control": .bool(false)]).nodes.map(\.visible)
                == [false, true, false, true])
        #expect(runtime.step(deltaTime: 0.1, propertyOverrides: ["mode": .string("3"), "night": .bool(false)]).nodes.map(\.visible)
                == [true, false, true, true])
    }

    @Test func conditionalValueScriptsResumeAfterAnExplicitVisibilityWrite() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Target", "visible": ["value": true,
                "user": ["name": "mode", "condition": "3"],
                "script": "export function update() { shared.calls = (shared.calls || 0) + 1; return true; }"]],
            ["id": 2, "visible": ["value": true, "script": """
            let once = true;
            export function update(value) {
                if (once) { thisScene.getLayer('Target').visible = true; once = false; }
                thisLayer.origin.x = shared.calls;
                return value;
            }
            """]],
        ], properties: ["mode": ["type": "combo", "value": "0"]]))
        defer { runtime.shutdown() }
        let first = runtime.step(deltaTime: 0.1)
        #expect(first.nodes[0].visible)
        #expect(first.nodes[1].worldPosition.x == 1)
        let next = runtime.step(deltaTime: 0.1)
        #expect(!next.nodes[0].visible)
        #expect(next.nodes[1].worldPosition.x == 2)
        #expect(runtime.step(deltaTime: 0.1, propertyOverrides: ["mode": .string("3")]).nodes[0].visible)
    }

    @Test func explicitChildVisibilityStillRespectsParentVisibility() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Parent", "visible": ["value": false, "user": "parentShown"]],
            ["id": 2, "name": "Child", "parent": 1,
                "visible": ["value": false, "user": ["name": "mode", "condition": "3"]]],
            ["id": 3, "visible": ["value": true,
                "script": "export function update(value) { thisScene.getLayer('Child').visible = true; return value; }"]],
        ], properties: ["mode": ["type": "combo", "value": "0"], "parentShown": ["type": "bool", "value": false]]))
        defer { runtime.shutdown() }
        #expect(!runtime.step(deltaTime: 0.1).nodes[1].visible)
        #expect(runtime.step(deltaTime: 0.1, propertyOverrides: ["parentShown": .bool(true)]).nodes[1].visible)
    }

    @Test func directlyBoundPropertiesStillInitializeAndRunTheirScripts() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "ClockLibrary", "image": "missing.json", "visible": ["value": true, "user": "shown", "script": """
            shared.format = () => 'live';
            export function init(value) { shared.initialVisibility = value; return value; }
            export function update(value) { shared.ticks = (shared.ticks || 0) + 1; return value; }
            """]],
            ["id": 1, "image": "missing.json", "origin": ["value": "0 0 0", "script": """
            export function update() {
                if (shared.format() !== 'live' || shared.initialVisibility !== false) throw new Error('bound library skipped');
                return new Vec3(shared.ticks, 0, 0);
            }
            """]],
        ], properties: ["shown": ["type": "bool", "value": false]]))
        let first = runtime.step(deltaTime: 0.1)
        #expect(!first.nodes[0].visible)
        #expect(first.nodes[1].worldPosition.x == 1)
        let second = runtime.step(deltaTime: 0.1, propertyOverrides: ["shown": .bool(true)])
        #expect(second.nodes[0].visible)
        #expect(second.nodes[1].worldPosition.x == 2)
    }

    @Test func userValuesFeedScriptsAndUpdatesRetainTheirCurrentValue() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "image": "missing.json", "alpha": ["value": 0.9, "user": "amount",
                "script": "export function init(value) { shared.initialAmount = value; return value; } export function update(value) { return value + 0.1; }"]],
            ["id": 2, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function update() { return shared.initialAmount; }"]],
        ], properties: ["amount": ["type": "slider", "value": 0.2]]))
        let first = runtime.step(deltaTime: 0.1)
        #expect(abs((first.nodes[0].opacity ?? 0) - 0.3) < 0.00001)
        #expect(first.nodes[1].opacity == 0.2)
        #expect(abs((runtime.step(deltaTime: 0.1).nodes[0].opacity ?? 0) - 0.4) < 0.00001)
        let changed = runtime.step(deltaTime: 0.1, propertyOverrides: ["amount": .double(0.7)])
        #expect(abs((changed.nodes[0].opacity ?? 0) - 0.8) < 0.00001)
        #expect(changed.nodes[1].opacity == 0.2)
    }

    @Test func sharedLibraryFunctionsUseTheCallingLayerAndKeepExplicitReferences() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "Library", "image": "missing.json", "visible": ["value": false, "script": """
            const saved = thisLayer;
            shared.touch = () => { thisLayer.origin.x += 3; return thisObject === thisLayer; };
            shared.saved = () => saved;
            shared.Listener = class { constructor() { this.layer = thisLayer; this.object = thisObject; } };
            """]],
            ["id": 1, "name": "First", "image": "missing.json", "alpha": ["value": 1, "script": """
            export function update(value) {
                if (!shared.touch() || shared.saved().name !== 'Library') throw new Error('wrong shared context');
                const listener = new shared.Listener();
                if (listener.layer !== thisLayer || listener.object !== thisObject) throw new Error('wrong constructor context');
                return value;
            }
            """]],
            ["id": 2, "name": "Second", "image": "missing.json", "alpha": ["value": 1,
                "script": "export function update(value) { shared.touch(); return value; }"]],
        ]))
        for value: Float in [3, 6] {
            let packet = runtime.step(deltaTime: 0.1)
            #expect(packet.nodes.map(\.worldPosition.x) == [0, value, value])
        }
    }

    @Test func sharedFunctionsResolveTheCallingAnimationObjectAndItsLayer() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "Library", "image": "missing.json", "visible": ["value": false, "script": """
            shared.adjust = () => { thisObject.rate += 1; thisLayer.origin.x += 2; };
            """]],
            ["id": 1, "image": "missing.json", "animationlayers": [["id": 1, "animation": 10, "rate": 1,
                "visible": ["value": true, "script": "export function update(value) { shared.adjust(); return value; }"]]]],
        ]))
        let packet = runtime.step(deltaTime: 0)
        #expect(packet.nodes[0].worldPosition.x == 0)
        #expect(packet.nodes[1].worldPosition.x == 2)
        #expect(packet.nodes[1].animationLayers[0].rate == 2)
    }

    @Test func sharedLibraryTimerCallbacksKeepTheDispatchingScriptContext() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "Library", "image": "missing.json", "visible": ["value": false,
                "script": "shared.touch = () => { thisLayer.origin.x += 4; };"]],
            ["id": 1, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function init(value) { engine.setInterval(shared.touch, 100); return value; }"]],
            ["id": 2, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function init(value) { engine.setInterval(shared.touch, 200); return value; }"]],
        ]))
        _ = runtime.step(deltaTime: 0)
        #expect(runtime.step(deltaTime: 0.1).nodes.map(\.worldPosition.x) == [0, 4, 0])
        #expect(runtime.step(deltaTime: 0.1).nodes.map(\.worldPosition.x) == [0, 8, 4])
    }

    @Test func sharedLibraryDestroyCallbacksRunWithEachOwnersContext() throws {
        let storage = try SceneScriptStorage()
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "Library", "image": "missing.json", "visible": ["value": false,
                "script": "shared.saveOwner = () => localStorage.set(thisLayer.name, thisObject.name);"]],
            ["id": 1, "name": "First", "image": "missing.json", "visible": ["value": true,
                "script": "export function init(value) { return value; } export function destroy() { shared.saveOwner(); }"]],
            ["id": 2, "name": "Second", "image": "missing.json", "visible": ["value": true,
                "script": "export function init(value) { return value; } export function destroy() { shared.saveOwner(); }"]],
        ]), storage: storage)
        _ = runtime.step(deltaTime: 0)
        runtime.shutdown()
        #expect(try storage.request(#"{"operation":"get","key":"First"}"#) == #""First""#)
        #expect(try storage.request(#"{"operation":"get","key":"Second"}"#) == #""Second""#)
        #expect(try storage.request(#"{"operation":"get","key":"Library"}"#) == nil)
    }

    @Test func skeletalLayerPropertiesResolveUserBindingsAndValueScripts() throws {
        let original = try scene([
            ["id": 90, "name": "Puppet", "image": "missing.json", "animationlayers": [
                ["id": 7, "name": "Breathing", "animation": 10,
                 "rate": ["value": 0.5, "user": "speed"],
                 "blend": ["value": 0.25, "script": "export function update(value) { if (thisObject === thisLayer || thisLayer.name !== 'Puppet' || thisObject !== thisLayer.getAnimationLayer(0)) throw new Error('wrong animation owner'); return value + 0.125; }"],
                 "visible": ["value": false, "user": "shown"]],
                ["id": 8, "animation": 11],
            ]],
        ], properties: ["speed": ["type": "slider", "value": 2], "shown": ["type": "bool", "value": true]])
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        let runtime = SceneRuntime(scene: restored)
        let first = runtime.step(deltaTime: 0.25).nodes[0].animationLayers
        #expect(first[0].rate == 2)
        #expect(first[0].blend == 0.375)
        #expect(first[0].visible)
        #expect(first[1].rate == 1 && first[1].blend == 1)
        let next = runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(-0.5), "shown": .bool(false)]).nodes[0].animationLayers
        #expect(next[0].rate == -0.5)
        #expect(next[0].blend == 0.5)
        #expect(!next[0].visible)
    }

    @Test func legacySkeletalDescriptorsKeepWritableNumericProperties() throws {
        let original = try scene([
            ["id": 1, "image": "missing.json", "animationlayers": [["id": 7, "animation": 10, "rate": 2, "blend": 0.5]],
             "alpha": ["value": 1, "script": "export function update(value) { thisLayer.getAnimationLayer(0).rate += 1; return value; }"]],
        ])
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var graph = try #require(encoded["scene"] as? [String: Any])
        var nodes = try #require(graph["nodes"] as? [[String: Any]])
        var image = try #require(nodes[0]["image"] as? [String: Any])
        var layers = try #require(image["animationLayers"] as? [[String: Any]])
        for key in ["name", "rateSetting", "blendSetting"] { layers[0].removeValue(forKey: key) }
        image["animationLayers"] = layers; nodes[0]["image"] = image; graph["nodes"] = nodes; encoded["scene"] = graph
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONSerialization.data(withJSONObject: encoded))
        let runtime = SceneRuntime(scene: restored)
        #expect(runtime.step(deltaTime: 0.25).nodes[0].animationLayers[0].rate == 3)
        #expect(runtime.step(deltaTime: 0.25).nodes[0].animationLayers[0].rate == 4)
    }

    @Test func skeletalPropertyLibrariesFollowAuthoredLayerOrder() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "image": "missing.json", "animationlayers": [["id": 1, "animation": 10,
                "visible": ["value": true, "script": "export function init(value) { shared.animationSpeed = () => 2.5; return value; }"]]]],
            ["id": 1, "image": "missing.json", "animationlayers": [["id": 1, "animation": 10,
                "rate": ["value": 0, "script": "const speed = shared.animationSpeed(); export function init() { return speed; }"]]]],
        ]))
        #expect(runtime.step(deltaTime: 0.25).nodes[1].animationLayers[0].rate == 2.5)
    }

    @Test func retainedSkeletalLayersSupportNameIndexAndIndependentPropertyWrites() throws {
        let source = """
        const target = thisScene.getLayer('Puppet');
        const animation = target.getAnimationLayer('Breathing');
        export function init() {
            if (target.getAnimationLayerCount() !== 2 || target.getAnimationLayer(0) !== animation ||
                target.getAnimationLayer('missing') !== undefined || target.getAnimationLayer(-1) !== undefined ||
                animation.name !== 'Breathing') throw new Error('animation lookup mismatch');
            animation.rate = 3;
            animation.visible = true;
        }
        export function update(value) { animation.blend += 0.125; return value; }
        """
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "Puppet", "image": "missing.json", "animationlayers": [
                ["id": 7, "name": "Breathing", "animation": 10, "visible": false, "rate": 0, "blend": 0.25],
                ["id": 8, "name": "Other", "animation": 10, "visible": false, "rate": 2, "blend": 0.5],
            ]],
            ["id": 1, "image": "missing.json", "alpha": ["value": 1, "script": source]],
        ]))
        for expected in [0.375, 0.5] {
            let frame = runtime.step(deltaTime: 0.25)
            let layers = frame.nodes[0].animationLayers
            #expect(layers[0].rate == 3 && layers[0].visible && layers[0].blend == expected)
            #expect(layers[1].rate == 2 && !layers[1].visible && layers[1].blend == 0.5)
            #expect(frame.nodes[0].visible)
        }
    }

    @Test func initWithoutParametersCanReturnAPropertyValue() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "image": "missing.json",
                "visible": ["value": false, "script": "export function init() { return true; }"],
                "alpha": ["value": 1, "script": "export function init() { return 0.25; }"],
                "origin": ["value": "0 0 0", "script": "export function init() { return 2; }"]],
        ]))
        for _ in 0..<2 {
            let node = try #require(runtime.step(deltaTime: 1 / 60).nodes.first)
            #expect(node.visible)
            #expect(node.opacity == 0.25)
            #expect(node.worldPosition == RuntimeVector3(x: 2, y: 2, z: 2))
        }
    }

    @Test func initOnlyLayerWritesPersistAndIdenticalScriptsKeepSeparateInstances() throws {
        let source = "let initialized = false; export function init() { if (initialized) throw new Error('duplicate init'); initialized = true; shared.count = (shared.count || 0) + 1; thisObject.origin.x = shared.count; }"
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "image": "missing.json", "alpha": ["value": 1, "script": source],
                "visible": ["value": true, "script": source]],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 2)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 2)
    }

    @Test func arrowFunctionUpdatesContinueAfterAnotherScriptWritesTheirProperty() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Target", "image": "missing.json", "origin": ["value": "0 0 0",
                "script": "export const update = value => value.add(new Vec3(1, 0, 0));"]],
            ["id": 2, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function init() { thisScene.getLayer('Target').origin = new Vec3(100, 0, 0); }"]],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 100)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 2)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 3)
    }

    @Test func earlierValueScriptsPublishInitialStateAndRefreshBeforeLaterCallbacks() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "image": "missing.json", "visible": ["value": false,
                "script": "export function init() { shared.amount = engine.userProperties.amount; } export function update(value) { shared.amount = engine.userProperties.amount; return value; }"]],
            ["id": 1, "image": "missing.json", "alpha": ["value": 1,
                "script": "if (shared.amount === undefined) throw new Error('library not initialized'); export function init() { thisObject.origin = new Vec3(shared.amount, 0, 0); } export function applyUserProperties() { thisObject.origin = new Vec3(shared.amount, 0, 0); }"]],
        ], properties: ["amount": ["type": "slider", "value": 7]]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[1].worldPosition.x == 7)
        #expect(runtime.step(deltaTime: 1 / 60, propertyOverrides: ["amount": .int(12)]).nodes[1].worldPosition.x == 12)
    }

    @Test func callbackLibrariesFollowLayerOrderInsteadOfSortingNumericIDs() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function init() { shared.lookup = function() { return 8; }; }"]],
            ["id": 1, "image": "missing.json", "alpha": ["value": 1,
                "script": "const amount = shared.lookup(); export function init() { thisObject.origin = new Vec3(amount, 0, 0); }"]],
            ["id": 2, "image": "missing.json", "origin": ["value": "0 0 0",
                "script": "export function update() { return new Vec3(shared.lookup(), 0, 0); }"]],
        ]))
        let packet = runtime.step(deltaTime: 1 / 60)
        #expect(packet.nodes[1].worldPosition.x == 8)
        #expect(packet.nodes[2].worldPosition.x == 8)
    }

    @Test(arguments: ["material", "effect"])
    func earlierLayerComponentsPublishSharedValuesBeforeLaterLayers(component: String) throws {
        let producer: [String: Any] = ["value": 1, "script": """
        export function init() { shared.initialColor = new Vec3(0.25, 0.5, 0.75); }
        export function update(value) { shared.current = engine.userProperties.amount; return value; }
        """]
        var first: [String: Any] = ["id": 90, "image": "model.json", "visible": false]
        var constants: [String: Any] = [:]
        if component == "material" { constants["gain"] = producer }
        else { first["effects"] = [["file": "effect.json", "passes": [["constantshadervalues": ["gain": producer]]]]] }
        let runtime = SceneRuntime(scene: try scene([
            first,
            ["id": 1, "image": "missing.json", "origin": ["value": "0 0 0", "script": """
            const initial = shared.initialColor.copy();
            export function update() { return new Vec3(shared.current, initial.y, initial.z); }
            """]],
        ], properties: ["amount": ["type": "slider", "value": 7]], files: [
            "model.json": ["material": "material.json"],
            "material.json": ["passes": [["shader": "unused", "constantshadervalues": constants]]],
            "effect.json": ["passes": []],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[1].worldPosition == RuntimeVector3(x: 7, y: 0.5, z: 0.75))
        #expect(runtime.step(deltaTime: 1 / 60, propertyOverrides: ["amount": .int(12)]).nodes[1].worldPosition
                == RuntimeVector3(x: 12, y: 0.5, z: 0.75))
    }

    @Test func effectComponentsKeepAuthoredNumericOrderAcrossFrames() throws {
        let effects: [[String: Any]] = (0..<12).map { index in
            ["file": "effect.json", "passes": [["constantshadervalues": ["gain": ["value": 1, "script": """
            export function update(value) {
                if (shared.next !== \(index)) throw new Error('effect out of order');
                shared.next++;
                thisLayer.origin.x = shared.next;
                return value;
            }
            """]]]]]
        }
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "image": "missing.json", "visible": ["value": true,
                "script": "export function update(value) { shared.next = 0; return value; }"], "effects": effects],
        ], files: ["effect.json": ["passes": []]]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 12)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 12)
    }

    @Test func skeletalComponentScriptsRunBeforeTheNextLayer() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "image": "missing.json", "animationlayers": [["id": 7, "animation": 10,
                "rate": ["value": 1, "script": "export function update(value) { shared.rate = (shared.rate || 0) + 1; return value; }"]]]],
            ["id": 1, "image": "missing.json", "origin": ["value": "0 0 0",
                "script": "export function update() { return new Vec3(shared.rate, 0, 0); }"]],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[1].worldPosition.x == 1)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[1].worldPosition.x == 2)
    }

    @Test func particleInstanceScriptsFollowTheirLayerAndPrecedeTheNextLayer() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "particle": "particle.json", "origin": ["value": "0 0 0",
                "script": "export function update(value) { shared.base = (shared.base || 0) + 1; return value; }"],
             "instanceoverride": ["alpha": ["value": 1, "script": """
             export function update(value) {
                 if (thisObject !== thisLayer.instance) throw new Error('wrong owner');
                 shared.instanceValue = shared.base * 3;
                 return value;
             }
             """]]],
            ["id": 1, "image": "missing.json", "origin": ["value": "0 0 0",
                "script": "export function update() { return new Vec3(shared.instanceValue, 0, 0); }"]],
        ], files: ["particle.json": ["maxcount": 1, "emitter": [], "initializer": [], "operator": [], "renderer": []]]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[1].worldPosition.x == 3)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[1].worldPosition.x == 6)
    }

    @Test func materialVectorComponentWritesRetainAllFourComponents() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "image": "model.json"],
        ], files: [
            "model.json": ["material": "material.json"],
            "material.json": ["passes": [["shader": "unused", "constantshadervalues": [
                "gain": ["value": 1, "script": "export function update(value) { if (!(thisObject.tint instanceof Vec4)) throw new Error('lost material Vec4'); thisObject.tint.w += 1; return value; }"],
                "tint": "1 2 3 4",
            ]]]],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).materials[0].passes[0].constants["tint"] == .vec4([1, 2, 3, 5]))
        #expect(runtime.step(deltaTime: 1 / 60).materials[0].passes[0].constants["tint"] == .vec4([1, 2, 3, 6]))
    }

    @Test func nestedScriptBindingsFollowUserOptionsWithoutLosingTheirSavedType() throws {
        let original = try scene([
            ["id": 1, "image": "missing.json", "alpha": ["value": 1,
                "script": "const props = createScriptProperties().addCheckbox({name:'on',value:false}).addSlider({name:'level',value:0}).finish(); export function update() { return props.on ? props.level : 0; }",
                "scriptproperties": ["on": ["value": false, "user": ["name": "mode", "condition": "2"]],
                                     "level": ["value": 0.1, "user": "amount"]]]],
            ["id": 2, "visible": ["value": false, "user": ["name": "mode", "condition": "2"]]],
        ], properties: ["mode": ["type": "combo", "value": "2"], "amount": ["type": "slider", "value": 0.7]])
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        let runtime = SceneRuntime(scene: restored)
        let initial = runtime.step(deltaTime: 1 / 60)
        #expect(initial.nodes[0].opacity == 0.7)
        #expect(initial.nodes[1].visible)
        let switched = runtime.step(deltaTime: 1 / 60, propertyOverrides: ["mode": .string("1")])
        #expect(switched.nodes[0].opacity == 0)
        #expect(!switched.nodes[1].visible)
        #expect(runtime.step(deltaTime: 1 / 60, propertyOverrides: ["amount": .double(0.4)]).nodes[0].opacity == 0.4)
    }

    private func scene(_ objects: [[String: Any]], properties: [String: Any] = [:], files: [String: Any] = [:]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": properties]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": objects])
            .write(to: root.appendingPathComponent("scene.json"))
        for (name, object) in files {
            try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(name))
        }
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }

    @Test func materialScriptsHaveTheirOwnObjectAndCanMoveTheirLayerBeforeRendering() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Canvas", "image": "model.json", "origin": "10 0 0"],
        ], files: [
            "model.json": ["material": "material.json"],
            "material.json": ["passes": [["shader": "unused", "constantshadervalues": [
                "gain": ["value": 0.5, "script": "export function update(value) { if (thisObject === thisLayer) throw new Error('wrong property owner'); thisLayer.origin.x = 42; thisObject.bias = 0.25; return value * 0.5; }"],
                "bias": 0,
            ]]]],
        ]))
        let first = runtime.step(deltaTime: 1 / 60)
        #expect(first.nodes[0].worldPosition.x == 42)
        #expect(first.materials[0].passes[0].constants["gain"]?.doubleValue == 0.25)
        #expect(first.materials[0].passes[0].constants["bias"]?.doubleValue == 0.25)
        #expect(runtime.step(deltaTime: 1 / 60).materials[0].passes[0].constants["gain"]?.doubleValue == 0.125)
    }

    @Test func alphaScriptsCanRevealAuthoredHiddenLayersBeforeVisibilityIsComputed() throws {
        let source = """
        export function init(value) { thisLayer.visible = true; return value; }
        export function update(value) {
            thisLayer.visible = engine.userProperties.shown;
            return value;
        }
        """
        let scene = try scene([
            ["id": 99, "name": "Night", "image": "missing.json", "visible": false,
             "alpha": ["value": 0.75, "script": source]],
        ], properties: ["shown": ["type": "bool", "value": true]])
        let runtime = SceneRuntime(scene: scene)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].visible)
        #expect(!runtime.step(deltaTime: 1 / 60, propertyOverrides: ["shown": .bool(false)]).nodes[0].visible)
        let third = runtime.step(deltaTime: 1 / 60, propertyOverrides: ["shown": .bool(true)])
        #expect(third.nodes[0].visible)
        #expect(third.nodes[0].opacity == 0.75)
    }

    @Test func retainedLayerReferencesResolveNamesIndicesParentsAndChildren() throws {
        let source = """
        const target = thisScene.getLayer('Target');
        const parent = thisLayer.getParent();
        export function update(value) {
            if (thisScene.getLayer(0) !== target || thisScene.getLayer(999) !== undefined ||
                thisScene.getLayer('missing') !== undefined || thisScene.getLayerCount() !== 3 ||
                thisScene.getLayerIndex(target) !== 0 || thisScene.enumerateLayers()[2] !== thisLayer ||
                parent.getParent() !== undefined || parent.getChildren()[0] !== thisLayer ||
                thisObject !== thisLayer) throw new Error('layer lookup mismatch');
            target.origin.x += 2;
            return value;
        }
        """
        let runtime = SceneRuntime(scene: try scene([
            ["id": 90, "name": "Target", "image": "missing.json", "origin": "10 5 0"],
            ["id": 42, "name": "Parent"],
            ["id": 71, "name": "Controller", "parent": 42, "image": "missing.json",
             "alpha": ["value": 1, "script": source]],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 12)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 14)
    }

    @Test func aCrossLayerWriteDoesNotStopTheTargetsValueScriptOnLaterFrames() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Target", "image": "missing.json",
             "origin": ["value": "0 0 0", "script": "export function update(value) { return value.add(new Vec3(1, 0, 0)); }"]],
            ["id": 2, "image": "missing.json",
             "alpha": ["value": 1, "script": "let once = true; export function update(value) { if (once) { thisScene.getLayer('Target').origin = new Vec3(100, 0, 0); once = false; } return value; }"]],
        ]))
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 100)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 2)
        #expect(runtime.step(deltaTime: 1 / 60).nodes[0].worldPosition.x == 3)
    }

    @Test func scriptAnglesUseDegreesWhileSceneTransformsKeepRadians() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Rotated", "angles": ["value": "0 0 \(Double.pi / 2)",
                "script": "export function update(value) { return value.add(new Vec3(0, 0, 90)); }"]],
            ["id": 2, "parent": 1, "image": "missing.json", "origin": "10 0 0"],
            ["id": 3, "name": "SetRotation"],
            ["id": 4, "parent": 3, "image": "missing.json", "origin": "10 0 0"],
            ["id": 5, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function update(value) { thisScene.getLayer('SetRotation').angles = new Vec3(0, 0, 90); return value; }"]],
        ]))
        let frame = runtime.step(deltaTime: 1 / 60)
        #expect(abs(frame.nodes[1].worldPosition.x + 10) < 0.0001)
        #expect(abs(frame.nodes[1].worldPosition.y) < 0.0001)
        #expect(abs(frame.nodes[3].worldPosition.x) < 0.0001)
        #expect(abs(frame.nodes[3].worldPosition.y - 10) < 0.0001)
    }

    @Test func imperativeCallbacksShareTheRealLayerAndSceneObjects() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "image": "missing.json", "alpha": ["value": 1,
                "script": "export function init() { thisLayer.origin = new Vec3(8, 9, 0); thisScene.bloom = true; thisObject.alpha = 0.25; }"]],
        ]))
        let frame = runtime.step(deltaTime: 1 / 60)
        #expect(frame.nodes[0].worldPosition == RuntimeVector3(x: 8, y: 9, z: 0))
        #expect(frame.nodes[0].opacity == 0.25)
        #expect(frame.cameraBloom?.enabled == true)
    }
}
