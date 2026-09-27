import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct MediaArtworkTests {
    @Test func artworkRequiresBoundedTightlyPackedRGBA8() {
        #expect(SceneMediaArtwork(width: 0, height: 1, rgba8: Data()) == nil)
        #expect(SceneMediaArtwork(width: 1, height: 1025, rgba8: Data(repeating: 0, count: 4)) == nil)
        #expect(SceneMediaArtwork(width: 2, height: 1, rgba8: Data(repeating: 0, count: 7)) == nil)
        let artwork = SceneMediaArtwork(width: 1, height: 1, rgba8: Data([1, 2, 3, 4]))
        #expect(artwork?.width == 1)
        #expect(artwork?.height == 1)
        #expect(artwork?.rgba8 == Data([1, 2, 3, 4]))
        #expect(SceneMediaState.Thumbnail().artwork == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func mediaArtworkBindsCurrentAndPreviousCoversWithoutStaleState(effect: Bool, fallback: Bool) throws {
        let root = try fixture(effect: effect, fallback: fallback)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))

        func capture(_ renderer: NativeSceneRenderer, target: MTLTexture) throws -> [UInt8] {
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: 0, into: target, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
            target.getBytes(&pixels, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            return pixels
        }
        func pixel(_ pixels: [UInt8], _ x: Int) -> [UInt8] {
            Array(pixels[(4 * 8 + x) * 4..<(4 * 8 + x) * 4 + 4])
        }
        let emptyCoverEncoded: [UInt8] = fallback ? [0, 255, 255, 255] : [0, 0, 0, 255]

        // Missing media uses the authored placeholder, or transparency when none exists.
        var pixels = try capture(renderer, target: target)
        #expect(pixel(pixels, 0) == emptyCoverEncoded)
        #expect(pixel(pixels, 2) == emptyCoverEncoded)

        // The two rows make both top-row-first upload and straight alpha observable.
        let coverA = try #require(SceneMediaArtwork(width: 2, height: 2, rgba8: Data([
            255, 0, 0, 255,    255, 0, 0, 255,
            0, 0, 255, 64,     0, 0, 255, 64,
        ])))
        let coverB = try #require(SceneMediaArtwork(width: 1, height: 2, rgba8: Data([
            0, 255, 255, 128,
            255, 0, 255, 255,
        ])))
        var state = SceneMediaState()
        state.enabled = true
        state.thumbnail.hasThumbnail = true
        state.thumbnail.identifier = "same-identifier"
        state.thumbnail.artwork = coverA
        renderer.updateMediaState(state)
        pixels = try capture(renderer, target: target)
        #expect(pixel(pixels, 0) == [255, 0, 255, 255]) // current top: red, alpha 1
        #expect(pixel(pixels, 1) == [0, 255, 64, 255]) // current bottom: blue, alpha 64/255
        #expect(pixel(pixels, 2) == emptyCoverEncoded) // previous cover retains its placeholder on first artwork
        #expect(pixel(pixels, 4) == [64, 64, 0, 255]) // current texture is 2x2

        // Re-publishing identical artwork does not manufacture a previous cover.
        renderer.updateMediaState(state)
        pixels = try capture(renderer, target: target)
        #expect(pixel(pixels, 2) == emptyCoverEncoded)

        // A different payload with the same identifier must replace current and retain A as previous.
        state.thumbnail.artwork = coverB
        renderer.updateMediaState(state)
        pixels = try capture(renderer, target: target)
        #expect(pixel(pixels, 0) == [0, 255, 128, 255])
        #expect(pixel(pixels, 2) == [255, 0, 255, 255])
        #expect(pixel(pixels, 4) == [32, 64, 0, 255]) // current texture is 1x2
        #expect(pixel(pixels, 6) == [64, 64, 0, 255]) // previous texture remains A at 2x2

        // Disabling clears both covers even when the platform state still carries B.
        state.enabled = false
        renderer.updateMediaState(state)
        pixels = try capture(renderer, target: target)
        #expect(pixel(pixels, 0) == emptyCoverEncoded)
        #expect(pixel(pixels, 2) == emptyCoverEncoded)

        // Re-enabling without artwork must not revive either old texture.
        state.enabled = true
        state.thumbnail.hasThumbnail = false
        state.thumbnail.artwork = nil
        renderer.updateMediaState(state)
        pixels = try capture(renderer, target: target)
        #expect(pixel(pixels, 0) == emptyCoverEncoded)
        #expect(pixel(pixels, 2) == emptyCoverEncoded)

        // Artwork ownership is renderer-local: a fresh renderer cannot inherit prior covers.
        let freshRenderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let freshTarget = try #require(device.makeTexture(descriptor: descriptor))
        pixels = try capture(freshRenderer, target: freshTarget)
        #expect(pixel(pixels, 0) == emptyCoverEncoded)
        #expect(pixel(pixels, 2) == emptyCoverEncoded)
    }

    private func fixture(effect: Bool, fallback: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEMediaArtwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func json(_ file: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(file))
        }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", [
            "camera": [:],
            "general": ["orthogonalprojection": ["width": 8, "height": 8]],
            "objects": [["id": 1, "image": "model.json", "origin": "4 4 0"]],
        ])
        try json("model.json", ["material": "material.json", "width": 8, "height": 8])
        try json("material.json", ["passes": [[
            "shader": "mediaartwork", "blending": "normal",
            "usertextures": [
                ["name": "$mediaThumbnail", "type": "system"],
                ["name": "$mediaPreviousThumbnail", "type": "system"],
            ],
        ]]])
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/mediaartwork.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture0Resolution;
        uniform vec4 g_Texture1Resolution;
        void main() {
            vec4 currentTop = texSample2D(g_Texture0, vec2(0.5, 0.25));
            vec4 currentBottom = texSample2D(g_Texture0, vec2(0.5, 0.75));
            vec4 previousTop = texSample2D(g_Texture1, vec2(0.5, 0.25));
            vec4 previousBottom = texSample2D(g_Texture1, vec2(0.5, 0.75));
            if (gl_FragCoord.x < 1.0) gl_FragColor = vec4(currentTop.r, currentTop.b, currentTop.a, 1.0);
            else if (gl_FragCoord.x < 2.0) gl_FragColor = vec4(currentBottom.r, currentBottom.b, currentBottom.a, 1.0);
            else if (gl_FragCoord.x < 3.0) gl_FragColor = vec4(previousTop.r, previousTop.b, previousTop.a, 1.0);
            else if (gl_FragCoord.x < 4.0) gl_FragColor = vec4(previousBottom.r, previousBottom.b, previousBottom.a, 1.0);
            else if (gl_FragCoord.x < 6.0) gl_FragColor = vec4(g_Texture0Resolution.xy / 8.0, 0.0, 1.0);
            else gl_FragColor = vec4(g_Texture1Resolution.xy / 8.0, 0.0, 1.0);
        }
        """.write(to: root.appendingPathComponent("shaders/mediaartwork.frag"), atomically: true, encoding: .utf8)
        if effect {
            try json("scene.json", [
                "camera": [:], "general": ["orthogonalprojection": ["width": 8, "height": 8]],
                "objects": [["id": 1, "image": "model.json", "origin": "4 4 0", "effects": [[
                    "file": "effect.json", "id": 10, "passes": [["id": 200, "usertextures": [
                        NSNull(), ["name": "$mediaThumbnail", "type": "system"],
                        ["name": "$mediaPreviousThumbnail", "type": "system"],
                    ]]],
                ]]]],
            ])
            try json("effect.json", ["passes": [["material": "effect-material.json"]]])
            try json("effect-material.json", ["passes": [["shader": "effectartwork", "blending": "normal"]]])
            let vertex = try String(contentsOf: root.appendingPathComponent("shaders/mediaartwork.vert"), encoding: .utf8)
            let fragment = try String(contentsOf: root.appendingPathComponent("shaders/mediaartwork.frag"), encoding: .utf8)
                .replacingOccurrences(of: "g_Texture1", with: "g_Texture2")
                .replacingOccurrences(of: "g_Texture0", with: "g_Texture1")
            try vertex.write(to: root.appendingPathComponent("shaders/effectartwork.vert"), atomically: true, encoding: .utf8)
            try fragment.write(to: root.appendingPathComponent("shaders/effectartwork.frag"), atomically: true, encoding: .utf8)
        }
        if fallback {
            let provider = try #require(CGDataProvider(data: Data([0, 0, 255, 255]) as CFData))
            let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent("fallback.png") as CFURL,
                UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            let url = root.appendingPathComponent(effect ? "effect-material.json" : "material.json")
            var material = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var passes = try #require(material["passes"] as? [[String: Any]])
            passes[0]["textures"] = effect ? [NSNull(), "fallback.png", "fallback.png"] : ["fallback.png", "fallback.png"]
            material["passes"] = passes
            try JSONSerialization.data(withJSONObject: material).write(to: url)
        }
        return root
    }
}
