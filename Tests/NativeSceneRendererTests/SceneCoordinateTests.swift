import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import NativeSceneCore
import NativeSceneCompatibility
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing
import UniformTypeIdentifiers

@Suite(.serialized)
struct SceneCoordinateTests {
    @Test(arguments: [0, 1, 2], [false, true])
    func orthographicCameraUsesItsViewTransform(effectCount: Int, rolled: Bool) throws {
        let root = try makeFixture(effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        // The projection's eye offset and the paired look-at view cancel for
        // a forward-facing 2D camera. Roll still changes the view's axes.
        scene["camera"] = rolled
            ? ["eye": "0 0 0", "center": "0 0 -1", "up": "1 0 0"]
            : ["eye": "23 -9 1", "center": "23 -9 0", "up": "0 1 0"]
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        for pixels in try renderFrames(root: root, deltaTimes: [0, 1 / 30]) {
            func rgb(_ x: Int, _ y: Int) -> [UInt8] {
                Array(pixels[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3])
            }
            if rolled {
                #expect(rgb(8, 48) == [255, 0, 0])
                #expect(rgb(24, 48) == [0, 0, 255])
                #expect(rgb(8, 8) == [0, 0, 0])
            } else {
                #expect(rgb(8, 8) == [255, 0, 0])
                #expect(rgb(8, 24) == [0, 0, 255])
                #expect(rgb(48, 48) == [0, 0, 0])
            }
        }
    }

    @Test(arguments: ["0 0 0", "0 0 1"])
    func degenerateCameraAxesKeepAFiniteView(up: String) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        scene["camera"] = ["eye": "0 0 0", "center": "0 0 0", "up": up]
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let pixels = try renderPixels(root: root)
        #expect(Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3]) == [255, 0, 0])
        #expect(Array(pixels[(24 * 64 + 8) * 4..<(24 * 64 + 8) * 4 + 3]) == [0, 0, 255])
    }

    @Test(arguments: [false, true], [0.0, 0.5, 1.0])
    func puppetLayersHonorVisibilityAndBlend(visible: Bool, blend: Double) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ path: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        try json("model.json", ["material": "material.json", "puppet": "puppet.mdl", "width": 32, "height": 32])
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scene.json"))) as? [String: Any])
        var nodes = try #require(scene["objects"] as? [[String: Any]])
        nodes[0]["animationlayers"] = [["id": 100, "animation": 10, "visible": visible, "blend": blend, "rate": 1]]
        scene["objects"] = nodes
        try json("scene.json", scene)

