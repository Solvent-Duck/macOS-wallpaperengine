import Foundation
import Metal
import NativeSceneCore
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct ImageTextureAnimationTests {
    @Test(arguments: [0,1], [false,true])
    func seekSelectsRotatedSecondPageWhileOtherLayersKeepAnimating(effectCount: Int, autoCombo: Bool) throws {
        let root=try fixture(effectCount: effectCount, autoCombo: autoCombo)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene=try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path,assetsPath: root.path)
        let device=try #require(MTLCreateSystemDefaultDevice())
        let renderer=try NativeSceneRenderer(scene: scene,device: device,assetRoots:[root])
        let queue=try #require(device.makeCommandQueue())
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:64,height:64,mipmapped:false)
        desc.usage=[.renderTarget,.shaderRead];desc.storageMode = .shared
        let target=try #require(device.makeTexture(descriptor:desc))
        for (dt,color) in [(0.0,[UInt8(255),0,0]),(0.3,[UInt8(0),0,255]),(1.2,[UInt8(255),0,0])] {
            let command=try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime:dt,into:target,commandBuffer:command)
            command.commit();command.waitUntilCompleted();#expect(command.status == .completed)
            var pixels=[UInt8](repeating:0,count:64*64*4)
            target.getBytes(&pixels,bytesPerRow:256,from:MTLRegionMake2D(0,0,64,64),mipmapLevel:0)
            func rgb(_ x: Int,_ y: Int)->[UInt8] { Array(pixels[(y*64+x)*4..<(y*64+x)*4+3]) }
            #expect(rgb(8,8) == [0,255,0])
            #expect(rgb(24,8) == [255,255,0])
            #expect(rgb(40,8) == color)
            #expect(rgb(56,8) == color)
        }
    }

    @Test func decoderSelectsPagesAndRejectsOutOfRangeIndices() throws {
        let device=try #require(MTLCreateSystemDefaultDevice())
        let data=texture()
        guard case .texture(let page)? = WETexDecoder.contents(data:data,device:device,imageIndex:1) else {
            Issue.record("Second animation image page did not decode");return
        }
        #expect(page.texture.width == 8 && page.texture.height == 4)
        var pixels=[UInt8](repeating:0,count:8*4*4)
        page.texture.getBytes(&pixels,bytesPerRow:32,from:MTLRegionMake2D(0,0,8,4),mipmapLevel:0)
        #expect(Array(pixels[0..<4]) == [0,255,0,255])
        #expect(Array(pixels[96..<100]) == [255,255,0,255])
        #expect(WETexDecoder.contents(data:data,device:device,imageIndex:-1) == nil)
        #expect(WETexDecoder.contents(data:data,device:device,imageIndex:2) == nil)
        #expect(WETexDecoder.contents(data:data.prefix(90),device:device,imageIndex:1) == nil)
    }

    private func fixture(effectCount: Int, autoCombo: Bool) throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("WEImageAnimation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("shaders"),withIntermediateDirectories:true)
        func json(_ name: String,_ value: Any) throws { try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent(name)) }
        try json("project.json",["type":"scene","file":"scene.json"])
        try json("scene.json",["camera":["eye":"0 0 0","center":"0 0 -1","up":"0 1 0"],
            "general":["orthogonalprojection":["width":64,"height":64],"clearcolor":"0 0 0"],"objects":[
                ["id":1,"image":"model.json","origin":"16 48 0","alpha":["value":1,"script":"export function init(value) { const animation=thisLayer.getTextureAnimation(); animation.stop(); animation.setFrame(2); return value; }"],
                 "effects":(0..<effectCount).map { ["id":$0,"file":"effect.json"] }],
                ["id":2,"image":"model.json","origin":"48 48 0"],
            ]])
        try json("model.json",["material":"material.json","width":32,"height":32])
        try json("material.json",["passes":[["shader":autoCombo ? "genericimage-test" : "copy","textures":["frames.tex"],"blending":"normal"]]])
        try json("effect.json",["passes":[["material":"effect-material.json"]]])
        try json("effect-material.json",["passes":[["shader":"copy","blending":"normal"]]])
        try """
        attribute vec3 a_Position; attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec4 g_Texture0Rotation; uniform vec2 g_Texture0Translation;
        varying vec2 v_TexCoord;
        void main() { v_TexCoord=g_Texture0Translation + a_TexCoord.x*g_Texture0Rotation.xy + a_TexCoord.y*g_Texture0Rotation.zw;
            gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0); }
        """.write(to:root.appendingPathComponent("shaders/copy.vert"),atomically:true,encoding:.utf8)
        try """
        uniform sampler2D g_Texture0; varying vec2 v_TexCoord;
        void main() { gl_FragColor=texSample2D(g_Texture0,v_TexCoord); }
        """.write(to:root.appendingPathComponent("shaders/copy.frag"),atomically:true,encoding:.utf8)
        let vertex = try String(contentsOf: root.appendingPathComponent("shaders/copy.vert"), encoding: .utf8)
            .replacingOccurrences(of: "void main() { v_TexCoord=", with: "void main() {\n#if SPRITESHEET\nv_TexCoord=")
            .replacingOccurrences(of: "gl_Position=", with: "\n#else\nv_TexCoord=a_TexCoord;\n#endif\ngl_Position=")
        try vertex.write(to: root.appendingPathComponent("shaders/genericimage-test.vert"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.frag"),
                                        to: root.appendingPathComponent("shaders/genericimage-test.frag"))
        try texture().write(to:root.appendingPathComponent("frames.tex"));return root
    }

    private func texture() -> Data {
        var data=Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) { var value=value.littleEndian;withUnsafeBytes(of:&value) { data.append(contentsOf:$0) } }
        // Real frame width is four, while storage is eight: never crop away
        // the right-hand frame of an animated texture page.
        [0,6,8,4,4,4,0].forEach { word(UInt32($0)) }
        data.append(Data("TEXB0001\0".utf8));word(2)
        for page in 0..<2 {
            word(2);word(8);word(4);word(128)
            for y in 0..<4 { for x in 0..<8 {
                let rgba:[UInt8] = page == 0 ? (x<4 ? [255,0,0,255] : [0,0,255,255])
                    : (y<2 ? [0,255,0,255] : [255,255,0,255])
                data.append(contentsOf:rgba)
            } }
            word(4);word(2);word(32);data.append(Data(repeating:0,count:32))
        }
        data.append(Data("TEXS0003\0".utf8));word(3);word(4);word(4)
        word(0);[Float(0.25),0,0,4,0,0,4].forEach { word($0.bitPattern) }
        word(0);[Float(0.75),4,0,4,0,0,4].forEach { word($0.bitPattern) }
        word(1);[Float(0.5),4,0,0,4,-4,0].forEach { word($0.bitPattern) }
        return data
    }
}
