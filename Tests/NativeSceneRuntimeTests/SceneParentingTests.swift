import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct SceneParentingTests {
    @Test func reparentingUpdatesLiveQueriesDescendantsAndFrameHierarchy() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Child", "parent": 2, "origin": "3 0 0"],
            ["id": 2, "name": "Old", "origin": "10 0 0"],
            ["id": 3, "name": "New", "origin": "20 0 0"],
            ["id": 4, "name": "Grandchild", "parent": 1, "origin": "2 0 0"],
            ["id": 5, "origin": ["value": "0 0 0", "script": """
            const child = thisScene.getLayer('Child'), old = thisScene.getLayer('Old'), next = thisScene.getLayer('New');
            export function init() { child.setParent('New'); }
            export function update() {
                next.origin.x += 1;
                if (child.getParent() !== next || old.getChildren().length || next.getChildren()[0] !== child)
                    return new Vec3(-1);
                return thisScene.getLayer('Grandchild').getTransformMatrix().translation();
            }
            """]],
        ]))
        for x: Float in [24,25] {
            let frame = runtime.step(deltaTime: 0)
            #expect(frame.nodes.map(\.nodeID.rawValue) == [1,2,3,4,5])
            #expect(frame.nodes[0].parentID?.rawValue == 3)
            #expect(frame.nodes[0].worldPosition.x == x)
            #expect(frame.nodes[3].worldPosition.x == x + 2)
            #expect(frame.nodes[4].worldPosition.x == x + 2)
        }
    }

    @Test func detachAndIndexReferencesUpdateInheritedVisibilityWhilePaused() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Child", "parent": 2, "origin": "3 0 0"],
            ["id": 2, "name": "Hidden", "origin": "10 0 0", "visible": false],
            ["id": 3, "name": "Shown", "origin": "20 0 0"],
            ["id": 4, "visible": ["value": false, "script": """
            export function applyUserProperties() {
                const child = thisScene.getLayer('Child');
                child.setParent(engine.userProperties.mode === 0 ? undefined : engine.userProperties.mode);
            }
            """]],
        ], properties: ["mode": ["type": "slider", "value": 0]]))
        runtime.setPaused(true)
        let detached = runtime.step(deltaTime: 1)
        #expect(detached.nodes[0].parentID == nil)
        #expect(detached.nodes[0].visible)
        #expect(detached.nodes[0].worldPosition.x == 3)
        let hidden = runtime.step(deltaTime: 1, propertyOverrides: ["mode": .int(1)])
        #expect(hidden.nodes[0].parentID?.rawValue == 2)
        #expect(!hidden.nodes[0].visible)
        #expect(hidden.nodes[0].worldPosition.x == 13)
        let shown = runtime.step(deltaTime: 1, propertyOverrides: ["mode": .int(2)])
        #expect(shown.nodes[0].visible)
        #expect(shown.nodes[0].worldPosition.x == 23)
    }

    @Test func preservingWorldTransformAdjustsTranslationRotationAndScale() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Child", "parent": 2, "origin": "3 2 1", "scale": "-1 2 3", "angles": "0.1 0.2 0.3"],
            ["id": 2, "name": "Old", "origin": "10 20 30", "scale": "2 2 2", "angles": "0.2 0.4 0.6"],
            ["id": 3, "name": "New", "origin": "-20 5 10", "scale": "3 3 3", "angles": "0.4 0.2 0.1"],
            ["id": 4, "origin": ["value": "0 0 0", "script": """
            let step = 0;
            export function update() {
                const child = thisScene.getLayer('Child');
                const before = child.getTransformMatrix();
                if (step === 0) child.setParent(thisScene.getLayer('New'), true);
                if (step === 1) child.setParent(undefined, true);
                step++;
                if (!before.equals(child.getTransformMatrix())) return new Vec3(-1000);
                return child.getTransformMatrix().translation();
            }
            """]],
        ]))
        let first = runtime.step(deltaTime: 0)
        let second = runtime.step(deltaTime: 0)
        #expect(first.nodes[0].parentID?.rawValue == 3)
        #expect(second.nodes[0].parentID == nil)
        for frame in [first,second] {
            #expect(abs(frame.nodes[0].worldPosition.x-frame.nodes[3].worldPosition.x) < 0.0001)
            #expect(abs(frame.nodes[0].worldPosition.y-frame.nodes[3].worldPosition.y) < 0.0001)
            #expect(abs(frame.nodes[0].worldPosition.z-frame.nodes[3].worldPosition.z) < 0.0001)
        }
        #expect(abs(first.nodes[0].worldPosition.x-second.nodes[0].worldPosition.x) < 0.0001)
        #expect(abs(first.nodes[0].worldPosition.y-second.nodes[0].worldPosition.y) < 0.0001)
    }

    @Test func invalidParentsCyclesAndSingularTransformsLeaveTheLayerUnchanged() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Child", "parent": 2, "origin": "3 0 0"],
            ["id": 2, "name": "Parent", "origin": "10 0 0"],
            ["id": 3, "name": "Descendant", "parent": 1],
            ["id": 4, "name": "Singular", "scale": "0 0 0"],
            ["id": 5, "origin": ["value": "0 0 0", "script": """
            export function update() {
                const child = thisScene.getLayer('Child'), before = child.getTransformMatrix();
                let rejected = 0;
                for (const args of [['Child'],['Descendant'],['missing'],[999],[{}],['Singular',true],['Parent','missing']]) {
                    try { child.setParent(...args); } catch (error) { if (error instanceof RangeError) rejected++; }
                }
                if (rejected !== 7 || child.getParent().name !== 'Parent' || !before.equals(child.getTransformMatrix())) return new Vec3(-1);
                return child.getTransformMatrix().translation();
            }
            """]],
        ]))
        let frame = runtime.step(deltaTime: 0)
        #expect(frame.nodes[0].parentID?.rawValue == 2)
        #expect(frame.nodes[0].worldPosition.x == 13)
        #expect(frame.nodes[4].worldPosition.x == 13)
    }

    @Test(arguments: ["'头'", "0"])
    func attachmentReparentingUsesTheCurrentPoseAndCanDetach(reference: String) throws {
        let root = try SkeletalAttachmentTests().fixture(reference: .name("头"), controller: """
        let calls = 0;
        export function update() {
            const child = thisScene.getLayer(0), puppet = thisScene.getLayer('Puppet');
            puppet.getAnimationLayer(0).setFrame(0.5);
            puppet.getAnimationLayer(0).pause();
            if (calls++ === 0) {
                child.setParent(undefined);
                child.setParent(puppet, \(reference));
            } else { child.setParent(undefined, true); }
            return child.getTransformMatrix().translation();
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let description = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: description, puppetModels: PuppetModelLibrary(assetRoots: [root]))
        for parent: Int? in [9,nil] {
            let frame = runtime.step(deltaTime: 0)
            #expect(frame.nodes[0].parentID?.rawValue == parent)
            #expect(abs(frame.nodes[0].worldPosition.x-10) < 0.0001)
            #expect(abs(frame.nodes[0].worldPosition.y-44) < 0.0001)
            #expect(abs(frame.nodes[0].worldPosition.y-frame.nodes[3].worldPosition.y) < 0.0001)
        }
    }

    private func scene(_ nodes: [[String: Any]], properties: [String: Any] = [:]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEParenting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": properties]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": nodes])
            .write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
