import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct CursorRenderingTests {
    @Test func shaderReceivesCurrentAndPreviousRenderedPositions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WECursorShader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ file: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(file))
        }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", ["camera": [:], "general": ["orthogonalprojection": ["width": 8, "height": 8]],
            "objects": [["id": 1, "image": "model.json", "origin": "4 4 0"]]])
        try json("model.json", ["material": "material.json", "width": 8, "height": 8])
        try json("material.json", ["passes": [["shader": "pointer", "blending": "normal"]]])
        try """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/pointer.vert"), atomically: true, encoding: .utf8)
        try """
        uniform vec2 g_PointerPosition;
        uniform vec2 g_PointerPositionLast;
        void main() { gl_FragColor = vec4(vec3(g_PointerPosition.x, g_PointerPositionLast.x, g_PointerPositionLast.y) * 0.5 + 0.25, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/pointer.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let cases: [(CGPoint, [Int])] = [(.init(x: 0.2, y: 0.3), [89, 89, 102]),
            (.init(x: 0.8, y: 0.6), [166, 89, 102]), (.init(x: 0.8, y: 0.6), [166, 166, 140]), (.init(x: -0.2, y: 1.5), [64, 166, 140]),
            (.init(x: 0.8, y: 0.6), [166, 64, 191])]
        for (position, expected) in cases {
            renderer.updateCursorInput(position, leftDown: false)
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: 1 / 30, into: texture, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
            texture.getBytes(&pixels, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            for channel in 0..<3 { #expect(abs(Int(pixels[(4 * 8 + 4) * 4 + channel]) - expected[channel]) <= 1) }
        }
    }
}

extension CursorRenderingTests {
    @Test func shaderReceivesHeldAndReleasedPointerState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEPointerState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ file: String, _ value: Any) throws { try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(file)) }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", ["camera": [:], "general": ["orthogonalprojection": ["width": 8, "height": 8]], "objects": [["id": 1, "image": "model.json", "origin": "4 4 0"]]])
        try json("model.json", ["material": "material.json", "width": 8, "height": 8])
        try json("material.json", ["passes": [["shader": "pointerstate", "blending": "normal"]]])
        try "attribute vec3 a_Position; uniform mat4 g_ModelViewProjectionMatrix; void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }".write(to: root.appendingPathComponent("shaders/pointerstate.vert"), atomically: true, encoding: .utf8)
        // Two sampled pixels expose all four components with opaque output.
        try "uniform vec4 g_PointerState; void main() { vec3 v = gl_FragCoord.x < 4.0 ? g_PointerState.xyz : vec3(g_PointerState.w, g_PointerState.x, g_PointerState.y); gl_FragColor = vec4(v * 0.5 + 0.25, 1.0); }".write(to: root.appendingPathComponent("shaders/pointerstate.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        func render(_ position: CGPoint?, _ down: Bool) throws -> [UInt8] {
            if let position { renderer.updateCursorInput(position, leftDown: down) }
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: 1 / 30, into: texture, commandBuffer: command)
            command.commit(); command.waitUntilCompleted(); #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
            texture.getBytes(&pixels, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            let pixel = { (x: Int) in Array(pixels[(4 * 8 + x) * 4..<(4 * 8 + x) * 4 + 3]) }
            return pixel(2) + pixel(6)
        }
        let neutral: [UInt8] = [64, 64, 64, 64, 64, 64]
        #expect(try render(nil, false) == neutral) // initial/default input
        #expect(try render(.init(x: 0.2, y: 0.3), false) == neutral) // explicit up
        #expect(try render(.init(x: 0.2, y: 0.3), true) == [64, 64, 191, 64, 64, 64])
        #expect(try render(.init(x: 0.8, y: 0.6), true) == [64, 64, 191, 64, 64, 64])
        #expect(try render(.init(x: 0.8, y: 0.6), false) == neutral) // release
    }
}
