import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct SkeletalAttachmentTests {
    @Test(arguments: [AttachmentReference.name("头"), .index(0)])
    func attachedChildrenFollowBonePoseBeforeParentScaleAndRotation(reference: AttachmentReference) throws {
        let root = try fixture(reference: reference)
        defer { try? FileManager.default.removeItem(at: root) }
        let description = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(description))
        #expect(restored == description)
        #expect(restored.nodes[0].attachment == reference)
        let library = PuppetModelLibrary(assetRoots: [root])
        let model = try #require(library.model(for: "puppet.mdl"))
        #expect(model.attachments.count == 1)
        #expect(model.attachments[0].name == "头")
        #expect(model.attachments[0].bone == 0)
        #expect(model.attachments[0].localTransform.columns.3.x == 3)
        let runtime = SceneRuntime(scene: restored, puppetModels: library)
        let first = runtime.step(deltaTime: 0.5)
        // Bone x=7, anchor x=3, child x=2; parent scale=2 and a quarter
        // turn carry that 12-unit offset upward from the parent's (10,20).
        expect(first, childY: 44, grandchildY: 46)
        runtime.setPaused(true)
        expect(runtime.step(deltaTime: 1), childY: 44, grandchildY: 46)
        // Disabling the clip retains the stored bind pose (bone x=5),
        // without hiding either the parent image or its attached children.
        let disabled = runtime.step(deltaTime: 1, propertyOverrides: ["moving": .bool(false)])
        expect(disabled, childY: 40, grandchildY: 42)
        #expect(disabled.nodes.allSatisfy { $0.visible })
    }

    @Test(arguments: [AttachmentReference.name("missing"), .index(-1), .index(10)])
    func unresolvedAttachmentsRetainOrdinaryParentTransforms(reference: AttachmentReference) throws {
        let root = try fixture(reference: reference)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene, puppetModels: PuppetModelLibrary(assetRoots: [root]))
        expect(runtime.step(deltaTime: 0.5), childY: 24, grandchildY: 26)
    }

    private func expect(_ frame: FramePacket, childY: Float, grandchildY: Float) {
        #expect(abs(frame.nodes[0].worldPosition.x - 10) < 0.0001)
        #expect(abs(frame.nodes[0].worldPosition.y - childY) < 0.0001)
        #expect(abs(frame.nodes[1].worldPosition.x - 10) < 0.0001)
        #expect(abs(frame.nodes[1].worldPosition.y - grandchildY) < 0.0001)
    }

    func fixture(reference: AttachmentReference, mode: String = "loop", fps: Float = 1, frameCount: Int = 1,
                 controller: String? = nil, secondLayer: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEAttachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func json(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        let attachment: Any
        switch reference { case .name(let name): attachment = name; case .index(let index): attachment = index }
        try json("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "moving": ["type": "bool", "value": true], "command": ["type": "textinput", "value": ""],
            "speed": ["type": "slider", "value": 1],
        ]]])
        var animationLayers: [[String: Any]] = [["id": 1, "name": "Move", "animation": 10,
            "rate": ["value": 1, "user": "speed"], "blend": 1, "visible": ["value": true, "user": "moving"]]]
        if secondLayer { animationLayers.append(["id": 2, "name": "Other", "animation": 10, "rate": 2, "visible": false]) }
        var objects: [[String: Any]] = [
            ["id": 1, "parent": 9, "attachment": attachment, "image": "missing.json", "origin": "2 0 0"],
            ["id": 2, "parent": 1, "origin": "1 0 0"],
            ["id": 9, "name": "Puppet", "image": "model.json", "origin": "10 20 0", "scale": "2 2 1", "angles": "0 0 \(Double.pi / 2)",
             "animationlayers": animationLayers],
        ]
        if let controller { objects.append(["id": 90, "image": "missing.json", "origin": ["value": "0 0 0", "script": controller]]) }
        try json("scene.json", ["camera": [:], "general": [:], "objects": objects])
        try json("model.json", ["material": "material.json", "puppet": "puppet.mdl"])
        var data = Data("MDLV0023\0".utf8)
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func short(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { uint(value.bitPattern) }
        func string(_ value: String) { data.append(Data((value + "\0").utf8)) }
        func matrix(x: Float) {
            for i in 0..<16 { scalar(i == 12 ? x : i % 5 == 0 ? 1 : 0) }
        }
        uint(0x0180_000F); uint(1); uint(1); string("material.json"); uint(0)
        for value: Float in [0, 0, 0, 1, 1, 0] { scalar(value) }
        uint(0x0180_000F); uint(3 * 80)
        for uv: SIMD2<Float> in [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)] {
            for value: Float in [uv.x, uv.y, 0, 0, 0, 1, 1, 0, 0, -1] { scalar(value) }
            for _ in 0..<4 { uint(0) }
            for value: Float in [1, 0, 0, 0, uv.x, uv.y] { scalar(value) }
        }
        uint(6); data.append(contentsOf: [0, 0, 1, 0, 2, 0, 0, 0])
        string("MDLS0001"); uint(0); uint(1); string("root"); uint(1); uint(UInt32.max); uint(64); matrix(x: 5); string("")
        let attachmentStart = data.count
        string("MDAT0001"); uint(0); short(1); short(0); string("头"); matrix(x: 3)
        var end = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &end) { data.replaceSubrange(attachmentStart + 9..<attachmentStart + 13, with: $0) }
        string("MDLA0001"); uint(0); uint(1); uint(10); uint(0); string("move"); string(mode); scalar(fps); uint(UInt32(frameCount)); uint(0); uint(1)
        uint(0); uint(UInt32((frameCount + 1) * 36))
        for frame in 0...frameCount {
            let x = 5 + 4 * Float(frame) / Float(max(1, frameCount))
            for value: Float in [x, 0, 0, 0, 0, 0, 1, 1, 1] { scalar(value) }
        }
        uint(0)
        try data.write(to: root.appendingPathComponent("puppet.mdl"))
        return root
    }
}
