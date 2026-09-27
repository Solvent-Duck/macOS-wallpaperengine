import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct LayerTransformTests {
    @Test func worldQueriesFollowRotatedScaledParentsAndImmediateWrites() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "name": "Parent", "origin": "10 20 0", "scale": "2 3 1", "angles": "0 0 \(Double.pi / 2)"],
            ["id": 2, "name": "Child", "parent": 1, "origin": "1 2 0"],
            ["id": 3, "image": "missing.json", "origin": ["value": "0 0 0", "script": """
            const parent = thisScene.getLayer('Parent'), child = thisScene.getLayer('Child');
            export function update() {
                parent.origin.x += 5;
                const matrix = child.getTransformMatrix();
                if (!(matrix instanceof Mat4) || !matrix.translation().equals(child.getAttachmentOrigin())) throw new Error('matrix/origin mismatch');
                if (Math.abs(child.getAttachmentAngles().z-90) > 1e-5) throw new Error('wrong world rotation');
                return matrix.transformPoint(new Vec3(0));
            }
            """]],
        ]))
        for x: Float in [9,14] {
            let frame = runtime.step(deltaTime: 0.1)
            #expect(abs(frame.nodes[2].worldPosition.x-x) < 0.0001)
            #expect(abs(frame.nodes[2].worldPosition.y-22) < 0.0001)
            #expect(frame.nodes[1].worldPosition == frame.nodes[2].worldPosition)
        }
    }

    @Test func copiedMatricesDoNotMutateLayerTransformsAndBadAttachmentsAreReported() throws {
        let runtime = SceneRuntime(scene: try scene([
            ["id": 1, "image": "missing.json", "origin": ["value": "10 20 30", "script": """
            export function update(value) {
                const matrix = thisLayer.getTransformMatrix(); matrix.m[12] = 200;
                if (thisLayer.getTransformMatrix().m[12] !== 10 || thisLayer.getAttachmentIndex('missing') !== -1) return new Vec3(-1);
                try { thisLayer.getAttachmentMatrix('missing'); return new Vec3(-2); } catch (error) {
                    if (!(error instanceof RangeError)) return new Vec3(-3);
                }
                return value.add(1);
            }
            """]],
        ]))
        #expect(runtime.step(deltaTime: 0).nodes[0].worldPosition == RuntimeVector3(x: 11,y: 21,z: 31))
    }

    @Test func attachmentQueriesUseCurrentBonePoseAndAttachedChildHierarchy() throws {
        let root = try SkeletalAttachmentTests().fixture(reference: .name("头"), controller: """
        const puppet = thisScene.getLayer('Puppet'), child = thisScene.getLayer(0);
        export function update() {
            if (puppet.getAttachmentIndex('头') !== 0) throw new Error('missing named attachment');
            if (!puppet.getAttachmentMatrix(0).equals(puppet.getAttachmentMatrix('头'))) throw new Error('index mismatch');
            return child.getTransformMatrix().translation();
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let description = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: description, puppetModels: PuppetModelLibrary(assetRoots: [root]))
        for (dt, enabled, y) in [(0.5,true,Float(44)), (0.25,false,Float(40))] {
            let frame = runtime.step(deltaTime: dt, propertyOverrides: ["moving": .bool(enabled)])
            #expect(abs(frame.nodes[3].worldPosition.y-y) < 0.0001)
            // Native matrices use Float while QuickJS computes in Double.
            #expect(abs(frame.nodes[0].worldPosition.x-frame.nodes[3].worldPosition.x) < 0.0001)
            #expect(abs(frame.nodes[0].worldPosition.y-frame.nodes[3].worldPosition.y) < 0.0001)
        }
    }

    @Test func seekingAndChangingBlendUpdatesAttachmentWithinTheSameScript() throws {
        let root = try SkeletalAttachmentTests().fixture(reference: .index(0), controller: """
        const puppet = thisScene.getLayer('Puppet');
        export function update() {
            const animation = puppet.getAnimationLayer(0);
            animation.setFrame(0.5); animation.pause(); animation.blend = 0.5;
            return puppet.getAttachmentOrigin(0);
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene, puppetModels: PuppetModelLibrary(assetRoots: [root]))
        let frame = runtime.step(deltaTime: 0)
        // Half-blended bone x=6 plus attachment x=3, scaled and rotated by the parent.
        #expect(abs(frame.nodes[3].worldPosition.x-10) < 0.0001)
        #expect(abs(frame.nodes[3].worldPosition.y-38) < 0.0001)
    }

    private func scene(_ objects: [[String: Any]]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELayerTransforms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type":"scene", "file":"scene.json"]).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera":[:], "general":[:], "objects":objects]).write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
