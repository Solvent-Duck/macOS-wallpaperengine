import Foundation
import NativeSceneCore
import Testing
@testable import NativeSceneRuntime

struct DynamicLayerTests {
    @Test func importedAssetsResolveTheExecutingScriptsNamespace() throws {
        let fixture = try LayerFixture(script: """
            'use strict';
            export let __workshopId = '900';
            const topLevel = thisScene.createLayer('models/bar.json');
            const asset = engine.registerAsset('models/bar.json');
            export function init() {
                function strictScope() { return this === undefined; }
                if (!strictScope()) throw new Error('authored strict mode lost');
                const retained = thisScene.createLayer(asset);
                const inline = thisScene.createLayer({image:'models/bar.json'});
                if (topLevel.size.x !== 17 || retained.size.x !== 17 || inline.size.x !== 17) throw new Error('wrong asset namespace');
                thisLayer.origin.y = 17;
                return false;
            }
            """)
        let models = fixture.root.appendingPathComponent("models/workshop/900")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["material":"material.json","width":17,"height":8])
            .write(to: models.appendingPathComponent("bar.json"))
        let frame = fixture.runtime.step(deltaTime: 0)
        #expect(frame.nodes.count == 4 && frame.nodes[0].worldPosition.y == 17)
        #expect(fixture.runtime.scene.nodes.dropFirst().allSatisfy { $0.image?.model?.filename == "models/workshop/900/bar.json" })
    }

    @Test func createdLayersAreRealRetainedNodesWithLiveTransforms() throws {
        let fixture = try LayerFixture(script: """
            let created;
            export function init() {
                created = thisScene.createLayer({name:'generated',image:'models/bar.json',origin:new Vec3(6,7,0)});
                created.alpha = 0.25;
                return false;
            }
            export function update() {
                if (thisScene.getLayer('generated') !== created || thisScene.getLayerCount() !== 2) throw new Error('missing layer');
                created.origin.x += 1;
                return false;
            }
            """)
        let first = fixture.runtime.step(deltaTime: 0.1)
        let created = try #require(first.nodes.first { $0.name == "generated" })
        #expect(created.visible && created.opacity == 0.25)
        #expect(created.worldPosition.x == 7 && created.worldPosition.y == 7)
        #expect(!created.renderItemReferences.isEmpty)
        let second = fixture.runtime.step(deltaTime: 0.1)
        #expect(second.nodes.first { $0.nodeID == created.nodeID }?.worldPosition.x == 8)
    }

    @Test func cloningUsesIndependentAuthoredConfigurationAndCurrentPropertyDefaults() throws {
        let fixture = try LayerFixture(script: """
            export function init() {
                const original = thisScene.getInitialLayerConfig('template');
                original.name = 'clone';
                const clone = thisScene.createLayer(original);
                if (clone.alpha !== 0.4) throw new Error('wrong property default');
                clone.visible = true;
                clone.origin = new Vec3(6,7,0);
                if (thisScene.getInitialLayerConfig('template').name !== 'template') throw new Error('config aliased');
                return false;
            }
            """, template: true, properties: ["gain": ["type":"slider","value":0.4]])
        let frame = fixture.runtime.step(deltaTime: 0.1)
        let clone = try #require(frame.nodes.first { $0.name == "clone" })
        #expect(clone.visible && abs((clone.opacity ?? 0) - 0.4) < 0.001)
        #expect(clone.worldPosition.x == 6 && clone.worldPosition.y == 7)
        #expect(frame.nodes.first { $0.name == "template" }?.visible == false)
        let changed = fixture.runtime.step(deltaTime: 0.1, propertyOverrides: ["gain": .double(0.7)])
        #expect(abs((changed.nodes.first { $0.nodeID == clone.nodeID }?.opacity ?? 0) - 0.7) < 0.001)
    }

    @Test func createdScriptsInitializeOnceAndRunInTheirOwnLayerContext() throws {
        let childScript = "export function init() { shared.childInitializations=(shared.childInitializations||0)+1; thisLayer.alpha=0.5; return new Vec3(0); } export function update() { return new Vec3(engine.runtime*10,3,0); }"
        let config: [String: Any] = ["name":"child","image":"models/bar.json","origin":["value":"0 0 0","script":childScript]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject:config),as:UTF8.self)
        let fixture = try LayerFixture(script: """
            export function init() { thisScene.createLayer(\(json)); return false; }
            export function update() { thisLayer.origin.y = shared.childInitializations || 0; return false; }
            """)
        let first = fixture.runtime.step(deltaTime:0.1)
        let child = try #require(first.nodes.first { $0.name == "child" })
        #expect(child.opacity == 0.5 && abs(child.worldPosition.x - 1) < 0.001 && child.worldPosition.y == 3)
        #expect(first.nodes.first { $0.name == "controller" }?.worldPosition.y == 1)
        let second = fixture.runtime.step(deltaTime:0.1)
        #expect(abs((second.nodes.first { $0.nodeID == child.nodeID }?.worldPosition.x ?? 0) - 2) < 0.001)
        #expect(second.nodes.first { $0.name == "controller" }?.worldPosition.y == 1)
    }

    @Test func destructionIsDeferredAndDispatchesDestroyOnlyOnce() throws {
        let childScript = "export function init() { return true; } export function destroy() { shared.destroyCount=(shared.destroyCount||0)+1; }"
        let config: [String: Any] = ["name":"child","image":"models/bar.json","visible":["value":true,"script":childScript]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject:config),as:UTF8.self)
        let fixture = try LayerFixture(script: """
            let child, requested=false;
            export function init() { child=thisScene.createLayer(\(json)); return false; }
            export function update() {
                if (engine.runtime >= 0.2 && !requested) {
                    if (!thisScene.destroyLayer(child)) throw new Error('destroy failed');
                    requested=true;
                }
                thisLayer.origin.x=shared.destroyCount||0;
                return false;
            }
            """)
        #expect(fixture.runtime.step(deltaTime:0.1).nodes.count == 2)
        #expect(fixture.runtime.step(deltaTime:0.1).nodes.count == 2)
        let removed = fixture.runtime.step(deltaTime:0.1)
        #expect(removed.nodes.count == 1 && removed.nodes[0].worldPosition.x == 1)
        #expect(fixture.runtime.step(deltaTime:0.1).nodes[0].worldPosition.x == 1)
    }

    @Test func assetHandlesAndSortOrderUseTheRealSceneTable() throws {
        let fixture = try LayerFixture(script: """
            export function init() {
                const first=thisScene.createLayer(engine.registerAsset('models/bar.json'));
                const second=thisScene.createLayer({name:'second',image:'models/bar.json'});
                if (!thisScene.sortLayer(second,0) || thisScene.getLayer(0)!==second || thisScene.getLayerIndex(first)!==2) throw new Error('sort failed');
                thisLayer.origin.y = first.size.x;
                return false;
            }
            """)
        let frame = fixture.runtime.step(deltaTime:0.1)
        #expect(frame.nodes.count == 3 && frame.nodes.first?.name == "second")
        #expect(frame.nodes[1].nodeID.rawValue == 1)
        #expect(frame.nodes[1].worldPosition.y == 8)
    }

    @Test func createDestroyCyclesDoNotRetainNodesAndNeverReuseIDs() throws {
        let fixture = try LayerFixture(script: """
            let previous;
            export function update() {
                if (previous && thisScene.getLayerIndex(previous)!==-1) throw new Error('removed layer retained');
                previous=thisScene.createLayer({name:'temporary',text:'test',origin:new Vec3(1,1,0)});
                thisScene.destroyLayer(previous);
                return false;
            }
            """)
        var ids:Set<NodeID>=[]
        for _ in 0..<40 {
            let frame=fixture.runtime.step(deltaTime:0.01)
            #expect(frame.nodes.count == 2 && frame.texts.count == 1)
            let id=try #require(frame.nodes.first { $0.name == "temporary" }?.nodeID)
            #expect(ids.insert(id).inserted)
        }
    }

    @Test func missingAssetDoesNotPublishAPhantomLayer() throws {
        let fixture = try LayerFixture(script: """
            export function init() {
                let failed=false;
                try { thisScene.createLayer('../missing.json'); } catch (_) { failed=true; }
                return !failed || thisScene.getLayerCount()!==1;
            }
            """)
        let frame=fixture.runtime.step(deltaTime:0.1)
        #expect(frame.nodes.count == 1 && frame.nodes[0].visible == false)
    }

    @Test func invalidInlineAssetsLeaveTheSceneUnchanged() throws {
        let fixture = try LayerFixture(script: """
            export function init() {
                let failures = 0;
                for (const config of [{image:'missing.json'}, {particle:'missing.json'}, {image:'material.json'}]) {
                    try { thisScene.createLayer(config); } catch (_) { failures++; }
                }
                thisLayer.origin.x = failures;
                return false;
            }
            """)
        let frame = fixture.runtime.step(deltaTime: 0)
        #expect(frame.nodes.count == 1 && frame.nodes[0].worldPosition.x == 3)
    }

    @Test func deletedParentsDetachChildrenAndIgnoreStaleReferences() throws {
        let fixture = try LayerFixture(script: """
            let parent, child, frame = 0;
            export function init() {
                parent = thisScene.createLayer({name:'parent',image:'models/bar.json',origin:[10,0,0]});
                child = thisScene.createLayer({name:'child',image:'models/bar.json',origin:[2,0,0]});
                child.setParent(parent);
                return false;
            }
            export function update() {
                if (++frame === 1) thisScene.destroyLayer(parent);
                else { parent.origin.x = 99; thisLayer.origin.y = child.getParent() == null ? 1 : -1; }
                return false;
            }
            """)
        #expect(fixture.runtime.step(deltaTime: 0).nodes.first { $0.name == "child" }?.worldPosition.x == 12)
        let frame = fixture.runtime.step(deltaTime: 0)
        #expect(frame.nodes.count == 2)
        #expect(frame.nodes.first { $0.name == "child" }?.worldPosition.x == 2)
        #expect(frame.nodes[0].worldPosition.y == 1)
    }

    @Test func shutdownDisposesCreatedScriptsOnceAndReplayDoesNotDuplicateLayers() throws {
        let storage = try SceneScriptStorage()
        let childScript = "export function init() { return true; } export function destroy() { localStorage.set('destroyed', (localStorage.get('destroyed')||0)+1); }"
        let configuration: [String: Any] = ["image":"models/bar.json", "visible":["value":true,"script":childScript]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
        let fixture = try LayerFixture(script: "export function init() { thisScene.createLayer(\(json)); return false; }", storage: storage)
        let first = fixture.runtime.step(deltaTime: 0)
        #expect(first.nodes.count == 2)
        fixture.runtime.shutdown()
        fixture.runtime.shutdown()
        #expect(fixture.runtime.scene.nodes.count == 1)
        #expect(try storage.request(#"{"operation":"get","key":"destroyed"}"#) == "1")
        let replay = fixture.runtime.step(deltaTime: 0)
        #expect(replay.nodes.count == 2 && replay.nodes.last?.nodeID != first.nodes.last?.nodeID)
        fixture.runtime.shutdown()
        #expect(try storage.request(#"{"operation":"get","key":"destroyed"}"#) == "2")
    }

    @Test func createdSoundLayersPublishTransportAndDropItAfterDeletion() throws {
        let fixture = try LayerFixture(script: """
            let sound, frame = 0;
            export function init() {
                sound = thisScene.createLayer({name:'sound',sound:['test.ogg'],startsilent:true});
                sound.volume = 0.25; sound.play();
                return false;
            }
            export function update() { if (++frame === 2) thisScene.destroyLayer(sound); return false; }
            """)
        let first = fixture.runtime.step(deltaTime: 0)
        #expect(first.soundTransports.count == 1)
        #expect(first.soundTransports.first?.state == .playing && first.soundTransports.first?.gain == 0.25)
        #expect(fixture.runtime.step(deltaTime: 0).soundTransports.count == 1)
        #expect(fixture.runtime.step(deltaTime: 0).soundTransports.isEmpty)
    }
}

