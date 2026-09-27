import Foundation
import Metal
import NativeSceneCore
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct SceneLightingTests {
    @Test(arguments: [0, 1, 3, 4, 5], [false, true])
    func legacyLightColorsPackFourLightsWithoutInventingAnother(lightCount: Int, hideFirst: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELegacyLights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func write(_ value: Any, _ name: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        try write(["type": "scene", "file": "scene.json"], "project.json")
        try write(["material": "material.json", "width": 64, "height": 64], "model.json")
        try write(["passes": [["shader": "lights", "blending": "normal"]]], "material.json")
        let colors: [[Double]] = [[0.1, 0.2, 0.3], [0.3, 0.1, 0.2], [0.5, 0.4, 0.3], [0.25, 0.5, 0.75], [1, 1, 1]]
        let intensities = [2.0, 0.5, 0.75, 1.25, 1.0]
        var objects: [[String: Any]] = [["id": 1, "image": "model.json", "origin": "32 32 0"]]
        for index in 0..<lightCount {
            objects.append(["id": index + 2, "light": "lpoint", "origin": "32 32 100",
                            "color": colors[index], "intensity": intensities[index], "visible": !(hideFirst && index == 0)])
        }
        try write(["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                   "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": objects], "scene.json")
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """.write(to: root.appendingPathComponent("shaders/lights.vert"), atomically: true, encoding: .utf8)
        try """
        uniform vec4 g_LightsColorPremultiplied[3];
        varying vec2 v_TexCoord;
        void main() {
            int index = int(v_TexCoord.y * 4.0);
            vec3 color;
            if (index < 3) color = g_LightsColorPremultiplied[index].rgb;
            else color = vec3(g_LightsColorPremultiplied[0].w, g_LightsColorPremultiplied[1].w, g_LightsColorPremultiplied[2].w);
            gl_FragColor = vec4(color, 1.0);
        }
        """.write(to: root.appendingPathComponent("shaders/lights.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(queue.makeCommandBuffer())
        try renderer.renderNextFrame(deltaTime: 0, into: target, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        target.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        let visibleIndices = (0..<lightCount).filter { !hideFirst || $0 != 0 }
        for index in 0..<4 {
            let offset = ((index * 16 + 8) * 64 + 32) * 4
            for channel in 0..<3 {
                let source = index < visibleIndices.count ? visibleIndices[index] : nil
                let expected = source.map { Int((colors[$0][channel] * intensities[$0] * 255).rounded()) } ?? 0
                #expect(abs(Int(pixels[offset + channel]) - expected) <= 1)
            }
        }
    }
}