        // One triangular mesh and one bone translating half a mesh width
        // over a one-second clip. At t=0.5, full/half blend move 8/4 pixels.
        var data = Data("MDLV0021\0".utf8)
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { uint(value.bitPattern) }
        func string(_ value: String) { data.append(Data((value + "\0").utf8)) }
        uint(0x0180_000F); uint(1); uint(1); string("material.json"); uint(0)
        for value: Float in [-0.5, -0.5, 0, 0.5, 0.5, 0] { scalar(value) }
        uint(0x0180_000F); uint(3 * 80)
        for uv: SIMD2<Float> in [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)] {
            for value: Float in [uv.x - 0.5, uv.y - 0.5, 0, 0, 0, 1, 1, 0, 0, -1] { scalar(value) }
            for _ in 0..<4 { uint(0) }
            for value: Float in [1, 0, 0, 0, uv.x, uv.y] { scalar(value) }
        }
        uint(6); data.append(contentsOf: [0, 0, 1, 0, 2, 0, 0, 0])
        string("MDLS0001"); uint(0); uint(1); string(""); uint(1); uint(UInt32.max); uint(64)
        for i in 0..<16 { scalar(i % 5 == 0 ? 1 : 0) }
        string(""); string("MDLA0001"); uint(0); uint(1)
        let clipStart = data.count
        uint(10); uint(0); string("move"); string("loop"); scalar(1); uint(2); uint(0); uint(1)
        uint(0); uint(72)
        for x: Float in [0, 0.5] {
            for value: Float in [x, 0, 0, 0, 0, 0, 1, 1, 1] { scalar(value) }
        }
        uint(0)
        let variants = [(1, 4, 0), (2, 4, 0), (3, 9, 0), (4, 10, 0),
                        (5, 34, 0), (6, 35, 0), (6, 35, 18), (5, 34, 192_720)]
        for (version, trailerSize, extraBytes) in variants {
            var encoded = data
            let animationStart = try #require(encoded.range(of: Data("MDLA0001\0".utf8))?.lowerBound)
            encoded.replaceSubrange(0..<8, with: Data("MDLV0023".utf8))
            encoded.replaceSubrange(animationStart..<animationStart + 8,
                                    with: Data(String(format: "MDLA%04d", version).utf8))
            encoded.replaceSubrange(animationStart + 13..<animationStart + 17, with: [2, 0, 0, 0])
            encoded.removeLast(4)
            encoded.append(Data(repeating: 0, count: trailerSize + extraBytes))
            var secondClip = Data(data[clipStart..<data.count - 4])
            secondClip.replaceSubrange(0..<4, with: [11, 0, 0, 0])
            encoded.append(secondClip)
            encoded.append(Data(repeating: 0, count: trailerSize))
            // Newer skeletons include constraint/controller metadata before
            // MDLA. An embedded non-header string must be ignored.
            encoded.insert(contentsOf: Data(repeating: 0, count: 40) + Data("MDLAoops\0".utf8), at: animationStart)
            let bindTranslation: Float = extraBytes == 18 ? 0.125 : 0
            if bindTranslation != 0 {
                let skeleton = try #require(encoded.range(of: Data("MDLS0001\0".utf8))?.lowerBound)
                var bits = bindTranslation.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { encoded.replaceSubrange(skeleton + 78..<skeleton + 82, with: $0) }
            }
            let decoded = try PuppetModelDecoder.decode(encoded)
            #expect(decoded.animations.map(\.id) == [10, 11])
            #expect(decoded.bones[0].bindTransform.columns.3.x == bindTranslation)
            if !visible, blend == 0 {
                // A title alone is not a clip header. A truncated following
                // track must fail instead of accepting metadata as a clip.
                var truncated = encoded
                truncated.removeLast(trailerSize + 1)
                #expect(throws: PuppetModelError.self) { try PuppetModelDecoder.decode(truncated) }
                var bounded = encoded
                let header = try #require(bounded.range(of: Data(String(format: "MDLA%04d\0", version).utf8))?.lowerBound)
                var end = UInt32(header + 17).littleEndian
                withUnsafeBytes(of: &end) { bounded.replaceSubrange(header + 9..<header + 13, with: $0) }
                #expect(throws: PuppetModelError.self) { try PuppetModelDecoder.decode(bounded) }
            }
            nodes[0]["animationlayers"] = [["id": 100, "animation": 11,
                                           "visible": visible, "blend": blend, "rate": 1]]
            scene["objects"] = nodes
            try json("scene.json", scene)
            try encoded.write(to: root.appendingPathComponent("puppet.mdl"))
            let pixels = try renderPixels(root: root, deltaTime: 0.5)
            let shift = visible ? blend * (8 - 32 * Double(bindTranslation)) : 0
            for x in [2, 6, 10] {
                let offset = (8 * 64 + x) * 4
                let expected: [UInt8] = Double(x) >= shift ? [255, 0, 0] : [0, 0, 0]
                #expect(Array(pixels[offset..<offset + 3]) == expected, "animation version: \(version), extra metadata: \(extraBytes)")
            }
        }
        if visible, blend == 1 {
            // Exercise the renderer with a paused/sought clock while global
            // elapsed time keeps changing. Sampling elapsedTime here would
            // place this mesh at a different horizontal position.
            try data.write(to: root.appendingPathComponent("puppet.mdl"))
            nodes[0]["animationlayers"] = [["id": 100, "animation": 10, "visible": true, "blend": 1, "rate": 1]]
            nodes[0]["alpha"] = ["value": 1, "script": """
            const clip = thisLayer.getAnimationLayer(0);
            export function init() { clip.pause(); clip.setFrame(0.25); }
            export function update(value) {
                if (engine.userProperties.command === 'play') clip.play();
                if (engine.userProperties.command === 'stop') clip.stop();
                return value;
            }
            """]
            scene["objects"] = nodes
            try json("scene.json", scene)
            try json("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
                "command": ["type": "textinput", "value": ""]
            ]]])
            let frames = try renderFrames(root: root, deltaTimes: [0.5, 3, 0, 0.25, 0], propertyOverrides: [
                [:], [:], ["command": .string("play")], [:], ["command": .string("stop")]
            ])
            for (pixels, shift) in zip(frames, [4, 4, 4, 8, 0]) {
                for x in [2, 6, 10] {
                    let offset = (8 * 64 + x) * 4
                    #expect(Array(pixels[offset..<offset + 3]) == (x >= shift ? [255, 0, 0] : [0, 0, 0]))
                }
            }
        }
    }

    @Test(arguments: [false, true], ["path", "slot", "name"])
    func sceneReadHazardsUseActiveSamplerBindings(samplesScene: Bool, binding: String) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "textures": ["colors.png", "scene-input"], "blending": "normal"]]])
            .write(to: root.appendingPathComponent("material.json"))
        try """
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture1Resolution;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = \(samplesScene ? "texSample2D(g_Texture1, v_TexCoord)" : "vec4(g_Texture1Resolution.x / 64.0)"); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let material = try #require(SceneRuntime(scene: scene).step(deltaTime: 0).materials.first)
        let pass = try #require(material.passes.first)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let binder = try MaterialBinder(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let sceneTexture = try #require(device.makeTexture(descriptor: descriptor))
        let otherTexture = try #require(device.makeTexture(descriptor: descriptor))
        let context = MaterialBindingContext(viewportSize: CGSize(width: 64, height: 64),
            textureOverridesBySlot: binding == "slot" ? [1: sceneTexture] : [:],
            textureOverridesByName: [binding == "name" ? "g_Texture1" : "scene-input": binding == "slot" ? otherTexture : sceneTexture])
        let prepared = try binder.preparePass(material: material, pass: pass, bindingContext: context)
        #expect(try binder.samplesTexture(sceneTexture, preparedPass: prepared, bindingContext: context) == samplesScene)
        #expect(try !binder.samplesTexture(otherTexture, preparedPass: prepared, bindingContext: context))
        if samplesScene {
            // The sole active WE sampler is texture 1, while Metal assigns it
            // slot 0. Hazard checks must follow the authored binding semantics.
            #expect(prepared.compiledShader.metal.fragmentTextureSlots["g_Texture1"] == 0)
        }
    }

    @Test(arguments: [0, 1, 2], [(false, false), (true, false), (false, true), (true, true)])
    func composeLayersCaptureTheirSceneRegionForConsumers(effectCount: Int, configuration: (Bool, Bool)) throws {
        let (visible, laterLayer) = configuration
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ path: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        let background = try #require((scene["objects"] as? [[String: Any]])?.first)
        scene["objects"] = [background,
            ["id": 2, "name": "capture", "image": "capture-model.json", "size": "32 32", "origin": "16 48 0", "visible": visible,
             "effects": (0..<effectCount).map { ["id": $0 + 10, "file": "effect.json"] }],
            ["id": 3, "name": "consumer", "image": "consumer-model.json", "origin": "48 48 0", "dependencies": [2]]]
        if laterLayer {
            var objects = try #require(scene["objects"] as? [[String: Any]])
            objects.insert(["id": 4, "image": "green-model.json", "origin": "16 48 0"], at: 2)
            scene["objects"] = objects
            try json("green-model.json", ["material": "green-material.json", "width": 32, "height": 32])
            try json("green-material.json", ["passes": [["shader": "green"]]])
            try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/green.vert"))
            try "void main() { gl_FragColor = vec4(0, 1, 0, 1); }".write(
                to: root.appendingPathComponent("shaders/green.frag"), atomically: true, encoding: .utf8)
        }
        try json("scene.json", scene)
        try json("capture-model.json", ["material": "capture-material.json", "passthrough": true])
        try json("capture-material.json", ["passes": [["shader": "capture", "blending": "translucent", "textures": ["_rt_FullFrameBuffer"]]]])
        try json("consumer-model.json", ["material": "consumer-material.json", "width": 32, "height": 32])
        try json("consumer-material.json", ["passes": [["shader": "copy", "textures": ["_rt_imageLayerComposite_2_a"]]]])
        // The stock compose shader uses geometry for scene sampling and UVs
        // for its destination. Both HLSL coordinate adjustments apply on Metal.
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec3 v_ScreenCoord;
        void main() {
            v_ScreenCoord = (g_ModelViewProjectionMatrix * vec4(a_Position, 1.0)).xyw;
            vec3 position = vec3(a_TexCoord, 0.0);
        #ifdef HLSL
            position.y = 1.0 - position.y;
            v_ScreenCoord.y = -v_ScreenCoord.y;
        #endif
            position.xy = position.xy * 2.0 - 1.0;
            gl_Position = vec4(position, 1.0);
        }
        """.write(to: root.appendingPathComponent("shaders/capture.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec3 v_ScreenCoord;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_ScreenCoord.xy / v_ScreenCoord.z * 0.5 + 0.5); }
        """.write(to: root.appendingPathComponent("shaders/capture.frag"), atomically: true, encoding: .utf8)
        for ext in ["vert", "frag"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.\(ext)"), to: root.appendingPathComponent("shaders/genericimage3.\(ext)"))
        }
        let frames = try renderFrames(root: root, deltaTimes: [0, 1 / 60])
        for pixels in frames {
            for x in [8, 48] {
                let covered = laterLayer && x == 8
                #expect(Array(pixels[(8 * 64 + x) * 4..<(8 * 64 + x) * 4 + 3]) == (covered ? [0, 255, 0] : [255, 0, 0]))
                #expect(Array(pixels[(24 * 64 + x) * 4..<(24 * 64 + x) * 4 + 3]) == (covered ? [0, 255, 0] : [0, 0, 255]))
                #expect(Array(pixels[(48 * 64 + x) * 4..<(48 * 64 + x) * 4 + 3]) == [0, 0, 0])
            }
        }
    }

    @Test(arguments: [0, 2], ["texture", "user", "system", "shortcut"])
    func imageMaterialInstancesKeepTheirTexturesCombosAndAnimatedConstants(effectCount: Int, binding: String) throws {
        let root = try makeFixture(effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ path: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        let provider = try #require(CGDataProvider(data: Data([0, 255, 0, 255]) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent("green.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        try json("project.json", ["type": "scene", "file": "scene.json", "general": ["properties": [
            "selected": ["type": "scenetexture", "value": "green.png"]
        ]]])
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/instance.vert"))
        try """
        uniform sampler2D g_Texture1;
        uniform float g_Tint; // {"material":"tint","default":1}
        varying vec2 v_TexCoord;
        void main() {
        #if INSTANCE
            vec4 color = texSample2D(g_Texture1, v_TexCoord);
            gl_FragColor = vec4(color.rgb * g_Tint, color.a);
        #else
            gl_FragColor = vec4(1, 0, 0, 1);
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/instance.frag"), atomically: true, encoding: .utf8)
        try json("material.json", ["passes": [["shader": "instance", "blending": "translucent",
            "combos": ["INSTANCE": 0], "textures": ["colors.png", "colors.png"], "constantshadervalues": ["tint": 1]]]])
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scene.json"))) as? [String: Any])
        var first = try #require((raw["objects"] as? [[String: Any]])?.first)
        var instance: [String: Any] = ["id": 100, "combos": ["INSTANCE": 1],
            "constantshadervalues": ["tint": ["value": 0.25, "script": "export function update() { return 0.25 + engine.runtime * 0.5; }"]]]
        if binding == "texture" { instance["textures"] = [NSNull(), "green.png"] }
        else { instance["usertextures"] = [NSNull(), ["name": binding == "system" ? "$mediaThumbnail" : "selected", "type": binding == "shortcut" ? "usershortcut" : binding]] }
        first["instance"] = instance
        raw["objects"] = [first, ["id": 2, "image": "model.json", "origin": "48 48 0"]]
        try json("scene.json", raw)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let support = NativeSceneRenderer.support(scene: scene)
        #expect(support.placeholderSubsystems.contains("system-textures") == (binding == "system"))
        #expect(support.placeholderSubsystems.contains("shortcut-icons") == (binding == "shortcut"))
        for (index, pixels) in try renderFrames(root: root, deltaTimes: [0, 1]).enumerated() {
            let actual = Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3])
            let level = index == 0 ? 64 : 191
            let expected = binding == "system" || binding == "shortcut" ? [level, 0, 0] : [0, level, 0]
            for (value, target) in zip(actual, expected) { #expect(abs(Int(value) - target) <= 1) }
            #expect(Array(pixels[(8 * 64 + 48) * 4..<(8 * 64 + 48) * 4 + 3]) == [255, 0, 0], "The sibling retains the base material")
        }
    }

    @Test(arguments: [0, 2], [0, 1])
    func userTexturePropertiesReplaceDefaultsAndUpdateLive(effectCount: Int, textureSlot: Int) throws {
        let root = try makeFixture(effectCount: effectCount)
        let preset = FileManager.default.temporaryDirectory.appendingPathComponent("WESelectedTexture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: preset, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: preset)
        }
        let selected = preset.appendingPathComponent("selected.png")
        let provider = try #require(CGDataProvider(data: Data([0, 255, 0, 255]) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(selected as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": [
            "background": ["type": "scenetexture", "value": selected.path]
        ]]]).write(to: root.appendingPathComponent("project.json"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/selected.vert"))
        try """
        uniform sampler2D g_Texture\(textureSlot);
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture\(textureSlot), v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/selected.frag"), atomically: true, encoding: .utf8)
        let userTextures = Array(repeating: "", count: textureSlot) + ["background"]
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "selected", "blending": "normal",
             "textures": Array(repeating: "colors.png", count: textureSlot + 1), "usertextures": userTextures]]])
            .write(to: root.appendingPathComponent("material.json"))
        let frames = try renderFrames(root: root, deltaTimes: [0, 0, 0], propertyOverrides: [
            [:], ["background": .string("")], ["background": .string(selected.path)]
        ])
        for (index, pixels) in frames.enumerated() {
            let expectedTop: [UInt8] = index == 1 ? [255, 0, 0] : [0, 255, 0]
            let expectedBottom: [UInt8] = index == 1 ? [0, 0, 255] : [0, 255, 0]
            #expect(Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3]) == expectedTop)
            #expect(Array(pixels[(24 * 64 + 8) * 4..<(24 * 64 + 8) * 4 + 3]) == expectedBottom)
        }
    }

    @Test(arguments: [2, 3], [3, 4])
    func widerFragmentVaryingsPreserveProducedComponents(vertexWidth: Int, fragmentWidth: Int) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = vertexWidth == 2 ? "a_TexCoord" : "vec3(a_TexCoord, 0.25)"
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec\(vertexWidth) v_TexCoord;
        void main() {
            v_TexCoord = \(value);
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        let extra = "v.z - \(vertexWidth == 3 ? "0.25" : "0.0")" + (fragmentWidth == 4 ? " + v.w" : "")
        try """
        uniform sampler2D g_Texture0;
        varying vec\(fragmentWidth) v_TexCoord;
        vec4 sampleColor(vec\(fragmentWidth) v) {
            return texSample2D(g_Texture0, v.xy) + vec4(0.0, abs(\(extra)), 0.0, 0.0);
        }
        void main() { gl_FragColor = sampleColor(v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        #expect(Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3]) == [255, 0, 0])
        #expect(Array(pixels[(24 * 64 + 8) * 4..<(24 * 64 + 8) * 4 + 3]) == [0, 0, 255])
    }

    @Test func absolutePresetTexturePathsLoadOutsideTheDependencyRoot() throws {
        let root = try makeFixture(effectCount: 0)
        let preset = FileManager.default.temporaryDirectory.appendingPathComponent("WEPresetTexture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: preset, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: preset)
        }
        let textureURL = preset.appendingPathComponent("photo ü.png")
        try FileManager.default.moveItem(at: root.appendingPathComponent("colors.png"), to: textureURL)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "textures": [textureURL.path], "blending": "normal"]]])
            .write(to: root.appendingPathComponent("material.json"))
        let pixels = try renderPixels(root: root)
        #expect(Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3]) == [255, 0, 0])
        #expect(Array(pixels[(24 * 64 + 8) * 4..<(24 * 64 + 8) * 4 + 3]) == [0, 0, 255])
    }

    // An asymmetric image catches vertical inversion that black-frame and
    // motion checks cannot detect. An identity effect must preserve it.
    @Test(arguments: [0, 1, 2], [false, true])
    func imagePlacementAndOrientation(effectCount: Int, fullscreen: Bool) throws {
        let root = try makeFixture(effectCount: effectCount, fullscreen: fullscreen)
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try renderPixels(root: root)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(pixels[((y * 64 + x) * 4)..<((y * 64 + x) * 4 + 3)])
        }
        // WE scene origins are measured from the lower-left; Metal texture
        // rows run from the top. This 32x32 layer belongs in the upper-left.
        #expect(pixel(8, 8) == [255, 0, 0], "top of image, effects: \(effectCount)")
        if fullscreen {
            #expect(pixel(8, 48) == [0, 0, 255], "bottom of fullscreen image")
            #expect(pixel(48, 8) == [255, 0, 0], "fullscreen image fills width")
        } else {
            #expect(pixel(8, 24) == [0, 0, 255], "bottom of image, effects: \(effectCount)")
            #expect(pixel(8, 48) == [0, 0, 0], "space below image")
            #expect(pixel(48, 8) == [0, 0, 0], "space beside image")
        }
    }

    @Test(arguments: ["center", "left", "right", "top", "bottom", "top left", "top right", "bottom left", "bottom right"], [0, 2])
    func imageAlignmentAnchorsTheAuthoredEdge(alignment: String, effectCount: Int) throws {
        let root = try makeFixture(effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var nodes = try #require(scene["objects"] as? [[String: Any]])
        nodes[0]["alignment"] = alignment
        nodes[0]["origin"] = "32 32 0"
        scene["objects"] = nodes
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        let pixels = try renderPixels(root: root)
        let corners = ["center": [16, 16], "left": [32, 16], "right": [0, 16], "top": [16, 32],
                       "bottom": [16, 0], "top left": [32, 32], "top right": [0, 32],
                       "bottom left": [32, 0], "bottom right": [0, 0]]
        let corner = try #require(corners[alignment])
        for y in stride(from: 8, to: 64, by: 16) {
            for x in stride(from: 8, to: 64, by: 16) {
                let inside = (corner[0]..<corner[0] + 32).contains(x) && (corner[1]..<corner[1] + 32).contains(y)
                let expected: [UInt8] = inside ? (y < corner[1] + 16 ? [255, 0, 0] : [0, 0, 255]) : [0, 0, 0]
                let offset = (y * 64 + x) * 4
                #expect(Array(pixels[offset..<offset + 3]) == expected, "\(alignment) at (\(x), \(y)), effects \(effectCount)")
            }
        }
    }

    @Test func imageAlignmentScalesAndRotatesAroundItsAnchor() throws {
        let root = try makeFixture(effectCount: 2, angle: .pi / 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var nodes = try #require(scene["objects"] as? [[String: Any]])
        nodes[0]["alignment"] = "left"
        nodes[0]["origin"] = "32 32 0"
        nodes[0]["scale"] = "0.5 0.5 1"
        scene["objects"] = nodes
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        let pixels = try renderPixels(root: root)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * 64 + x) * 4
            return Array(pixels[offset..<offset + 3])
        }
        #expect(pixel(28, 24) == [255, 0, 0])
        #expect(pixel(36, 24) == [0, 0, 255])
        #expect(pixel(32, 40) == [0, 0, 0])
    }

    @Test func sharedModelGeometryKeepsEachLayersAlignment() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        v -16 16 0
        v -16 -16 0
        v 16 16 0
        v 16 -16 0
        vt 0 0
        vt 0 1
        vt 1 0
        vt 1 1
        f 1/1 2/2 3/3
        f 3/3 2/2 4/4
        """.write(to: root.appendingPathComponent("model.obj"), atomically: true, encoding: .utf8)
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var first = try #require((scene["objects"] as? [[String: Any]])?.first)
        first["alignment"] = "left"
        first["origin"] = "32 48 0"
        var second = first
        second["id"] = 2
        second["alignment"] = "right"
        second["origin"] = "32 16 0"
        scene["objects"] = [first, second]
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        for pixels in try renderFrames(root: root, deltaTimes: [0, 1 / 60]) {
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = (y * 64 + x) * 4
                return Array(pixels[offset..<offset + 3])
            }
            #expect(pixel(48, 8) == [255, 0, 0])
            #expect(pixel(8, 8) == [0, 0, 0])
            #expect(pixel(8, 40) == [255, 0, 0])
            #expect(pixel(48, 40) == [0, 0, 0])
        }
    }

    @Test func effectTextureIndicesAreIndependentOfMetalBindingIndices() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        // The primary pass outputs green; the effect intentionally reads the
        // red/blue authored texture at WE slot 1, reflected as Metal slot 0.
        try "void main() { gl_FragColor = vec4(0, 1, 0, 1); }"
            .write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/secondary.vert"))
        try """
        uniform sampler2D g_Texture1;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture1, v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/secondary.frag"), atomically: true, encoding: .utf8)
        let material: [String: Any] = ["passes": [["shader": "secondary", "textures": [NSNull(), "colors.png"], "blending": "normal"]]]
        try JSONSerialization.data(withJSONObject: material).write(to: root.appendingPathComponent("effect-material.json"))
        let pixels = try renderPixels(root: root)
        let offset = (8 * 64 + 8) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [255, 0, 0])
    }

    @Test func textureDimensionsRemainAvailableWithoutASampledTexture() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/dimensions.vert"))
        try """
        uniform vec4 g_Texture0Resolution;
        void main() { gl_FragColor = vec4(g_Texture0Resolution.xy / 64.0, 0, 1); }
        """.write(to: root.appendingPathComponent("shaders/dimensions.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "dimensions", "blending": "normal"]]])
            .write(to: root.appendingPathComponent("effect-material.json"))
        let pixels = try renderPixels(root: root)
        let offset = (8 * 64 + 8) * 4
        // The effect input is 32x32; the scene itself is 64x64. Avoid
        // saturation so a mistaken viewport-size binding also fails.
        #expect(Array(pixels[offset..<offset + 3]) == [128, 128, 0])
    }

    @Test func authoredAnglesUseRadians() throws {
        let root = try makeFixture(effectCount: 0, angle: .pi / 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let frame = SceneRuntime(scene: scene).step(deltaTime: 0)
        let transform = try #require(frame.nodes.first).worldTransform.simdValue
        let rotated = transform * SIMD4<Float>(1, 0, 0, 0)
        #expect(abs(rotated.x) < 0.0001)
        #expect(abs(rotated.y - 1) < 0.0001)
    }

    @Test(arguments: ["sprite", "rope"], [0.5, 2.0])
    func cameraZoomMovesAndScalesParticles(renderer: String, zoom: Double) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        raw["camera"] = ["eye": "23 -9 0", "center": "23 -9 -1", "up": "0 1 0"]
        var general = try #require(raw["general"] as? [String: Any])
        general["zoom"] = zoom; raw["general"] = general
        let emitters: [[String: Any]] = renderer == "rope"
            ? [-16, 16].map { ["name": "boxrandom", "instantaneous": 1, "rate": 0, "origin": "\($0) 0 0"] }
            : [["name": "boxrandom", "instantaneous": 1, "rate": 0]]
        raw["objects"] = [["id": 1, "origin": "24 40 0", "particle": [
            "maxcount": 2, "material": "material.json",
            "emitter": emitters,
            "initializer": [["name": "sizerandom", "min": 64, "max": 64], ["name": "lifetimerandom", "min": 10, "max": 10]],
            "renderer": [["name": renderer]]
        ]]]
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        let pixels = try renderPixels(root: root, deltaTime: 1 / 30)
        let visible = (0..<4096).filter { pixels[$0 * 4] > 100 || pixels[$0 * 4 + 2] > 100 }
        let xs = visible.map { $0 % 64 }, ys = visible.map { $0 / 64 }
        #expect(xs.min() == (zoom < 1 ? 20 : 0)); #expect(ys.min() == (zoom < 1 ? 20 : 0))
        #expect(xs.max() == (zoom < 1 ? 35 : 47)); #expect(ys.max() == (zoom < 1 ? 35 : 47))
    }

    @Test func particleAtZeroDepthUsesTheSameImageOrientation() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        scene["objects"] = [["id": 1, "origin": "16 48 0", "particle": [
            "maxcount": 1, "material": "material.json",
            "emitter": [["id": 1, "name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 32, "max": 32], ["name": "lifetimerandom", "min": 10, "max": 10]],
            "renderer": [["name": "sprite"]]
        ]]]
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let pixels = try renderPixels(root: root, deltaTime: 1 / 30)
        let top = (12 * 64 + 16) * 4
        let bottom = (20 * 64 + 16) * 4
        #expect(Array(pixels[top..<top + 3]) == [255, 0, 0])
        #expect(Array(pixels[bottom..<bottom + 3]) == [0, 0, 255])
    }

    @Test func timelineMovesAnImageToItsAuthoredEndPosition() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["origin"] = ["value": "16 48 0", "animation": [
            "relative": true,
            "options": ["fps": 10, "length": 20, "mode": "single"],
            "c0": [["frame": 0, "value": 0], ["frame": 20, "value": 32]],
            "c1": [["frame": 0, "value": 0], ["frame": 20, "value": -32]]
        ]]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let pixels = try renderPixels(root: root, deltaTime: 2)
        let original = (8 * 64 + 8) * 4
        let movedTop = (40 * 64 + 40) * 4
        let movedBottom = (56 * 64 + 40) * 4
        #expect(Array(pixels[original..<original + 3]) == [0, 0, 0])
        #expect(Array(pixels[movedTop..<movedTop + 3]) == [255, 0, 0])
        #expect(Array(pixels[movedBottom..<movedBottom + 3]) == [0, 0, 255])
    }

    @Test func particlesUseTheirAuthoredShaderConstantsAndVertexColors() throws {
        let root = try makeParticleMaterialFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform float g_Tint; // {"material":"tint","default":1}
        varying vec4 v_Color;
        void main() { gl_FragColor = vec4(v_Color.rgb * g_Tint, v_Color.a); }
        """.write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        let animation: [String: Any] = ["value": 0, "animation": [
            "options": ["fps": 10, "length": 10, "mode": "single"],
            "c0": [["frame": 0, "value": 0.5], ["frame": 10, "value": 1]]
        ]]
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "particle", "blending": "normal",
            "constantshadervalues": ["tint": animation]]]])
            .write(to: root.appendingPathComponent("particle-material.json"))
        let frames = try renderFrames(root: root, deltaTimes: [0.01, 0.99])
        let offset = (12 * 64 + 16) * 4
        #expect(abs(Int(frames[0][offset]) - 64) <= 2)
        #expect(abs(Int(frames[0][offset + 1]) - 128) <= 2)
        #expect(abs(Int(frames[0][offset + 2]) - 32) <= 2)
        #expect(Array(frames[1][offset..<offset + 3]) == [128, 255, 64])
    }

    @Test func particleSamplerAnnotationsResolveTheSceneBeforeTheParticleDraw() throws {
        let root = try makeParticleMaterialFixture(underlay: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
        varying vec2 v_ScreenUV;
        void main() { gl_FragColor = vec4(1.0 - texSample2D(g_Texture3, v_ScreenUV).rgb, 1); }
        """.write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root, deltaTime: 0.01)
        let top = (12 * 64 + 16) * 4
        let bottom = (20 * 64 + 16) * 4
        #expect(Array(pixels[top..<top + 3]) == [0, 255, 255])
        #expect(Array(pixels[bottom..<bottom + 3]) == [255, 255, 0])
    }

    @Test(arguments: ["first-pass", "second-pass", "child"])
    func particleSceneReadsPreserveTheInputAcrossAllPassesAndChildren(reader: String) throws {
        let root = try makeParticleMaterialFixture(underlay: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ path: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/particle.vert"),
                                        to: root.appendingPathComponent("shaders/scene-read.vert"))
        try "void main() { gl_FragColor = vec4(0, 1, 0, 1); }"
            .write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
        varying vec2 v_ScreenUV;
        void main() { gl_FragColor = vec4(1.0 - texSample2D(g_Texture3, v_ScreenUV).rgb, 1); }
        """.write(to: root.appendingPathComponent("shaders/scene-read.frag"), atomically: true, encoding: .utf8)
        let readPass = ["shader": "scene-read", "blending": "normal"]
        let greenPass = ["shader": "particle", "blending": "normal"]
        try json("particle-material.json", ["passes": reader == "first-pass" ? [readPass] : reader == "second-pass" ? [greenPass, readPass] : [greenPass]])
        if reader == "child" {
            let scenePath = root.appendingPathComponent("scene.json")
            var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: scenePath)) as? [String: Any])
            var nodes = try #require(scene["objects"] as? [[String: Any]])
            var particle = try #require(nodes[1]["particle"] as? [String: Any])
            var child = particle
            child["material"] = "child-material.json"
            try json("child.json", child)
            try json("child-material.json", ["passes": [readPass]])
            particle["children"] = [["name": "child.json", "type": "static"]]
            nodes[1]["particle"] = particle
            scene["objects"] = nodes
            try json("scene.json", scene)
        }
        for pixels in try renderFrames(root: root, deltaTimes: [0.01, 0.01]) {
            let top = (12 * 64 + 16) * 4
            let bottom = (20 * 64 + 16) * 4
            #expect(Array(pixels[top..<top + 3]) == [0, 255, 255])
            #expect(Array(pixels[bottom..<bottom + 3]) == [255, 255, 0])
            #expect(Array(pixels[0..<3]) == [255, 0, 0], "pixels outside the particle retain their background")
        }
    }

    @Test func particleRefractionHelpersUseTopFirstRenderTargetCoordinates() throws {
        let root = try makeParticleMaterialFixture(underlay: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("shaders/particle.vert")
        let vertex = try String(contentsOf: path, encoding: .utf8)
            .replacingOccurrences(of: "v_ScreenUV = vec2(gl_Position.x * 0.5 + 0.5, 0.5 - gl_Position.y * 0.5);", with: """
            vec3 v_ScreenCoord = gl_Position.xyw;
            #ifdef HLSL
                v_ScreenCoord.y = -v_ScreenCoord.y;
            #endif
            v_ScreenUV = v_ScreenCoord.xy / v_ScreenCoord.z * 0.5 + 0.5;
            """)
        try vertex.write(to: path, atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
        varying vec2 v_ScreenUV;
        void main() {
            vec2 screenRefractionOffset = vec2(0, 0.125);
        #ifndef HLSL
            screenRefractionOffset.y = -screenRefractionOffset.y;
        #endif
            gl_FragColor = texSample2D(g_Texture3, v_ScreenUV + screenRefractionOffset);
        }
        """.write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root, deltaTime: 0.01)
        let offset = (12 * 64 + 16) * 4
        // A downward 8px displacement samples the lower, blue half of the
        // layer at y=20. A flipped scene coordinate samples empty space;
        // flipping only the offset samples the red upper half.
        #expect(Array(pixels[offset..<offset + 3]) == [0, 0, 255])
    }

    @Test func particlesDrawEveryMaterialPassInAuthoredOrder() throws {
        let root = try makeParticleMaterialFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform vec3 g_Tint; // {"material":"tint","default":"0 0 0"}
        void main() { gl_FragColor = vec4(g_Tint, 1); }
        """.write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [
            ["shader": "particle", "blending": "normal", "constantshadervalues": ["tint": "0.25 0 0"]],
            ["shader": "particle", "blending": "additive", "constantshadervalues": ["tint": "0 0 0.5"]]
        ]]).write(to: root.appendingPathComponent("particle-material.json"))
        let pixels = try renderPixels(root: root, deltaTime: 0.01)
        let offset = (12 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [64, 0, 128])
    }

    @Test func billboardShadersCanUseMoreThanThreeVertexAttributes() throws {
        let root = try makeParticleMaterialFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("shaders/particle.vert")
        let source = try String(contentsOf: path, encoding: .utf8)
            .replacingOccurrences(of: "attribute vec4 a_Color;", with: """
            attribute vec4 a_Color;
            attribute vec2 a_TexCoordC2;
            attribute vec4 a_TexCoordVec4C1;
            """)
            .replacingOccurrences(of: "v_Color = a_Color;", with:
                "v_Color = a_Color + vec4(a_TexCoordC2, a_TexCoordVec4C1.xy) * 0.01;")
        try source.write(to: path, atomically: true, encoding: .utf8)
        try "varying vec4 v_Color; void main() { gl_FragColor = v_Color; }"
            .write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root, deltaTime: 0.01)
        let offset = (12 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [128, 255, 64])
    }

    @Test func billboardAttributesPreserveCornersRotationVelocityAndOpacity() throws {
        let root = try makeParticleMaterialFixture(opacity: 0.5)
        defer { try? FileManager.default.removeItem(at: root) }
        let scenePath = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: scenePath)) as? [String: Any])
        var nodes = try #require(scene["objects"] as? [[String: Any]])
        var particle = try #require(nodes[0]["particle"] as? [String: Any])
        var initializers = try #require(particle["initializer"] as? [[String: Any]])
        initializers += [
            ["name": "rotationrandom", "min": "0.2 0.4 0.6", "max": "0.2 0.4 0.6"],
            ["name": "velocityrandom", "min": "4 5 6", "max": "4 5 6"]
        ]
        particle["initializer"] = initializers
        nodes[0]["particle"] = particle
        scene["objects"] = nodes
        try JSONSerialization.data(withJSONObject: scene).write(to: scenePath)
        let vertexPath = root.appendingPathComponent("shaders/particle.vert")
        let vertex = try String(contentsOf: vertexPath, encoding: .utf8)
            .replacingOccurrences(of: "attribute vec4 a_Color;", with: """
            attribute vec4 a_Color;
            attribute vec2 a_TexCoord;
            attribute vec2 a_TexCoordC2;
            attribute vec4 a_TexCoordVec4C1;
            """)
            .replacingOccurrences(of: "v_Color = a_Color;", with: """
            bool correct = all(lessThan(abs(a_TexCoord - a_TexCoordVec4.xy), vec2(0.0001)))
                && all(lessThan(abs(a_TexCoordC2 - vec2(0.2, 0.4)), vec2(0.0001)))
                && abs(a_TexCoordVec4.z - 0.6) < 0.0001
                && abs(a_TexCoordVec4.w - 16.0) < 0.0001
                && all(lessThan(abs(a_TexCoordVec4C1.xyz - vec3(4, 5, 6)), vec3(0.0001)))
                && abs(a_TexCoordVec4C1.w - 0.001) < 0.0001
                && all(lessThan(abs(a_Color - vec4(0.5, 1, 0.25, 0.5)), vec4(0.0001)));
            v_Color = correct ? vec4(0, 1, 0, 1) : vec4(1, 0, 0, 1);
            """)
        try vertex.write(to: vertexPath, atomically: true, encoding: .utf8)
        try "varying vec4 v_Color; void main() { gl_FragColor = v_Color; }"
            .write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root, deltaTime: 0.01)
        // Check both triangles away from their shared edge. A swapped or missing
        // attribute must reach the shader as an error, rather than only testing
        // zero-valued rotation/velocity as the simpler billboard fixture does.
        for (x, y) in [(12, 12), (20, 12), (12, 20), (20, 20)] {
            let offset = (y * 64 + x) * 4
            #expect(Array(pixels[offset..<offset + 3]) == [0, 255, 0])
        }
    }

    @Test func particleOpacityIsAppliedOnceAndInheritedByChildren() throws {
        let root = try makeParticleMaterialFixture(opacity: 0.5)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var nodes = try #require(scene["objects"] as? [[String: Any]])
        var particle = try #require(nodes[0]["particle"] as? [String: Any])
        try JSONSerialization.data(withJSONObject: particle).write(to: root.appendingPathComponent("child.json"))
        particle["children"] = [["name": "child.json", "type": "static", "origin": "32 0 0"]]
        nodes[0]["particle"] = particle
        scene["objects"] = nodes
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        try "varying vec4 v_Color; void main() { gl_FragColor = v_Color; }"
            .write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "particle", "blending": "translucent"]]])
            .write(to: root.appendingPathComponent("particle-material.json"))
        let pixels = try renderPixels(root: root, deltaTime: 0.01)
        for x in [16, 48] {
            let offset = (12 * 64 + x) * 4
            #expect(Array(pixels[offset..<offset + 3]) == [64, 128, 32])
        }
    }

    private func makeParticleMaterialFixture(underlay: Bool = false, opacity: Double = 1) throws -> URL {
        let root = try makeFixture(effectCount: 0)
        let scenePath = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: scenePath)) as? [String: Any])
        let particle: [String: Any] = ["id": 2, "origin": "16 48 0", "instanceoverride": ["alpha": opacity], "particle": [
            "maxcount": 1, "material": "particle-material.json",
            "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 32, "max": 32],
                            ["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "colorrandom", "min": "0.5 1 0.25", "max": "0.5 1 0.25"]],
            "renderer": [["name": "sprite"]]
        ]]
        scene["objects"] = (underlay ? (scene["objects"] as? [[String: Any]] ?? []) : []) + [particle]
        try JSONSerialization.data(withJSONObject: scene).write(to: scenePath)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "particle", "blending": "normal"]]])
            .write(to: root.appendingPathComponent("particle-material.json"))
        try """
        attribute vec3 a_Position;
        attribute vec4 a_TexCoordVec4;
        attribute vec4 a_Color;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_Color;
        varying vec2 v_ScreenUV;
        void main() {
            vec3 p = a_Position + vec3((a_TexCoordVec4.x - 0.5) * a_TexCoordVec4.w,
                                      (0.5 - a_TexCoordVec4.y) * a_TexCoordVec4.w, 0);
            gl_Position = g_ModelViewProjectionMatrix * vec4(p, 1);
            v_ScreenUV = vec2(gl_Position.x * 0.5 + 0.5, 0.5 - gl_Position.y * 0.5);
            v_Color = a_Color;
        }
        """.write(to: root.appendingPathComponent("shaders/particle.vert"), atomically: true, encoding: .utf8)
        return root
    }

    private func renderPixels(root: URL, deltaTime: Double = 0) throws -> [UInt8] {
        try #require(renderFrames(root: root, deltaTimes: [deltaTime]).first)
    }

    @Test func sharedEffectPipelinesKeepEachLayersAnimatedConstants() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/tint.vert"))
        try """
        uniform float g_Tint; // {"material":"tint","default":0}
        void main() { gl_FragColor = vec4(g_Tint, 0, 1 - g_Tint, 1); }
        """.write(to: root.appendingPathComponent("shaders/tint.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "tint", "blending": "normal"]]])
            .write(to: root.appendingPathComponent("effect-material.json"))
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let animation: [String: Any] = ["value": 0, "animation": [
            "options": ["fps": 10, "length": 20, "mode": "single"],
            "c0": [["frame": 0, "value": 0], ["frame": 20, "value": 1]]
        ]]
        scene["objects"] = [
            ["id": 1, "image": "model.json", "origin": "16 48 0",
             "effects": [["id": 1, "file": "effect.json", "passes": [["constantshadervalues": ["tint": animation]]]]]],
            ["id": 2, "image": "model.json", "origin": "48 48 0",
             "effects": [["id": 2, "file": "effect.json", "passes": [["constantshadervalues": ["tint": 0.5]]]]]]
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let frames = try renderFrames(root: root, deltaTimes: [0, 2])
        func pixel(_ frame: Int, _ x: Int) -> [UInt8] {
            let offset = (8 * 64 + x) * 4
            return Array(frames[frame][offset..<offset + 3])
        }
        #expect(pixel(0, 8) == [0, 0, 255])
        #expect(pixel(1, 8) == [255, 0, 0])
        #expect(pixel(0, 40) == [128, 0, 128])
        #expect(pixel(1, 40) == [128, 0, 128])
    }

    @Test(arguments: [false, true])
    func layerColorAndOpacityReachSolidAndCombinedUniforms(combined: Bool) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "blending": "translucent"]]])
            .write(to: root.appendingPathComponent("material.json"))
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["alpha"] = 0.5
        objects[0]["color"] = ["value": "1 1 1", "animation": [
            "options": ["fps": 10, "length": 10, "mode": "single"],
            "c0": [["frame": 0, "value": 1], ["frame": 10, "value": 0]],
            "c1": [["frame": 0, "value": 0], ["frame": 10, "value": 1]],
            "c2": [["frame": 0, "value": 0], ["frame": 10, "value": 0]]
        ]]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let fragment = combined ? """
        uniform vec4 g_Color4;
        void main() { gl_FragColor = g_Color4; }
        """ : """
        uniform float g_Alpha;
        uniform vec3 g_Color;
        void main() { gl_FragColor = vec4(g_Color, g_Alpha); }
        """
        try fragment.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let frames = try renderFrames(root: root, deltaTimes: [0, 1])
        let offset = (8 * 64 + 8) * 4
        #expect(Array(frames[0][offset..<offset + 3]) == [128, 0, 0])
        #expect(Array(frames[1][offset..<offset + 3]) == [0, 128, 0])
    }

    @Test func effectColorAndAlphaOverrideLayerUniformDefaults() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "blending": "translucent"]]])
            .write(to: root.appendingPathComponent("material.json"))
        try """
        uniform float g_Alpha; // {"material":"alpha","default":0.25}
        uniform vec3 g_Color; // {"material":"color","default":"0 1 0"}
        void main() { gl_FragColor = vec4(g_Color, g_Alpha); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let offset = (8 * 64 + 8) * 4
        let defaults = try renderPixels(root: root)
        #expect(Array(defaults[offset..<offset + 3]) == [0, 64, 0])
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "blending": "translucent",
            "constantshadervalues": ["alpha": 0.5, "color": "0 0 1"]]]])
            .write(to: root.appendingPathComponent("material.json"))
        let authored = try renderPixels(root: root)
        #expect(Array(authored[offset..<offset + 3]) == [0, 0, 128])
    }

    @Test func boundMaskTextureEnablesItsShaderVariant() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/masked.vert"))
        try """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1; // {"combo":"MASK"}
        varying vec2 v_TexCoord;
        void main() {
            vec4 color = texSample2D(g_Texture0, v_TexCoord);
        #if MASK
            color.rgb *= texSample2D(g_Texture1, v_TexCoord).r;
        #else
            color = vec4(0, 1, 0, 1);
        #endif
            gl_FragColor = color;
        }
        """.write(to: root.appendingPathComponent("shaders/masked.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "masked", "blending": "normal",
            "textures": [NSNull(), "colors.png"]]]]).write(to: root.appendingPathComponent("effect-material.json"))
        let pixels = try renderPixels(root: root)
        let top = (8 * 64 + 8) * 4, bottom = (24 * 64 + 8) * 4
        #expect(Array(pixels[top..<top + 3]) == [255, 0, 0])
        #expect(Array(pixels[bottom..<bottom + 3]) == [0, 0, 0])
    }

    @Test func particleAtlasUsesIndividualFramesAndLuminanceAlphaFormat() throws {
        let root = try makeParticleMaterialFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeAtlasTestTexture().write(to: root.appendingPathComponent("atlas.tex"))
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "particle", "blending": "normal",
            "textures": ["atlas.tex"]]]]).write(to: root.appendingPathComponent("particle-material.json"))
        let path = root.appendingPathComponent("shaders/particle.vert")
        var vertex = try String(contentsOf: path, encoding: .utf8)
        vertex = vertex.replacingOccurrences(of: "attribute vec4 a_Color;", with: """
        attribute vec4 a_Color;
        attribute vec4 a_TexCoordVec4C1;
        uniform vec4 g_RenderVar1;
        varying vec2 v_TexCoord;
        """)
        vertex = vertex.replacingOccurrences(of: "v_Color = a_Color;", with: """
        v_Color = a_Color;
        v_TexCoord = a_TexCoordVec4.xy;
        #if SPRITESHEET
        float frame = floor(frac(a_TexCoordVec4C1.w) * g_RenderVar1.z);
        v_TexCoord = (v_TexCoord + vec2(frame, 0)) * g_RenderVar1.xy;
        #endif
        """)
        try vertex.write(to: path, atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            vec4 color = texSample2D(g_Texture0, v_TexCoord);
        #if TEX0FORMAT == 8
            color = color.rrrg;
        #endif
            gl_FragColor = color;
        }
        """.write(to: root.appendingPathComponent("shaders/particle.frag"), atomically: true, encoding: .utf8)
        // The atlas import duration is 1s, but this particle lives 10s.
        // Frame selection must follow lifetime, not the import duration.
        let frames = try renderFrames(root: root, deltaTimes: [1, 5])
        let offset = (16 * 64 + 16) * 4
        #expect(Array(frames[0][offset..<offset + 3]) == [64, 64, 64])
        #expect(Array(frames[1][offset..<offset + 3]) == [192, 192, 192])
    }

    @Test(arguments: [0.0, 0.5, -0.5])
    func numericShaderConditionsTreatOnlyZeroAsFalse(value: Double) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform float g_Enabled; // {"material":"enabled","default":\(value)}
        void main() {
            vec3 color = g_Enabled ? vec3(0, 1, 0) : vec3(1, 0, 0);
            if (g_Enabled) color.b = 1;
            gl_FragColor = vec4(color, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (8 * 64 + 8) * 4
        #expect(Array(pixels[offset..<offset + 3]) == (value == 0 ? [255, 0, 0] : [0, 255, 255]))
    }

    @Test func layerTransformRemainsAvailableInsideAnOffscreenEffectChain() throws {
        let root = try makeFixture(effectCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["scale"] = "0.5 0.25 1"
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/layer.vert"))
        try """
        uniform mat4 g_LayerModelMatrix;
        void main() {
            gl_FragColor = vec4(length(g_LayerModelMatrix[0].xyz), length(g_LayerModelMatrix[1].xyz), 0, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/layer.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "layer", "blending": "normal"]]])
            .write(to: root.appendingPathComponent("effect-material.json"))
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [128, 64, 0])
    }

    @Test func metalOperatorKeywordsRemainUsableAsAuthoredVariableNames() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        void main() {
            float or = 0.25;
            float and = 0.5;
            float xor = 0.75;
            gl_FragColor = vec4(or, and, xor, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [64, 128, 191])
    }

    @Test(arguments: [2, 3])
    func fragmentVaryingsCanConsumeFewerComponentsThanTheVertexProduces(components: Int) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1);
            v_TexCoord = vec4(0.25, 0.5, 0.75, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        varying vec\(components) v_TexCoord;
        vec\(components) readCoordinates() { return v_TexCoord; }
        void main() {
            vec\(components) value = readCoordinates();
            gl_FragColor = vec4(value.xy, \(components == 2 ? "0.0" : "value.z"), 1);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [64, 128, components == 2 ? 0 : 191])
    }

    @Test func varyingComponentSuffixesDoNotCreateDuplicateDeclarations() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_Size;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); v_Size = vec4(0.25, 0.5, 0.75, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        varying vec4 v_Size.xy;
        void main() { gl_FragColor = v_Size; }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [64, 128, 191])
    }

    @Test(arguments: [2, 4])
    func fragmentInputsCanBeModifiedThroughHelperFunctions(components: Int) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_TexCoord;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); v_TexCoord = vec4(0.25, 0.5, 0.75, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        varying vec\(components) v_TexCoord;
        void moveCoordinates() { v_TexCoord.xy += vec2(0.25, -0.25); }
        void main() { moveCoordinates(); gl_FragColor = vec4(v_TexCoord.xy, 0, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [128, 64, 0])
    }

    @Test func unreducedImageEffectsReceiveAUnitTextureReductionScale() throws {
        let root = try makeFixture(effectCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform float g_TextureReductionScale;
        void main() { gl_FragColor = vec4(0.5 / g_TextureReductionScale, 0.25, 0.75, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [128, 64, 191])
    }

    @Test func localConstantsCanBeInitializedFromFragmentInputs() throws {
        let root = try makeFixture(effectCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        varying vec2 v_TexCoord;
        void main() {
            const vec4 sampleValue = vec4(v_TexCoord.x * 0.0 + 0.5, 0.25, 0.75, 1);
            gl_FragColor = sampleValue;
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [128, 64, 191])
    }

    @Test func compoundVectorArithmeticTruncatesTheExpressionBeforeMacroSubtraction() throws {
        let root = try makeFixture(effectCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let vertexURL = root.appendingPathComponent("shaders/copy.vert")
        let vertex = try String(contentsOf: vertexURL, encoding: .utf8)
            .replacingOccurrences(of: "varying vec2 v_TexCoord", with: "varying vec4 v_TexCoord")
            .replacingOccurrences(of: "v_TexCoord = a_TexCoord", with: "v_TexCoord = vec4(a_TexCoord, 0, 0)")
        try vertex.write(to: vertexURL, atomically: true, encoding: .utf8)
        try """
        varying vec4 v_TexCoord;
        uniform vec2 u_center; // {"default":"0.25 0.5"}
        #define center (u_center * 2.0 - 1.0)
        void main() {
            vec2 shifted = ((v_TexCoord * 2.0 - 1.0 - center) + 1.0 + center) / 2.0;
            gl_FragColor = vec4(shifted, 0.5, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(abs(Int(pixels[offset]) - 131) <= 1)
        #expect(abs(Int(pixels[offset + 1]) - 131) <= 1)
        #expect(pixels[offset + 2] == 128)
    }

    @Test(arguments: [false, true])
    func optionalTextureCombosPreserveDefinedness(texturePresent: Bool) throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let vertexURL = root.appendingPathComponent("shaders/copy.vert")
        var vertex = try String(contentsOf: vertexURL, encoding: .utf8)
        vertex = """
        #ifdef NORMALMAP
        varying vec3 v_Normal;
        #else
        varying vec3 v_WorldNormal;
        #endif

        """ + vertex.replacingOccurrences(of: "void main() {", with: """
        void main() {
        #if NORMALMAP
            v_Normal = vec3(0, 1, 0);
        #else
            v_WorldNormal = vec3(1, 0, 0);
        #endif
        """ + "\n")
        try vertex.write(to: vertexURL, atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture1; // {"combo":"NORMALMAP"}
        #ifdef NORMALMAP
        varying vec3 v_Normal;
        #else
        varying vec3 v_WorldNormal;
        #endif
        void main() {
        #if NORMALMAP
            gl_FragColor = vec4(v_Normal, 1);
        #else
            gl_FragColor = vec4(v_WorldNormal, 1);
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        if texturePresent {
            let material: [String: Any] = ["passes": [["shader": "copy", "textures": [NSNull(), "colors.png"], "blending": "normal"]]]
            try JSONSerialization.data(withJSONObject: material).write(to: root.appendingPathComponent("effect-material.json"))
        }
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(Array(pixels[offset..<offset + 3]) == (texturePresent ? [0, 255, 0] : [255, 0, 0]))
    }

    @Test func authoredLogarithmHelpersAreNotReplacedByCompatibilityMacros() throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        float log10(float x) { return log(x) / log(10.0); }
        void main() { gl_FragColor = vec4(log10(10.0) * 0.5, 0.25, 0.75, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (16 * 64 + 16) * 4
        #expect(abs(Int(pixels[offset]) - 128) <= 1)
        #expect(Array(pixels[(offset + 1)..<(offset + 3)]) == [64, 191])
    }

    @Test(arguments: [16, 32, 64])
    func conditionalTerminatorsDoNotPreventShaderBranchSelection(samples: Int) throws {
        let root = try makeFixture(effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "combos": ["SAMPLES": samples], "blending": "normal"]]])
            .write(to: root.appendingPathComponent("effect-material.json"))
        try """
        void main() {
        #if SAMPLES == 16; // authored conditional terminator
            gl_FragColor = vec4(1, 0, 0, 1);
        #elif SAMPLES == 32;
            gl_FragColor = vec4(0, 1, 0, 1);
        #elif SAMPLES == 64; // another branch
            gl_FragColor = vec4(0, 0, 1, 1);
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (8 * 64 + 8) * 4
        #expect(Array(pixels[offset..<offset + 3]) == (samples == 16 ? [255, 0, 0] : samples == 32 ? [0, 255, 0] : [0, 0, 255]))
    }

    @Test(arguments: ["\n", "\r\n"])
    func continuedExpressionsAndIncludedMacrosCompile(newline: String) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "#define GREEN \\\(newline)vec3(0, 0.5, 0)\(newline)"
            .write(to: root.appendingPathComponent("shaders/continued.h"), atomically: true, encoding: .utf8)
        try "#include \"continued.h\"\(newline)void main() { gl_FragColor = vec4(vec3(0.25, 0, 0) + \\\(newline)GREEN, 1); }\(newline)"
            .write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let offset = (8 * 64 + 8) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [64, 128, 0])
    }

    @Test(arguments: [0, 1, 2], ["a", "b"])
    func hiddenImageDependenciesKeepPhysicalCompositeTextures(effectCount: Int, texture: String) throws {
        let root = try makeFixture(effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var source = try #require((scene["objects"] as? [[String: Any]])?.first)
        source["visible"] = false
        source["dependencies"] = [1] // An authored self reference must terminate.
        // The consumer precedes both a hidden group and its image dependency.
        scene["objects"] = [
            ["id": 2, "name": "consumer", "image": "consumer-model.json", "origin": "48 48 0", "dependencies": [3]],
            ["id": 3, "name": "dependency group", "visible": false, "dependencies": [1]],
            source,
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        try JSONSerialization.data(withJSONObject: ["material": "consumer-material.json", "width": 32, "height": 32])
            .write(to: root.appendingPathComponent("consumer-model.json"))
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "textures": ["_rt_imageLayerComposite_1_\(texture)"], "blending": "normal"]]])
            .write(to: root.appendingPathComponent("consumer-material.json"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/rotate.vert"))
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { vec4 color = texSample2D(g_Texture0, v_TexCoord); gl_FragColor = vec4(color.brg, color.a); }
        """.write(to: root.appendingPathComponent("shaders/rotate.frag"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "rotate", "blending": "normal"]]])
            .write(to: root.appendingPathComponent("effect-material.json"))
        let frames = try renderFrames(root: root, deltaTimes: [0, 1 / 60])
        for pixels in frames {
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = (y * 64 + x) * 4
                return Array(pixels[offset..<offset + 3])
            }
            #expect(pixel(8, 8) == [0, 0, 0], "hidden producer must not appear in the scene")
            #expect(pixel(8, 24) == [0, 0, 0])
            if texture == "b" && effectCount == 0 {
                #expect(pixel(48, 8) == [0, 0, 0], "unwritten B is transparent")
            } else {
                let rotations = texture == "b" ? 1 : (effectCount == 2 ? 2 : 0)
                let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255]]
                #expect(pixel(48, 8) == colors[rotations])
                #expect(pixel(48, 24) == colors[(rotations + 2) % 3])
            }
        }
    }

    @Test func directMDLModelsRemainExplicitlyPartial() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        #expect(!NativeSceneRenderer.support(scene: ordinary).placeholderSubsystems.contains("3d-models"))
        let url = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var nodes = try #require(scene["objects"] as? [[String: Any]])
        nodes[0]["image"] = "model.mdl"
        scene["objects"] = nodes
        try JSONSerialization.data(withJSONObject: scene).write(to: url)
        let model = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let support = NativeSceneRenderer.support(scene: model)
        #expect(support.isSupported, "partial scenes can still render")
        #expect(support.parityStatus == .partial)
        #expect(support.placeholderSubsystems.contains("3d-models"))
    }

    @Test(arguments: [0, 1, 2])
    func frameTimeAndInverseTransformsReachSceneAndEffectPasses(effectCount: Int) throws {
        let root = try makeFixture(effectCount: effectCount, angle: .pi / 6)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat4 g_ModelViewProjectionMatrixInverse;
        uniform mat4 g_ModelMatrix;
        uniform mat4 g_ModelMatrixInverse;
        varying float v_Error;
        void main() {
            vec4 local = vec4(a_Position, 1);
            gl_Position = g_ModelViewProjectionMatrix * local;
            v_Error = length(g_ModelViewProjectionMatrixInverse * gl_Position - local)
                + length(g_ModelMatrixInverse * g_ModelMatrix * local - local);
        }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        uniform float g_Frametime;
        varying float v_Error;
        void main() { gl_FragColor = vec4(g_Frametime, v_Error < 0.001 ? 1.0 : 0.0, 0, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let frames = try renderFrames(root: root, deltaTimes: [0.25, 0.125])
        for (index, pixels) in frames.enumerated() {
            let expected: [UInt8] = [index == 0 ? 64 : 32, 255, 0, 255]
            let offset = (16 * 64 + 16) * 4
            #expect(Array(pixels[offset..<offset + 4]) == expected)
        }
    }

    @Test(arguments: [0, 1])
    func disabledEmptyShaderHelpersDoNotRejectTheActiveEffect(mode: Int) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "textures": ["colors.png"], "combos": ["MODE": mode]]]])
            .write(to: root.appendingPathComponent("material.json"))
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        vec3 optionalMask(vec2 uv) {
        #if MODE == 1
            return vec3(0, 1, 0);
        #endif
        }
        #define USE_MASK (MODE != 0)
        void main() {
            vec4 color = texSample2D(g_Texture0, v_TexCoord);
        #if USE_MASK
            color.rgb = optionalMask(v_TexCoord);
        #endif
            gl_FragColor = color;
        }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let expected: [UInt8] = mode == 0 ? [255, 0, 0] : [0, 255, 0]
        #expect(Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3]) == expected)
    }

    @Test func activeEmptyShaderHelpersStillFailCompilation() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        vec4 optionalMask() {}
        #define ACTIVE_MASK optionalMask
        void main() { gl_FragColor = ACTIVE_MASK(); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try ShaderPipeline.compile(ShaderCompilationRequest(shaderPath: "copy", assetRoots: [root]))
        }
    }

    @Test func samplerParametersReachStockStyleHelperFunctions() throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        vec4 sampleLayer(DECLARE_SAMPLER2D_PARAMETER(layer), vec2 uv) { return texSample2D(layer, uv); }
        void main() { gl_FragColor = sampleLayer(MAKE_SAMPLER2D_ARGUMENT(g_Texture0), v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        #expect(Array(pixels[(8 * 64 + 8) * 4..<(8 * 64 + 8) * 4 + 3]) == [255, 0, 0])
        #expect(Array(pixels[(24 * 64 + 8) * 4..<(24 * 64 + 8) * 4 + 3]) == [0, 0, 255])
    }

    @Test(arguments: ["0", "0.25", "1e-1"])
    func scalarVectorInitializersBroadcast(literal: String) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "void main() { vec4 color = \(literal); gl_FragColor = color; }"
            .write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let expected = Int((Double(literal)! * 255).rounded())
        for channel in 0..<4 {
            #expect(abs(Int(pixels[(8 * 64 + 8) * 4 + channel]) - expected) <= 1)
        }
    }

    @Test(arguments: [1, 2])
    func conditionalFragmentInputDeclarationsRemainWritable(version: Int) throws {
        let root = try makeFixture(effectCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["passes": [["shader": "copy", "blending": "normal", "combos": ["VERSION": version]]]])
            .write(to: root.appendingPathComponent("material.json"))
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_Branch;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); v_Branch = vec4(0.2, 0.4, 0.8, 1); }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        #if VERSION == 1
        varying vec4 v_Branch;
        void main() { v_Branch.xy *= 0.5; gl_FragColor = v_Branch; }
        #endif
        #if VERSION == 2
        varying vec4 v_Branch;
        void main() { v_Branch.z *= 0.5; gl_FragColor = v_Branch; }
        #endif
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let pixels = try renderPixels(root: root)
        let expected = version == 1 ? [26, 51, 204, 255] : [51, 102, 102, 255]
        for channel in 0..<4 {
            #expect(abs(Int(pixels[(8 * 64 + 8) * 4 + channel]) - expected[channel]) <= 1)
        }
    }

    @Test(arguments: [0, 1, 2], [0, 2, 11, 31])
    func layerColorBlendingUsesSceneCoordinatesAndStraightAlpha(effectCount: Int, blendMode: Int) throws {
        let root = try makeFixture(effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var foreground = try #require((scene["objects"] as? [[String: Any]])?.first)
        foreground["id"] = 2
        foreground["image"] = "solid-model.json"
        foreground["color"] = "0.25 0.5 0.75"
        foreground["alpha"] = 0.5
        foreground["colorBlendMode"] = blendMode
        scene["objects"] = [["id": 1, "image": "background-model.json", "origin": "16 48 0"], foreground]
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        for name in ["background", "solid"] {
            try JSONSerialization.data(withJSONObject: ["material": "\(name)-material.json", "width": 32, "height": 32])
                .write(to: root.appendingPathComponent("\(name)-model.json"))
            try JSONSerialization.data(withJSONObject: ["passes": [["shader": name, "blending": name == "solid" ? "translucent" : "normal"]]])
                .write(to: root.appendingPathComponent("\(name)-material.json"))
            try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/\(name).vert"))
        }
        try """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(v_TexCoord.y < 0.5 ? vec3(0.25, 0.5, 0.75) : vec3(0.75, 0.25, 0.5), 1); }
        """.write(to: root.appendingPathComponent("shaders/background.frag"), atomically: true, encoding: .utf8)
        try """
        uniform vec3 g_Color;
        uniform float g_Alpha;
        void main() { gl_FragColor = vec4(g_Color, g_Alpha); }
        """.write(to: root.appendingPathComponent("shaders/solid.frag"), atomically: true, encoding: .utf8)
        // Minimal stock shader contract, so this pixel test does not depend
        // on an installed Wallpaper Engine asset directory.
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        varying vec3 v_ScreenPos;
        void main() {
            v_TexCoord = a_TexCoord;
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1);
            v_ScreenPos = gl_Position.xyw;
        #ifdef HLSL
            v_ScreenPos.y = -v_ScreenPos.y;
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/genericimage3.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
        uniform vec4 g_Color4;
        varying vec2 v_TexCoord;
        varying vec3 v_ScreenPos;
        float overlay(float a, float b) { return a < 0.5 ? 2.0*a*b : 1.0-2.0*(1.0-a)*(1.0-b); }
        void main() {
            vec4 layer = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
            vec4 scene = texSample2D(g_Texture4, v_ScreenPos.xy/v_ScreenPos.z*0.5+0.5);
        #if BLENDMODE == 2
            vec3 color = mix(scene.rgb, scene.rgb*layer.rgb, layer.a);
        #elif BLENDMODE == 11
            vec3 color = mix(scene.rgb, vec3(overlay(scene.r,layer.r), overlay(scene.g,layer.g), overlay(scene.b,layer.b)), layer.a);
        #elif BLENDMODE == 31
            vec3 color = scene.rgb + layer.rgb*layer.a;
        #else
            vec3 color = mix(scene.rgb, layer.rgb, layer.a);
        #endif
            gl_FragColor = vec4(color, scene.a);
        }
        """.write(to: root.appendingPathComponent("shaders/genericimage3.frag"), atomically: true, encoding: .utf8)
        for pixels in try renderFrames(root: root, deltaTimes: [0, 1 / 60]) {
            for (y, background) in [(8, [0.25, 0.5, 0.75]), (24, [0.75, 0.25, 0.5])] {
                for (channel, layer) in [0.25, 0.5, 0.75].enumerated() {
                    let a = background[channel]
                    let blended: Double
                    switch blendMode {
                    case 2: blended = a * layer
                    case 11: blended = a < 0.5 ? 2 * a * layer : 1 - 2 * (1 - a) * (1 - layer)
                    case 31: blended = a + layer
                    default: blended = layer
                    }
                    let expected = Int((min(1, (a + blended) * 0.5) * 255).rounded())
                    let actual = Int(pixels[(y * 64 + 8) * 4 + channel])
                    #expect(abs(actual - expected) <= 2, "mode \(blendMode), effects \(effectCount), row \(y), channel \(channel): \(actual) vs \(expected)")
                }
                #expect(pixels[(y * 64 + 8) * 4 + 3] == 255)
            }
            #expect(pixels[(48 * 64 + 8) * 4] == 0, "blend pass must retain layer geometry")
        }
    }

    private func renderFrames(root: URL, deltaTimes: [Double], propertyOverrides: [[String: FrameValue]]? = nil) throws -> [[UInt8]] {
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice(), "Metal is required for renderer tests")
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        return try deltaTimes.enumerated().map { index, deltaTime in
            if let propertyOverrides { renderer.updatePropertyOverrides(propertyOverrides[index]) }
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: deltaTime, into: texture, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            texture.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            return pixels
        }
    }

    private func makeFixture(effectCount: Int, angle: Double = 0, fullscreen: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WECoordinates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func json(_ name: String, _ object: Any) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(name))
        }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "name": "asymmetric", "image": "model.json", "origin": "16 48 0", "angles": "0 0 \(angle)",
                         "effects": (0..<effectCount).map { ["id": $0, "file": "effect.json"] }]]
        ])
        try json("model.json", ["material": "material.json", "width": 32, "height": 32, "fullscreen": fullscreen])
        try json("material.json", ["passes": [["shader": "copy", "textures": ["colors.png"], "blending": "normal"]]])
        try json("effect-material.json", ["passes": [["shader": "copy", "blending": "normal"]]])
        try json("effect.json", ["passes": [["material": "effect-material.json"]]])
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() { v_TexCoord = a_TexCoord; gl_Position = \(fullscreen ? "" : "g_ModelViewProjectionMatrix * ")vec4(a_Position, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let data = Data((0..<32).flatMap { y in
            (0..<32).flatMap { _ -> [UInt8] in y < 16 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        })
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent("colors.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return root
    }
}