private final class LayerFixture {
    let root: URL
    let runtime: SceneRuntime
    init(script: String, template: Bool = false, properties: [String: Any] = [:], storage: SceneScriptStorage? = nil) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("DynamicLayerTests-\(UUID().uuidString)")
        root=directory
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("models"),withIntermediateDirectories:true)
        func save(_ path:String,_ value:Any) throws { try JSONSerialization.data(withJSONObject:value).write(to:directory.appendingPathComponent(path)) }
        try save("project.json",["title":"Dynamic layers","type":"scene","file":"scene.json","general":["properties":properties]])
        try save("models/bar.json",["material":"material.json","width":8,"height":8])
        try save("material.json",["passes":[["shader":"generic","blending":"normal"]]])
        var nodes:[[String:Any]] = [["id":1,"name":"controller","image":"models/bar.json","origin":"0 0 0","visible":["value":false,"script":script]]]
        if template { nodes.append(["id":2,"name":"template","image":"models/bar.json","origin":"2 2 0","visible":false,"alpha":["value":1,"user":"gain"]]) }
        try save("scene.json",["camera":[:],"general":["orthogonalprojection":["width":8,"height":8]],"objects":nodes])
        let scene=try SceneDescriptionLoader.loadSceneDescription(wallpaperPath:root.path,assetsPath:root.path)
        runtime=SceneRuntime(scene:scene,storage:storage,assetRoots:[root])
    }
    deinit { runtime.shutdown(); try? FileManager.default.removeItem(at:root) }
}
