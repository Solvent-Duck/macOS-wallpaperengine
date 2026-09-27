import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct DynamicLayerRenderingTests {
    @Test func manyCreatedImagesPreserveSceneReadOrder() throws {
        let fixture = try RenderFixture(script: """
            export function init() {
                for (let i = 0; i < 120; ++i)
                    thisScene.createLayer({image:'red.json',origin:[32,16,0]});
                thisScene.createLayer({image:'scene-read.json',origin:[32,16,0]});
                thisScene.createLayer({image:'green.json',origin:[48,16,0],scale:[0.5,1,1]});
                return false;
            }
            """)
        let packet = try fixture.draw()
        #expect(packet.nodes.count == 123)
        // The read sees every preceding red layer, then the green layer paints
        // over its right half. The scene read must include all preceding draws.
        #expect(Array(fixture.pixel(x: 16, y: 16).prefix(3)) == [0,255,255])
        #expect(Array(fixture.pixel(x: 48, y: 16).prefix(3)) == [0,255,0])
    }

    @Test func autosizedCreatedBarsUseTextureDimensionsAndLiveAlignment() throws {
        let fixture = try RenderFixture(script: """
            let bar, frame = 0;
            export function init() {
                bar = thisScene.createLayer({image:'auto.json',origin:[32,16,0]});
                if (bar.size.x !== 4 || bar.size.y !== 4) throw new Error('incorrect intrinsic size');
                bar.scale = new Vec3(4,3,1);
                return false;
            }
            export function update() { bar.alignment = ++frame === 1 ? 'bottom' : 'top'; return false; }
            """)
        let first = try fixture.draw()
        #expect(first.nodes.last?.imageAlignment == "bottom")
        #expect(fixture.pixel(x: 32, y: 10)[1] == 255)
        #expect(fixture.pixel(x: 32, y: 22)[1] == 0)
        #expect(fixture.pixel(x: 10, y: 10)[1] == 0)
        let second = try fixture.draw()
        #expect(second.nodes.last?.imageAlignment == "top")
        #expect(fixture.pixel(x: 32, y: 10)[1] == 0)
        #expect(fixture.pixel(x: 32, y: 22)[1] == 255)
    }

    @Test func createdLayersDrawInSortedOrderAndDisappearAfterDeletion() throws {
        let fixture = try RenderFixture(script: """
            let red, green, frame = 0;
            export function init() {
                red = thisScene.createLayer({name:'red',image:'red.json',origin:[32,16,0]});
                green = thisScene.createLayer({name:'green',image:'green.json',origin:[32,16,0]});
                return false;
            }
            export function update() {
                ++frame;
                if (frame === 2) thisScene.sortLayer(red, thisScene.getLayerCount()-1);
                if (frame === 3) thisScene.destroyLayer(red);
                if (frame === 4) thisScene.destroyLayer(green);
                return false;
            }
            """)
        for expected: [UInt8] in [[0,255,0], [255,0,0], [255,0,0], [0,255,0], [0,0,0]] {
            _ = try fixture.draw()
            #expect(Array(fixture.pixel(x: 32, y: 16).prefix(3)) == expected)
        }
        #expect(fixture.renderer.scene.nodes.count == 1)
    }

    @Test func repeatedTextCreationDrawsAndReleasesTextures() throws {
        let fixture = try RenderFixture(script: """
            let previous, frame = 0;
            export function update() {
                if (frame++ < 24) {
                    previous = thisScene.createLayer({text:'X',pointsize:24,color:[1,1,1],origin:[32,16,0]});
                    thisScene.destroyLayer(previous);
                }
                return false;
            }
            """)
        for _ in 0..<24 {
            let packet = try fixture.draw()
            #expect(packet.texts.count == 1)
            #expect(fixture.pixels().enumerated().contains { $0.offset % 4 != 3 && $0.element > 100 })
            #expect(fixture.renderer.layerResourceCounts.text == 1)
        }
        _ = try fixture.draw()
        #expect(fixture.renderer.layerResourceCounts.text == 0)
        #expect(fixture.renderer.scene.nodes.count == 1)
        #expect(fixture.pixels().enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 })
    }
}

private final class RenderFixture {
    let root: URL
    let renderer: NativeSceneRenderer
    let queue: MTLCommandQueue
    let target: MTLTexture

    init(script: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicLayerRendering-\(UUID().uuidString)")
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func json(_ file: String, _ object: Any) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(file))
        }
        try json("project.json", ["title":"Dynamic render", "type":"scene", "file":"scene.json"])
        try json("scene.json", ["camera":[:], "general":["clearcolor":"0 0 0", "orthogonalprojection":["width":64,"height":32]],
            "objects":[["id":1,"image":"green.json","visible":["value":false,"script":script]]]])
        try json("auto.json", ["material":"auto-material.json","autosize":true])
        try json("auto-material.json", ["passes":[["shader":"green","blending":"normal","textures":["pixel.tex"]]]])
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { tex.append(contentsOf: $0) } }
        [0,2,4,4,4,4,0].forEach { word(UInt32($0)) }
        tex.append(Data("TEXB0001\0".utf8))
        [1,1,4,4,64].forEach { word(UInt32($0)) }
        for _ in 0..<16 { tex.append(contentsOf: [0,255,0,255]) }
        try tex.write(to: root.appendingPathComponent("pixel.tex"))
        try json("scene-read.json", ["material":"scene-read-material.json","width":64,"height":32])
        try json("scene-read-material.json", ["passes":[["shader":"scene-read","blending":"normal","textures":["_rt_FullFrameBuffer"]]]])
        try "attribute vec3 a_Position; attribute vec2 a_TexCoord; uniform mat4 g_ModelViewProjectionMatrix; varying vec2 v_UV; void main(){v_UV=a_TexCoord;gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);}"
            .write(to: root.appendingPathComponent("shaders/scene-read.vert"), atomically: true, encoding: .utf8)
        try "uniform sampler2D g_Texture0; varying vec2 v_UV; void main(){gl_FragColor=vec4(vec3(1.0)-texSample2D(g_Texture0,v_UV).rgb,1.0);}"
            .write(to: root.appendingPathComponent("shaders/scene-read.frag"), atomically: true, encoding: .utf8)
        for (name, color) in [("red","1,0,0"), ("green","0,1,0")] {
            try json("\(name).json", ["material":"\(name)-material.json","width":64,"height":32])
            try json("\(name)-material.json", ["passes":[["shader":name,"blending":"normal"]]])
            try "attribute vec3 a_Position; uniform mat4 g_ModelViewProjectionMatrix; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);}"
                .write(to: root.appendingPathComponent("shaders/\(name).vert"), atomically: true, encoding: .utf8)
            try "void main(){gl_FragColor=vec4(\(color),1);}"
                .write(to: root.appendingPathComponent("shaders/\(name).frag"), atomically: true, encoding: .utf8)
        }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 32, mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
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
