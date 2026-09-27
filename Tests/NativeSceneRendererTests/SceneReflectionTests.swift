import Foundation
import Metal
import NativeSceneCore
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct SceneReflectionTests {
    @Test(arguments: ["image", "effect", "text", "model", "particle"], [false, true])
    func reflectionSamplesSceneMipLevelsAndRefreshesBetweenFrames(kind: String, explicitTexture: Bool) throws {
        let root = try fixture(kind: kind, explicitTexture: explicitTexture)
        defer { try? FileManager.default.removeItem(at: root) }
        // Particle emitters start on the first positive simulation step.
        let frames = try render(root: root, deltaTimes: [0.01, 1])
        // The last mip averages red/green stripes. Level zero still sees red.
        // Blue reports the maximum mip level (6 for a 64-pixel texture).
        expectPixel(frames[0], red: 128, green: 255, blue: 255)
        // The animated underlay becomes blue. A cached old snapshot is wrong.
        expectPixel(frames[1], red: 0, green: 0, blue: 255)
    }

    @Test func laterReflectionLayersReadTheUpdatedScene() throws {
        let root = try fixture(kind: "image", explicitTexture: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scene.json"))) as? [String: Any])
        var objects = try #require(raw["objects"] as? [[String: Any]])
        var second = objects[1]; second["id"] = 3; objects.append(second); raw["objects"] = objects
        try write(raw, to: root.appendingPathComponent("scene.json"))
        let frames = try render(root: root, deltaTimes: [0])
        // The first reflection paints (0.5, 1, 1); the next sees 0.5 at both LODs.
        expectPixel(frames[0], red: 128, green: 128, blue: 255)
    }

    @Test(arguments: [false, true])
    func mipInformationSurvivesAnOptimizedOutSampler(explicitTexture: Bool) throws {
        let root = try fixture(kind: "image", explicitTexture: explicitTexture)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = explicitTexture ? "" : " // {\"default\":\"_rt_MipMappedFrameBuffer\"}"
        try """
        uniform sampler2D g_Texture5;\(metadata)
        uniform float g_Texture5MipMapInfo;
        void main() { gl_FragColor = vec4(g_Texture5MipMapInfo / 6.0, 0.0, 0.0, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/reflection.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root: root, deltaTimes: [0])
        expectPixel(frames[0], red: 255, green: 0, blue: 0)
    }

    @Test func reflectionNormalsUseTopFirstScreenCoordinates() throws {
        let root = try fixture(kind: "image", explicitTexture: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = v_TexCoord.y < 0.5 ? vec4(1, 0, 0, 1) : vec4(0, 1, 0, 1); }
        """.write(to: root.appendingPathComponent("shaders/background.frag"), atomically: true, encoding: .utf8)
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec3 v_ScreenPos;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            v_ScreenPos = gl_Position.xyw;
        #ifdef HLSL
            v_ScreenPos.y = -v_ScreenPos.y;
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/reflection.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture5; // {"default":"_rt_MipMappedFrameBuffer"}
        varying vec3 v_ScreenPos;
        void main() {
            vec2 screenUV = (v_ScreenPos.xy / v_ScreenPos.z) * 0.5 + 0.5;
            vec3 normal = vec3(0.0, 0.25, 0.0);
        #ifdef HLSL
            normal.y = -normal.y;
        #endif
            gl_FragColor = textureLod(g_Texture5, screenUV + normal.xy, 0.0);
        }
        """.write(to: root.appendingPathComponent("shaders/reflection.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root: root, deltaTimes: [0])
        // The stock reflection helper offsets projected +Y normals toward the
        // top of a Metal/Direct3D framebuffer, which is the red half here.
        expectPixel(frames[0], red: 255, green: 0, blue: 0)
    }

    @Test(arguments: ["effect", "text"], ["_rt_MipMappedFrameBuffer", "previous"])
    func effectBindingsSelectTheRequestedTexture(kind: String, path: String) throws {
        let root = try fixture(kind: kind, explicitTexture: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["passes": [["material": "reflection.json", "bind": [["index": 5, "name": path]]]]],
                  to: root.appendingPathComponent("effect.json"))
        let frames = try render(root: root, deltaTimes: [0.01])
        if path == "_rt_MipMappedFrameBuffer" {
            expectPixel(frames[0], red: 128, green: 255, blue: 255)
        } else {
            // The effect input is a single-level texture. It overrides the
            // sampler's default reflection target, including its mip metadata.
            #expect(frames[0][(32 * 64 + 32) * 4 + 2] == 0)
        }
    }

    private func expectPixel(_ pixels: [UInt8], red: Int, green: Int, blue: Int) {
        let offset = (32 * 64 + 32) * 4
        for (index, expected) in [red, green, blue].enumerated() {
            #expect(abs(Int(pixels[offset + index]) - expected) <= 1)
        }
    }

    private func fixture(kind: String, explicitTexture: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEReflection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try write(["type": "scene", "file": "scene.json"], to: root.appendingPathComponent("project.json"))
        var reflection: [String: Any] = ["id": 2, "image": "reflection-model.json", "origin": "32 32 0"]
        if kind == "effect" {
            reflection["image"] = "plain-model.json"
            reflection["effects"] = [["id": 1, "file": "effect.json"]]
        } else if kind == "text" {
            reflection.removeValue(forKey: "image")
            reflection["text"] = "H"; reflection["font"] = "Helvetica"; reflection["pointsize"] = 12
            reflection["size"] = "64 64"; reflection["padding"] = 0
            reflection["horizontalalign"] = "center"; reflection["verticalalign"] = "center"
            reflection["effects"] = [["id": 1, "file": "effect.json"]]
        } else if kind == "model" {
            reflection.removeValue(forKey: "image"); reflection["model"] = "reflection.mdl"
        } else if kind == "particle" {
            reflection.removeValue(forKey: "image")
            reflection["particle"] = ["maxcount": 1, "material": "reflection.json",
                "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
                "initializer": [["name": "sizerandom", "min": 64, "max": 64],
                                ["name": "lifetimerandom", "min": 10, "max": 10]],
                "renderer": [["name": "sprite"]]]
        }
        try write(["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                   "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
                   "objects": [["id": 1, "image": "background-model.json", "origin": "32 32 0"], reflection]],
                  to: root.appendingPathComponent("scene.json"))
        for name in ["background", "reflection", "plain"] {
            try write(["material": name + ".json", "width": 64, "height": 64], to: root.appendingPathComponent(name + "-model.json"))
            var pass: [String: Any] = ["shader": name, "blending": "normal"]
            if name == "reflection", explicitTexture {
                pass["textures"] = [NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), "_rt_MipMappedFrameBuffer"]
            }
            try write(["passes": [pass]], to: root.appendingPathComponent(name + ".json"))
            try """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            uniform mat4 g_ModelViewProjectionMatrix;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
                v_TexCoord = a_TexCoord;
            }
            """.write(to: root.appendingPathComponent("shaders/" + name + ".vert"), atomically: true, encoding: .utf8)
        }
        try write(["passes": [["material": "reflection.json"]]], to: root.appendingPathComponent("effect.json"))
        try "void main() { gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0); }"
            .write(to: root.appendingPathComponent("shaders/plain.frag"), atomically: true, encoding: .utf8)
        try """
        uniform float g_Time;
        varying vec2 v_TexCoord;
        void main() {
            float stripe = step(0.5, fract(v_TexCoord.x * 8.0));
            gl_FragColor = g_Time < 0.5 ? vec4(1.0 - stripe, stripe, 0.0, 1.0) : vec4(0.0, 0.0, 1.0, 1.0);
        }
        """.write(to: root.appendingPathComponent("shaders/background.frag"), atomically: true, encoding: .utf8)
        let metadata = explicitTexture ? "" : " // {\"default\":\"_rt_MipMappedFrameBuffer\"}"
        try """
        uniform sampler2D g_Texture5;\(metadata)
        uniform float g_Texture5MipMapInfo;
        void main() {
            float rough = textureLod(g_Texture5, vec2(0.03125, 0.25), g_Texture5MipMapInfo).r;
            float sharp = textureLod(g_Texture5, vec2(0.03125, 0.25), 0.0).r;
            gl_FragColor = vec4(rough, sharp, g_Texture5MipMapInfo / 6.0, 1.0);
        }
        """.write(to: root.appendingPathComponent("shaders/reflection.frag"), atomically: true, encoding: .utf8)
        var data = Data("MDLV0021\0".utf8)
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { uint(value.bitPattern) }
        uint(15); uint(1); uint(1); data.append(Data("reflection.json\0".utf8)); uint(0)
        for value: Float in [-32, -32, 0, 32, 32, 0] { scalar(value) }
        uint(15); uint(4 * 48)
        for (x, y): (Float, Float) in [(-32, -32), (32, -32), (32, 32), (-32, 32)] {
            for value: Float in [x, y, 0, 0, 0, 1, 1, 0, 0, -1, x / 64 + 0.5, 0.5 - y / 64] { scalar(value) }
        }
        uint(12); data.append(contentsOf: [0, 0, 1, 0, 2, 0, 0, 0, 2, 0, 3, 0, 0, 0, 0])
        try data.write(to: root.appendingPathComponent("reflection.mdl"))
        return root
    }

    private func render(root: URL, deltaTimes: [Double]) throws -> [[UInt8]] {
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        return try deltaTimes.map { delta in
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: delta, into: texture, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            texture.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            return pixels
        }
    }
    private func write(_ value: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
}
