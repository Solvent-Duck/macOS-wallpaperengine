import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct EffectFeedbackTests {
    @Test func nonUniqueEffectTargetsRetainFeedbackAcrossFrames() throws {
        let root = try makeSingleFeedbackFixture(command: "copy", unique: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try makeRenderer(root: root, device: device)
        let target = try makeTarget(device: device)

        #expect(try renderRed(renderer, queue: queue, target: target, pressed: false) <= 1,
                "fresh feedback storage must begin cleared")
        #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: true)),
                "held click writes the 0.25 impulse")
        for _ in 0..<3 {
            #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: false)),
                    "released input must retain the prior B feedback value")
        }

        let freshRenderer = try makeRenderer(root: root, device: device)
        let freshTarget = try makeTarget(device: device)
        #expect(try renderRed(freshRenderer, queue: queue, target: freshTarget, pressed: false) <= 1,
                "feedback storage must be scoped to a renderer, not shared with a prior scene instance")
    }

    @Test func materialTextureBindingRetainsFeedbackBeforeFirstWrite() throws {
        let root = try makeSingleFeedbackFixture(command: "copy", unique: false, readHistoryThroughMaterialTexture: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try makeRenderer(root: root, device: device), target = try makeTarget(device: device)

        #expect(try renderRed(renderer, queue: queue, target: target, pressed: false) <= 1)
        #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: true)))
        #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: false)),
                "a material texture at slot 1 is a read-before-write dependency too")
    }

    @Test func textEffectTargetsRetainFeedbackAcrossReleasedFrames() throws {
        let root = try makeTextFeedbackFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try makeRenderer(root: root, device: device), target = try makeTarget(device: device)

        #expect(try renderRed(renderer, queue: queue, target: target, pressed: false) <= 1)
        #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: true)),
                "opaque feedback display keeps the text-path sample deterministic")
        for _ in 0..<3 {
            #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: false)),
                    "text effect feedback must persist after release")
        }
    }

    @Test func feedbackSwapRetainsLogicalTargetMappingAcrossFrames() throws {
        let root = try makeSingleFeedbackFixture(command: "swap", unique: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try makeRenderer(root: root, device: device), target = try makeTarget(device: device)

        #expect(try renderRed(renderer, queue: queue, target: target, pressed: false) <= 1)
        #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: true)))
        for _ in 0..<3 {
            #expect((63...65).contains(try renderRed(renderer, queue: queue, target: target, pressed: false)),
                    "a swap must persist its logical A/B mapping, not only its physical textures")
        }
    }

    @Test func duplicateEffectIDsAndTargetNamesKeepIndependentHistories() throws {
        let root = try makePairedHistoryFixture(hideFirstOnThirdFrame: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try makeRenderer(root: root, device: device), target = try makeTarget(device: device)

        // First effect is 0.125, 0.25, 0.375. The second accumulates that
        // chain input with its own B history: 0.125, 0.375, 0.75.
        for expected in [32, 96, 191] {
            let value = try renderRed(renderer, queue: queue, target: target, pressed: false)
            #expect(abs(Int(value) - expected) <= 1,
                    "same authored IDs/FBO names must not alias effect histories")
        }
    }

    @Test func hidingEarlierEffectDoesNotRenumberLaterFeedbackHistory() throws {
        let root = try makePairedHistoryFixture(hideFirstOnThirdFrame: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try makeRenderer(root: root, device: device), target = try makeTarget(device: device)

        #expect(abs(Int(try renderRed(renderer, queue: queue, target: target, pressed: false)) - 32) <= 1)
        #expect(abs(Int(try renderRed(renderer, queue: queue, target: target, pressed: false)) - 96) <= 1)
        // The earlier source effect becomes invisible at 0.09 s. The final
        // effect still reads its own retained 0.375 history; it must not move
        // to the earlier effect's cache identity or begin again at zero.
        #expect(abs(Int(try renderRed(renderer, queue: queue, target: target, pressed: false)) - 96) <= 1,
                "omitting an earlier effect must not shift the later source identity")
    }

    private func makeRenderer(root: URL, device: MTLDevice) throws -> NativeSceneRenderer {
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        return try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
    }

    private func makeTarget(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func renderRed(_ renderer: NativeSceneRenderer, queue: MTLCommandQueue, target: MTLTexture, pressed: Bool) throws -> UInt8 {
        renderer.updateCursorInput(.init(x: 0.5, y: 0.5), leftDown: pressed)
        let command = try #require(queue.makeCommandBuffer())
        try renderer.renderNextFrame(deltaTime: 1 / 30, into: target, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        target.getBytes(&pixels, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
        return pixels[(4 * 8 + 4) * 4]
    }

    private func makeSingleFeedbackFixture(command: String, unique: Bool, readHistoryThroughMaterialTexture: Bool = false) throws -> URL {
        let root = try makeRoot()
        try writeScene(root: root, effects: [["id": 1, "file": "feedback-effect.json"]])
        try writeJSON("feedback-effect.json", feedbackEffect(writeMaterial: "write-material.json", displayMaterial: "display-material.json", command: command, unique: unique, readHistoryThroughMaterialTexture: readHistoryThroughMaterialTexture), root: root)
        try writeJSON("write-material.json", material(shader: readHistoryThroughMaterialTexture ? "feedbackmaterial" : "feedbackwrite", textures: readHistoryThroughMaterialTexture ? [NSNull(), "B"] : []), root: root)
        try writeJSON("display-material.json", material(shader: "feedbackdisplay"), root: root)
        try writeShaders(root: root)
        return root
    }

    private func makeTextFeedbackFixture() throws -> URL {
        let root = try makeRoot()
        try writeJSON("scene.json", [
            "camera": [:],
            "general": ["orthogonalprojection": ["width": 8, "height": 8], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "text": "H", "origin": "4 4 0", "font": "Helvetica", "pointsize": 6,
                         "effects": [["id": 1, "file": "feedback-effect.json"]]]]
        ], root: root)
        try writeJSON("feedback-effect.json", feedbackEffect(writeMaterial: "write-material.json", displayMaterial: "display-material.json", command: "copy", unique: false), root: root)
        try writeJSON("write-material.json", material(shader: "feedbackwrite"), root: root)
        try writeJSON("display-material.json", material(shader: "feedbackdisplay"), root: root)
        try writeShaders(root: root)
        return root
    }

    private func makePairedHistoryFixture(hideFirstOnThirdFrame: Bool) throws -> URL {
        let root = try makeRoot()
        var first: [String: Any] = ["id": 7, "file": "first-effect.json"]
        if hideFirstOnThirdFrame {
            first["visible"] = ["value": true, "script": "export function update(value) { return engine.runtime < 0.09; }"]
        }
        try writeScene(root: root, effects: [first, ["id": 7, "file": "second-effect.json"]])
        try writeJSON("first-effect.json", feedbackEffect(writeMaterial: "first-write-material.json", displayMaterial: "first-display-material.json", command: "copy", unique: false), root: root)
        try writeJSON("second-effect.json", feedbackEffect(writeMaterial: "second-write-material.json", displayMaterial: "second-display-material.json", command: "copy", unique: false, includePrevious: true), root: root)
        try writeJSON("first-write-material.json", material(shader: "increment"), root: root)
        try writeJSON("first-display-material.json", material(shader: "feedbackdisplay"), root: root)
        try writeJSON("second-write-material.json", material(shader: "combine"), root: root)
        try writeJSON("second-display-material.json", material(shader: "feedbackdisplay"), root: root)
        try writeShaders(root: root)
        return root
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEEffectFeedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try writeJSON("project.json", ["type": "scene", "file": "scene.json"], root: root)
        try writeJSON("model.json", ["material": "base-material.json", "width": 8, "height": 8, "fullscreen": true], root: root)
        try writeJSON("base-material.json", material(shader: "base"), root: root)
        return root
    }

    private func writeScene(root: URL, effects: [[String: Any]]) throws {
        try writeJSON("scene.json", [
            "camera": [:],
            "general": ["orthogonalprojection": ["width": 8, "height": 8], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "model.json", "origin": "4 4 0", "effects": effects]]
        ], root: root)
    }

    private func feedbackEffect(writeMaterial: String, displayMaterial: String, command: String, unique: Bool, includePrevious: Bool = false, readHistoryThroughMaterialTexture: Bool = false) -> [String: Any] {
        var binds: [[String: Any]] = readHistoryThroughMaterialTexture ? [] : [["name": "B", "index": 0]]
        if includePrevious { binds.append(["name": "previous", "index": 1]) }
        return [
            "fbos": [["name": "A", "format": "rgba8888", "scale": 1, "unique": unique],
                     ["name": "B", "format": "rgba8888", "scale": 1, "unique": unique]],
            "passes": [
                ["material": writeMaterial, "bind": binds, "target": "A"],
                ["command": command, "source": "A", "target": "B"],
                ["material": displayMaterial, "bind": [["name": "B", "index": 0]]]
            ]
        ]
    }

    private func material(shader: String, textures: [Any] = []) -> [String: Any] {
        var pass: [String: Any] = ["shader": shader, "blending": "normal"]
        if !textures.isEmpty { pass["textures"] = textures }
        return ["passes": [pass]]
    }

    private func writeJSON(_ name: String, _ value: Any, root: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
    }

    private func writeShaders(root: URL) throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() { v_TexCoord = a_TexCoord; gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }
        """
        for shader in ["base", "feedbackwrite", "feedbackmaterial", "feedbackdisplay", "increment", "combine"] {
            try vertex.write(to: root.appendingPathComponent("shaders/\(shader).vert"), atomically: true, encoding: .utf8)
        }
        try "void main() { gl_FragColor = vec4(0, 0, 0, 1); }"
            .write(to: root.appendingPathComponent("shaders/base.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        uniform vec4 g_PointerState;
        varying vec2 v_TexCoord;
        void main() {
            float prior = texSample2D(g_Texture0, v_TexCoord).r;
            gl_FragColor = vec4(max(prior, g_PointerState.z * 0.25), 0, 0, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/feedbackwrite.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture1;
        uniform vec4 g_PointerState;
        varying vec2 v_TexCoord;
        void main() {
            float prior = texSample2D(g_Texture1, v_TexCoord).r;
            gl_FragColor = vec4(max(prior, g_PointerState.z * 0.25), 0, 0, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/feedbackmaterial.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(texSample2D(g_Texture0, v_TexCoord).rgb, 1); }
        """.write(to: root.appendingPathComponent("shaders/feedbackdisplay.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(texSample2D(g_Texture0, v_TexCoord).r + 0.125, 0, 0, 1); }
        """.write(to: root.appendingPathComponent("shaders/increment.frag"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        varying vec2 v_TexCoord;
        void main() {
            float ownHistory = texSample2D(g_Texture0, v_TexCoord).r;
            float previousChain = texSample2D(g_Texture1, v_TexCoord).r;
            gl_FragColor = vec4(min(ownHistory + previousChain, 1.0), 0, 0, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/combine.frag"), atomically: true, encoding: .utf8)
    }
}
