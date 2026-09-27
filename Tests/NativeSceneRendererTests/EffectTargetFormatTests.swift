import Foundation
import Metal
import NativeSceneCore
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct EffectTargetFormatTests {
    @Test(arguments: [("rgba8888", 0), ("r8", 9), ("rg88", 8), ("r16f", 11), ("rg1616f", 10)], [0, 2])
    func effectBindingsSupplyTextureFormatMetadata(format: (String, Int), slot: Int) throws {
        let root = try fixture(formats: [format.0], steps: [
            ["material": "write.json", "target": "T0"],
            ["material": "display.json", "bind": [["name": "T0", "index": slot]]]
        ], write: "vec4(0.25, 0.5, 0.75, 1)")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform sampler2D g_Texture\(slot);
        varying vec2 v_TexCoord;
        void main() {
            vec4 value = texSample2D(g_Texture\(slot), v_TexCoord);
        #if TEX\(slot)FORMAT == \(format.1)
            gl_FragColor = vec4(0, 1, value.r, 1);
        #else
            gl_FragColor = vec4(1, 0, value.r, 1);
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/display.frag"), atomically: true, encoding: .utf8)
        expect(try render(root: root)[0], near: [0, 255, 64])
    }

    @Test(arguments: ["r16f", "rg1616f", "rgb161616f", "rgba16161616f"])
    func floatingTargetsPreserveSignedAndAboveOneValues(format: String) throws {
        let root = try fixture(formats: [format])
        defer { try? FileManager.default.removeItem(at: root) }
        let pixel = try render(root: root)[0]
        expect(pixel, near: [64, format == "r16f" ? 0 : 96,
                            ["rgb161616f", "rgba16161616f"].contains(format) ? 64 : 0])
    }

    @Test(arguments: ["r8", "rg88", "rgba8888", "rgba_backbuffer"])
    func normalizedTargetsClampValuesAndSupplyMissingChannels(format: String) throws {
        let root = try fixture(formats: [format])
        defer { try? FileManager.default.removeItem(at: root) }
        expect(try render(root: root)[0], near: [128, format == "r8" ? 0 : 64,
                                               ["rgba8888", "rgba_backbuffer"].contains(format) ? 32 : 0])
    }

    @Test(arguments: ["r16f", "rg1616f", "rgb161616f", "rgba16161616f", "r8", "rg88"])
    func targetsWithoutAlphaSampleAsOpaque(format: String) throws {
        let root = try fixture(formats: [format], display: "vec4(vec3(value.a), 1.0)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = format == "rgba16161616f" ? 32 : 255
        expect(try render(root: root)[0], near: [expected, expected, expected])
    }

    @Test func oneMaterialCanWriteDifferentAttachmentFormatsInOneFrame() throws {
        let root = try fixture(formats: ["r16f", "rg1616f", "rgb161616f"],
            display: "vec4(value.r + 0.5, texSample2D(g_Texture1, v_TexCoord).g * 0.25, texSample2D(g_Texture2, v_TexCoord).b * 0.125, 1.0)")
        defer { try? FileManager.default.removeItem(at: root) }
        expect(try render(root: root)[0], near: [64, 96, 64])
    }

    @Test(arguments: ["copy", "swap"], ["r16f", "rgb161616f"])
    func floatingFeedbackSurvivesCommandsAndLaterFrames(command: String, format: String) throws {
        let steps: [[String: Any]] = [
            ["material": "write.json", "target": "T0", "bind": [["name": "T1", "index": 0]]],
            ["command": command, "source": "T0", "target": "T1"],
            ["material": "display.json", "bind": [["name": "T1", "index": 0]]]
        ]
        let root = try fixture(formats: [format, format], steps: steps,
            write: "vec4(texSample2D(g_Texture0, v_TexCoord).r - 0.25, 0, 0, 1)",
            display: "vec4(value.r + 1.0, 0, 0, 1)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try render(root: root, frames: 3)
        for (pixel, expected) in zip(pixels, [191, 128, 64]) {
            expect(pixel, near: [expected, 0, 0])
        }
    }

    @Test func copyConvertsDifferentFloatingFormatsWithoutClamping() throws {
        let steps: [[String: Any]] = [
            ["material": "write.json", "target": "T0"],
            ["command": "copy", "source": "T0", "target": "T1"],
            ["material": "display.json", "bind": [["name": "T1", "index": 0]]]
        ]
        let root = try fixture(formats: ["rg1616f", "rgba16161616f"], steps: steps)
        defer { try? FileManager.default.removeItem(at: root) }
        expect(try render(root: root)[0], near: [64, 96, 0])
    }

    @Test func textEffectsPreserveSignedValues() throws {
        let root = try fixture(formats: ["r16f"], text: true)
        defer { try? FileManager.default.removeItem(at: root) }
        expect(try render(root: root)[0], near: [64, 0, 0])
    }

    @Test func convertingCopyPreservesTheUnscaledOverlappingRegion() throws {
        let steps: [[String: Any]] = [
            ["material": "write.json", "target": "T0"],
            ["command": "copy", "source": "T0", "target": "T1"],
            ["material": "display.json", "bind": [["name": "T1", "index": 0]]]
        ]
        let root = try fixture(formats: ["r16f", "rgba16161616f"], steps: steps,
            write: "vec4(v_TexCoord.x < 0.5 ? -0.25 : 0.25, 0, 0, 1)", scales: [1, 2])
        defer { try? FileManager.default.removeItem(at: root) }
        expect(try render(root: root)[0], near: [64, 0, 0])
    }

    @Test func copyingRGBToRGBAUsesOpaqueAlphaDespiteMatchingBackingFormats() throws {
        let steps: [[String: Any]] = [
            ["material": "write.json", "target": "T0"],
            ["command": "copy", "source": "T0", "target": "T1"],
            ["material": "display.json", "bind": [["name": "T1", "index": 0]]]
        ]
        let root = try fixture(formats: ["rgb161616f", "rgba16161616f"], steps: steps,
            display: "vec4(vec3(value.a), 1.0)")
        defer { try? FileManager.default.removeItem(at: root) }
        expect(try render(root: root)[0], near: [255, 255, 255])
    }

    @Test func unknownFormatsRetainPlaybackWithAnExplicitPartialSupportReport() throws {
        let root = try fixture(formats: ["future-format"])
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let support = NativeSceneRenderer.support(scene: scene)
        #expect(support.isSupported)
        #expect(support.parityStatus == .partial)
        #expect(support.placeholderSubsystems.contains("effect-target-formats"))
        expect(try render(root: root)[0], near: [128, 64, 32])
    }

    private func expect(_ pixel: [UInt8], near expected: [Int], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(zip(pixel.prefix(3), expected).allSatisfy { abs(Int($0.0) - $0.1) <= 1 },
                "actual RGB \(Array(pixel.prefix(3))); expected \(expected)", sourceLocation: sourceLocation)
    }

    private func render(root: URL, frames: Int = 1) throws -> [[UInt8]] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        return try (0..<frames).map { _ in
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: 1 / 30, into: target, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
            target.getBytes(&pixels, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            let center = (4 * 8 + 4) * 4
            return Array(pixels[center..<center + 4])
        }
    }

    private func fixture(formats: [String], steps: [[String: Any]]? = nil,
                         write: String = "vec4(-0.25, 1.5, 2.0, 0.125)",
                         display: String = "vec4(value.r + 0.5, value.g * 0.25, value.b * 0.125, 1.0)",
                         text: Bool = false, scales: [Double]? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEEffectTargetFormat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try json("project.json", ["type": "scene", "file": "scene.json"], root: root)
        try json("model.json", ["material": "base.json", "width": 8, "height": 8, "fullscreen": true], root: root)
        var node: [String: Any] = ["id": 1, "origin": "4 4 0", "effects": [["id": 1, "file": "effect.json"]]]
        if text {
            node.merge(["text": "H", "font": "Helvetica", "pointsize": 6]) { _, last in last }
        } else {
            node["image"] = "model.json"
        }
        try json("scene.json", ["camera": [:],
            "general": ["orthogonalprojection": ["width": 8, "height": 8], "clearcolor": "0 0 0"],
            "objects": [node]], root: root)
        let binds = formats.indices.map { ["name": "T\($0)", "index": $0] as [String: Any] }
        let passes = steps ?? formats.indices.map { ["material": "write.json", "target": "T\($0)"] as [String: Any] }
            + [["material": "display.json", "bind": binds]]
        try json("effect.json", ["fbos": formats.enumerated().map {
            ["name": "T\($0.offset)", "format": $0.element, "scale": scales?[$0.offset] ?? 1, "unique": true] as [String: Any]
        }, "passes": passes], root: root)
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() { v_TexCoord = a_TexCoord; gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }
        """
        for shader in ["base", "write", "display"] {
            try json("\(shader).json", ["passes": [["shader": shader, "blending": "normal"]]], root: root)
            try vertex.write(to: root.appendingPathComponent("shaders/\(shader).vert"), atomically: true, encoding: .utf8)
        }
        try "void main() { gl_FragColor = vec4(0, 0, 0, 1); }"
            .write(to: root.appendingPathComponent("shaders/base.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = \(write); }
        """.write(to: root.appendingPathComponent("shaders/write.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform sampler2D g_Texture2;
        varying vec2 v_TexCoord;
        void main() { vec4 value = texSample2D(g_Texture0, v_TexCoord); gl_FragColor = \(display); }
        """.write(to: root.appendingPathComponent("shaders/display.frag"), atomically: true, encoding: .utf8)
        return root
    }

    private func json(_ name: String, _ value: Any, root: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
    }
}
