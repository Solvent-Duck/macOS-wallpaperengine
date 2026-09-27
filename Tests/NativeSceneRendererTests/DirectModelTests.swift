import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct DirectModelTests {
    @Test(arguments: [14, 19, 21, 23])
    func modelSectionsRetainGeometryAndTheirOwnMaterials(version: Int) throws {
        let data = model(version: version, sections: [("left.json", -1, 0, -2), ("right.json", 0, 1, -2)])
        let meshes = try DirectModelDecoder.decode(data)
        #expect(meshes.map(\.material) == ["left.json", "right.json"])
        #expect(meshes.map { $0.vertices.count } == [4, 4])
        #expect(meshes.map { $0.indices.count } == [6, 6])
        #expect(meshes[0].vertices[0].position == SIMD3(-1, -1, -2))
        #expect(meshes[1].vertices[2].position == SIMD3(1, 1, -2))
        #expect(meshes[0].vertices[0].normal == SIMD3(0, 0, 1))
        #expect(meshes[0].vertices[0].tangent == SIMD4(1, 0, 0, -1))
        #expect(meshes[0].vertices[2].uv == SIMD2(1, 0))
        #expect(throws: DirectModelError.self) { try DirectModelDecoder.decode(data.dropLast(8)) }
    }

    @Test(arguments: [14, 21])
    func malformedMeshIndicesAndNonfiniteVerticesAreRejected(version: Int) throws {
        let good = model(version: version, sections: [("left.json", -1, 1, -2)])
        var bad = good
        // Six UInt16 indices, optional metadata, and a file terminator.
        // Corrupt the first index, then a position.
        bad[bad.count - (version == 14 ? 13 : 15)] = 255
        #expect(throws: DirectModelError.self) { try DirectModelDecoder.decode(bad) }
        bad = good
        let vertexStart = 21 + "left.json".utf8.count + 1 + (version == 14 ? 8 : 36)
        bad.replaceSubrange(vertexStart..<vertexStart + 4, with: [0, 0, 128, 127])
        #expect(throws: DirectModelError.self) { try DirectModelDecoder.decode(bad) }
    }

    @Test(arguments: [false, true], [14, 21])
    func directModelsRenderEveryMaterialAndDepthOccludesLaterGeometry(reverseOrder: Bool, version: Int) throws {
        let root = try fixture(frontVersion: version)
        defer { try? FileManager.default.removeItem(at: root) }
        if reverseOrder {
            var scene = try json(root.appendingPathComponent("scene.json"))
            scene["objects"] = (scene["objects"] as! [[String: Any]]).reversed().map { $0 }
            try write(scene, to: root.appendingPathComponent("scene.json"))
        }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        #expect(scene.scene?.camera.projection.isPerspective == true)
        let front = try #require(scene.nodes.first { $0.id.rawValue == 1 })
        #expect(front.image?.model?.meshMaterials?.compactMap { $0?.filename } == ["red.json", "green.json"])
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(scene))
        #expect(restored == scene)
        let pixels = try render(scene: scene, root: root)
        #expect(pixel(pixels, x: 24, y: 32) == [255, 0, 0])
        #expect(pixel(pixels, x: 40, y: 32) == [0, 255, 0])
        #expect(pixel(pixels, x: 8, y: 32) == [0, 0, 0])
    }

    @Test func perspectiveChangesApparentSizeAndHonorsCameraTranslation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        raw["objects"] = [["id": 2, "model": "back.mdl", "origin": "0 0 0"]]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        var scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let far = try render(scene: scene, root: root)
        #expect(pixel(far, x: 24, y: 32) == [0, 0, 255])
        #expect(pixel(far, x: 18, y: 32) == [0, 0, 0])
        raw["camera"] = ["eye": "1 0 2", "center": "1 0 1", "up": "0 1 0"]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let moved = try render(scene: scene, root: root)
        #expect(pixel(moved, x: 25, y: 32) == [0, 0, 255])
        #expect(pixel(moved, x: 35, y: 32) == [0, 0, 0])
    }

    @Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
    func translucentSectionsBlendOverOpaqueGeometryInCameraDepthOrder(sameModel: Bool, reverseOrder: Bool, rotatedCamera: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        let angles = rotatedCamera ? "0 \(-Double.pi / 2) 0" : "0 0 0"
        if rotatedCamera { raw["camera"] = ["eye": "0 0 0", "center": "1 0 0", "up": "0 1 0"] }
        var sections: [(String, Float, Float, Float)] = [("red.json", -1, 1, -2), ("green.json", -1, 1, -2.5), ("blue.json", -1, 1, -3)]
        if reverseOrder { sections.reverse() }
        var objects: [[String: Any]] = []
        if sameModel {
            try model(version: 21, sections: sections).write(to: root.appendingPathComponent("layers.mdl"))
            objects = [["id": 1, "model": "layers.mdl", "angles": angles, "dependencies": [1]]]
        } else {
            for (index, section) in sections.enumerated() {
                let name = "layer\(index).mdl"
                try model(version: 21, sections: [section]).write(to: root.appendingPathComponent(name))
                objects.append(["id": index + 1, "model": name, "angles": angles])
            }
        }
        raw["objects"] = objects
        try write(raw, to: root.appendingPathComponent("scene.json"))
        for (name, color) in [("red", "1 0 0"), ("green", "0 1 0"), ("blue", "0 0 1")] {
            try write(["passes": [["shader": "transparent", "blending": name == "blue" ? "normal" : "translucent", "depthtest": "enabled", "depthwrite": "enabled",
                                   "constantshadervalues": ["tint": color, "testopacity": name == "blue" ? "1" : "0.5"]]]], to: root.appendingPathComponent(name + ".json"))
        }
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); v_TexCoord = a_TexCoord; }
        """.write(to: root.appendingPathComponent("shaders/transparent.vert"), atomically: true, encoding: .utf8)
        try """
        uniform vec3 g_Tint; // {"material":"tint","default":"0 0 0"}
        uniform float g_TestOpacity; // {"material":"testopacity","default":0.5}
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(g_Tint, g_TestOpacity < 1.0 && v_TexCoord.y < 0.5 ? 0.0 : g_TestOpacity); }
        """.write(to: root.appendingPathComponent("shaders/transparent.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let pixels = try render(scene: scene, root: root)
        #expect(pixel(pixels, x: 32, y: 28) == [0, 0, 255])
        let blended = pixel(pixels, x: 32, y: 36)
        for (actual, expected) in zip(blended, [128, 64, 64]) { #expect(abs(Int(actual) - expected) <= 1) }
    }

    @Test func modelTextureDependenciesTakePrecedenceOverTransparencySorting() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        raw["objects"] = [["id": 2, "model": "consumer.mdl", "dependencies": [1]], ["id": 1, "model": "producer.mdl"]]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        try model(version: 21, sections: [("producer.json", -1, 1, -2)]).write(to: root.appendingPathComponent("producer.mdl"))
        try model(version: 21, sections: [("consumer.json", -1, 1, -3)]).write(to: root.appendingPathComponent("consumer.mdl"))
        for name in ["producer", "consumer"] {
            try write(["passes": [["shader": name, "blending": "translucent", "depthtest": "disabled", "depthwrite": "disabled"]]],
                      to: root.appendingPathComponent(name + ".json"))
            try """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            uniform mat4 g_ModelViewProjectionMatrix;
            varying vec2 v_TexCoord;
            void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); v_TexCoord = a_TexCoord; }
            """.write(to: root.appendingPathComponent("shaders/\(name).vert"), atomically: true, encoding: .utf8)
        }
        try """
        void main() { gl_FragColor = vec4(0, 0, 1, 1); }
        """.write(to: root.appendingPathComponent("shaders/producer.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(texSample2D(g_Texture0, v_TexCoord).rgb * 0.5 + vec3(0.5, 0, 0), 1); }
        """.write(to: root.appendingPathComponent("shaders/consumer.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let blended = pixel(try render(scene: scene, root: root), x: 32, y: 32)
        for (actual, expected) in zip(blended, [128, 0, 128]) { #expect(abs(Int(actual) - expected) <= 1) }
    }

    @Test(arguments: [false, true], [0.5, 2.0])
    func cameraZoomScalesModelsOnlyIn2D(full3D: Bool, zoom: Double) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        var general = try #require(raw["general"] as? [String: Any])
        general["zoom"] = zoom
        if !full3D {
            general["orthogonalprojection"] = ["width": 64, "height": 64]
            general["perspectiveoverridefov"] = 90
        }
        raw["general"] = general
        raw["objects"] = [["id": 1, "model": "front.mdl", "perspective": true,
                           "origin": full3D ? "0 0 0" : "32 32 0", "scale": full3D ? "1 1 1" : "16 16 16"]]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let pixels = try render(scene: scene, root: root)
        // The 2D plane is 64 units from the camera after local Z and scale.
        let halfWidth = full3D ? 16 : Int(8 * zoom)
        #expect(pixel(pixels, x: 32 - halfWidth, y: 32) == [255, 0, 0])
        #expect(pixel(pixels, x: 31 - halfWidth, y: 32) == [0, 0, 0])
        #expect(pixel(pixels, x: 31 + halfWidth, y: 32) == [0, 255, 0])
        #expect(pixel(pixels, x: 32 + halfWidth, y: 32) == [0, 0, 0])
    }

    @Test(arguments: [false, true])
    func embeddedModelsShareThe2DCameraOffsetCancellation(perspective: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try json(path)
        raw["general"] = ["orthogonalprojection": ["width": 64, "height": 64],
                          "perspectiveoverridefov": 90, "nearz": 0.1, "farz": 1000, "clearcolor": "0 0 0"]
        raw["objects"] = [["id": 1, "model": "front.mdl", "perspective": perspective,
                           "origin": "32 32 0", "scale": "16 16 16"]]
        try write(raw, to: path)
        let initial = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let expected = try render(scene: initial, root: root)
        #expect(pixel(expected, x: 31, y: 32) == [255, 0, 0])
        raw["camera"] = ["eye": "23 -9 1", "center": "23 -9 0", "up": "0 1 0"]
        try write(raw, to: path)
        let moved = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        #expect(try render(scene: moved, root: root) == expected)
    }

    @Test func perspectiveModelsIn2DKeepMeshDepthWithoutInheritingFlatLayerDepth() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        raw["general"] = ["orthogonalprojection": ["width": 64, "height": 64],
                          "perspectiveoverridefov": 90, "nearz": 0.1, "farz": 1000, "clearcolor": "0 0 0"]
        raw["objects"] = [
            ["id": 2, "model": "back.mdl", "origin": "32 32 0", "scale": "24 24 24"],
            ["id": 1, "model": "front.mdl", "origin": "32 32 32", "scale": "16 16 16", "perspective": true]
        ]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        // A farther section is submitted last within the foreground model.
        // Its depth still has to be compared with that model's first sections.
        try model(version: 21, sections: [("red.json", -1, 0, -2), ("green.json", 0, 1, -2),
                                         ("blue.json", -1.5, 1.5, -4)])
            .write(to: root.appendingPathComponent("front.mdl"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        #expect(scene.scene?.camera.projection.isPerspective == false)
        #expect(scene.nodes.first { $0.id.rawValue == 1 }?.image?.perspective == true)
        let pixels = try render(scene: scene, root: root)
        #expect(pixel(pixels, x: 24, y: 32) == [255, 0, 0])
        #expect(pixel(pixels, x: 40, y: 32) == [0, 255, 0])
        #expect(pixel(pixels, x: 8, y: 32) == [0, 0, 255])
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func skeletalDepthMotionUsesTheLayerClockAndBlend(blend: Double) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        raw["objects"] = [["id": 1, "model": "animated.mdl",
                           "animationlayers": [["id": 100, "animation": 10, "blend": blend, "rate": 1]]]]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        var data = model(version: 21, sections: [("blue.json", -1, 1, -4)], skinned: true)
        data.removeLast()
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { uint(value.bitPattern) }
        func string(_ value: String) { data.append(Data((value + "\0").utf8)) }
        string("MDLS0001"); uint(0); uint(1); string(""); uint(1); uint(UInt32.max); uint(64)
        for i in 0..<16 { scalar(i % 5 == 0 ? 1 : 0) }
        string(""); string("MDLA0001"); uint(0); uint(1)
        uint(10); uint(0); string("toward camera"); string("loop"); scalar(1); uint(2); uint(0); uint(1)
        uint(0); uint(72)
        for z: Float in [0, 4] {
            for value: Float in [0, 0, z, 0, 0, 0, 1, 1, 1] { scalar(value) }
        }
        uint(0)
        try data.write(to: root.appendingPathComponent("animated.mdl"))
        let decoded = try DirectModelDecoder.decode(data)
        #expect(decoded[0].skinned)
        #expect(decoded[0].vertices[0].position.z == -4)
        #expect(decoded[0].vertices[0].weights == SIMD4(1, 0, 0, 0))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let pixels = try render(scene: scene, root: root, deltaTime: 0.5)
        #expect(pixel(pixels, x: 22, y: 32) == (blend > 0 ? [0, 0, 255] : [0, 0, 0]))
        #expect(pixel(pixels, x: 18, y: 32) == (blend == 1 ? [0, 0, 255] : [0, 0, 0]))
        #expect(pixel(pixels, x: 28, y: 32) == [0, 0, 255])
    }

    @Test func large2DPixelPlanesRemainInsideTheModelCameraFrustum() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        raw["general"] = ["orthogonalprojection": ["width": 4096, "height": 4096],
                          "perspectiveoverridefov": 90, "farz": 1000, "clearcolor": "0 0 0"]
        raw["objects"] = [["id": 1, "model": "front.mdl", "perspective": true,
                           "origin": "2048 2048 1024", "scale": "512 512 512"]]
        try write(raw, to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let pixels = try render(scene: scene, root: root)
        #expect(pixel(pixels, x: 28, y: 32) == [255, 0, 0])
        #expect(pixel(pixels, x: 36, y: 32) == [0, 255, 0])
    }

    @Test(arguments: ["test", "write"])
    func sharedMaterialPipelinesHonorEachPassDepthState(changedState: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try json(root.appendingPathComponent("scene.json"))
        raw["objects"] = (1...3).map { ["id": $0, "model": "depth\($0).mdl"] as [String: Any] }
        try write(raw, to: root.appendingPathComponent("scene.json"))
        for id in 1...3 {
            try model(version: 21, sections: [("red.json", -1, 1, Float(-2 * id))])
                .write(to: root.appendingPathComponent("depth\(id).mdl"))
        }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let pixels = try render(scene: scene, root: root) { material in
            let id = material.sourceNodeID.rawValue
            let passes = material.passes.map { pass in
                FrameMaterialPass(index: pass.index, shaderPath: pass.shaderPath, blending: pass.blending,
                    culling: pass.culling, depthTest: changedState == "test" && id == 2 ? 0 : 1,
                    depthWrite: changedState == "write" && id == 1 ? 0 : 1,
                    textures: pass.textures, userTextures: pass.userTextures,
                    constants: ["tint": .vec3(id == 1 ? [1, 0, 0] : id == 2 ? [0, 0, 1] : [0, 1, 0])], combos: pass.combos)
            }
            return FrameMaterial(id: material.id, sourceNodeID: material.sourceNodeID, sourceFile: material.sourceFile,
                                 passOrdering: material.passOrdering, passes: passes)
        }
        #expect(pixel(pixels, x: 32, y: 32) == [0, 0, 255])
    }

    private func fixture(frontVersion: Int = 21) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEDirectModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try write(["type": "scene", "file": "scene.json"], to: root.appendingPathComponent("project.json"))
        try write(["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                   "general": ["orthogonalprojection": NSNull(), "fov": 90, "nearz": 0.1, "farz": 100, "clearcolor": "0 0 0"],
                   "objects": [["id": 1, "model": "front.mdl"], ["id": 2, "model": "back.mdl"]]],
                  to: root.appendingPathComponent("scene.json"))
        try model(version: frontVersion, sections: [("red.json", -1, 0, -2), ("green.json", 0, 1, -2)])
            .write(to: root.appendingPathComponent("front.mdl"))
        try model(version: 23, sections: [("blue.json", -1.5, 1.5, -4)])
            .write(to: root.appendingPathComponent("back.mdl"))
        for (name, color) in [("red", "1 0 0"), ("green", "0 1 0"), ("blue", "0 0 1")] {
            try write(["passes": [["shader": "mesh", "depthtest": "enabled", "depthwrite": "enabled", "cullmode": "normal",
                                   "constantshadervalues": ["tint": color]]]], to: root.appendingPathComponent(name + ".json"))
        }
        try """
        attribute vec3 a_Position;
        attribute vec3 a_Normal;
        attribute vec4 a_Tangent4;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat3 g_NormalModelMatrix;
        varying float v_Light;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            v_Light = normalize(g_NormalModelMatrix * a_Normal).z * -a_Tangent4.w;
        }
        """.write(to: root.appendingPathComponent("shaders/mesh.vert"), atomically: true, encoding: .utf8)
        try """
        uniform vec3 g_Tint; // {"material":"tint","default":"0 0 0"}
        varying float v_Light;
        void main() { gl_FragColor = vec4(g_Tint * v_Light, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/mesh.frag"), atomically: true, encoding: .utf8)
        return root
    }

    private func model(version: Int, sections: [(String, Float, Float, Float)], skinned: Bool = false) -> Data {
        var data = Data(String(format: "MDLV%04d\0", version).utf8)
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { uint(value.bitPattern) }
        let layout: UInt32 = skinned ? 0x0180_000F : 15
        uint(layout); uint(1); uint(UInt32(sections.count))
        for (material, left, right, z) in sections {
            data.append(Data((material + "\0").utf8)); uint(0)
            if version != 14 {
                for value: Float in [left, -1, z, right, 1, z] { scalar(value) }
                uint(layout)
            }
            uint(skinned ? 4 * 80 : 4 * 48)
            for (x, y, u, v): (Float, Float, Float, Float) in [(left, -1, 0, 1), (right, -1, 1, 1), (right, 1, 1, 0), (left, 1, 0, 0)] {
                for value: Float in [x, y, z, 0, 0, 1, 1, 0, 0, -1] { scalar(value) }
                if skinned {
                    for _ in 0..<4 { uint(0) }
                    for weight: Float in [1, 0, 0, 0] { scalar(weight) }
                }
                scalar(u); scalar(v)
            }
            uint(12); data.append(contentsOf: [0, 0, 1, 0, 2, 0, 0, 0, 2, 0, 3, 0])
            data.append(Data(repeating: 0, count: version == 23 ? 6 : version == 21 ? 2 : 0))
        }
        data.append(0)
        return data
    }

    private func render(scene: SceneDescription, root: URL, deltaTime: Double = 0,
                        materialOverride: ((FrameMaterial) -> FrameMaterial)? = nil) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(queue.makeCommandBuffer())
        if let materialOverride {
            let packet = SceneRuntime(scene: scene).step(deltaTime: deltaTime)
            let updated = FramePacket(metadata: packet.metadata, timing: packet.timing, cursor: packet.cursor,
                cameraBloom: packet.cameraBloom, properties: packet.properties, nodes: packet.nodes,
                materials: packet.materials.map(materialOverride), lights: packet.lights,
                particleSystems: packet.particleSystems, texts: packet.texts, audio: packet.audio, cameraZoom: packet.cameraZoom)
            try renderer.render(packet: updated, into: texture, commandBuffer: command)
        } else {
            try renderer.renderNextFrame(deltaTime: deltaTime, into: texture, commandBuffer: command)
        }
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        texture.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return pixels
    }
    private func pixel(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] { Array(pixels[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3]) }
    private func json(_ url: URL) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
    private func write(_ value: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
}
