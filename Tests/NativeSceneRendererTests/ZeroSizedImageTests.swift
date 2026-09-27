import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct ZeroSizedImageTests {
    @Test func zeroSizedHelpersRemainInvisibleAndKeepRunningScripts() throws {
        let fixture = try ZeroSizeFixture(objects: [
            ["id": 1, "image": "solid.json", "size": "0 0", "origin": [32, 16, 0],
             "visible": ["value": true, "script": "export function update(value) { thisLayer.origin.x += 1; return value; }"]],
            ["id": 2, "image": "solid.json", "size": [0, 32], "origin": [32, 16, 0]],
            ["id": 3, "image": "solid.json", "size": [64, 0], "origin": [32, 16, 0]],
        ])
        let first = try fixture.draw()
        let second = try fixture.draw()
        #expect(first.nodes.count == 3 && second.nodes.count == 3)
        #expect(second.nodes[0].worldPosition.x > first.nodes[0].worldPosition.x)
        #expect(fixture.pixels().enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 })
    }

    @Test func explicitZeroOnCreatedImageDoesNotRequestIntrinsicAutosizing() throws {
        let script = """
            export function init() {
                const empty = thisScene.createLayer({image:'auto.json',size:[0,0],origin:[32,16,0]});
                if (empty.size.x !== 0 || empty.size.y !== 0) throw new Error('zero size was replaced');
                const clone = thisScene.createLayer(thisScene.getInitialLayerConfig(empty));
                clone.origin = new Vec3(48,16,0);
                thisScene.createLayer({image:'auto.json',origin:[8,16,0]});
                return false;
            }
            """
        let fixture = try ZeroSizeFixture(objects: [
            ["id": 1, "image": "solid.json", "visible": ["value": false, "script": script]],
        ])
        let packet = try fixture.draw()
        #expect(packet.nodes.count == 4)
        #expect(fixture.pixel(x: 8, y: 16) == [0, 255, 0, 255])
        #expect(fixture.pixel(x: 32, y: 16) == [0, 0, 0, 255])
        #expect(fixture.pixel(x: 48, y: 16) == [0, 0, 0, 255])
    }

    @Test func omittedSizeKeepsFallbackAndModelDimensions() throws {
        let fixture = try ZeroSizeFixture(objects: [
            ["id": 1, "image": "solid.json"],
            ["id": 2, "image": "fixed.json"],
            ["id": 3, "image": "solid.json", "size": [12, 20]],
        ])
        let imageRenderer = ImageRenderer(assetRoots: [fixture.root])
        let sizes = fixture.renderer.scene.nodes.map {
            imageRenderer.resolvedSize(for: $0, scene: fixture.renderer.scene, viewportSize: CGSize(width: 64, height: 32))
        }
        #expect(sizes == [CGSize(width: 256, height: 256), CGSize(width: 16, height: 8), CGSize(width: 12, height: 20)])
    }
}

private final class ZeroSizeFixture {
    let root: URL
    let renderer: NativeSceneRenderer
    let queue: MTLCommandQueue
    let target: MTLTexture

    init(objects: [[String: Any]]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZeroSizedImage-\(UUID().uuidString)")
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func json(_ path: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", ["camera": [:], "general": ["clearcolor": "0 0 0", "orthogonalprojection": ["width": 64, "height": 32]], "objects": objects])
        try json("solid.json", ["material": "material.json", "solidlayer": true])
        try json("fixed.json", ["material": "material.json", "width": 16, "height": 8])
        try json("auto.json", ["material": "material.json", "autosize": true])
        try json("material.json", ["passes": [["shader": "green", "blending": "normal", "textures": ["pixel.tex"]]]])
        try "attribute vec3 a_Position; uniform mat4 g_ModelViewProjectionMatrix; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);}"
            .write(to: root.appendingPathComponent("shaders/green.vert"), atomically: true, encoding: .utf8)
        try "void main(){gl_FragColor=vec4(0,1,0,1);}"
            .write(to: root.appendingPathComponent("shaders/green.frag"), atomically: true, encoding: .utf8)
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { tex.append(contentsOf: $0) } }
        [0,2,4,4,4,4,0].forEach { word(UInt32($0)) }
        tex.append(Data("TEXB0001\0".utf8))
        [1,1,4,4,64].forEach { word(UInt32($0)) }
        for _ in 0..<16 { tex.append(contentsOf: [0,255,0,255]) }
        try tex.write(to: root.appendingPathComponent("pixel.tex"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 32, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        target = try #require(device.makeTexture(descriptor: descriptor))
    }

    func draw() throws -> FramePacket {
        let command = try #require(queue.makeCommandBuffer())
        let packet = try renderer.renderNextFrame(deltaTime: 0.01, into: target, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        return packet
    }

    func pixels() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
        target.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
        return pixels
    }
    func pixel(x: Int, y: Int) -> [UInt8] { Array(pixels()[(y * 64 + x) * 4..<(y * 64 + x + 1) * 4]) }
    deinit { try? FileManager.default.removeItem(at: root) }
}
