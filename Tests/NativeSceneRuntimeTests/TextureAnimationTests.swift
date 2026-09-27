import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct TextureAnimationTests {
    @Test func packedFramesPreservePageRotationAndUnevenTiming() throws {
        let animation = try #require(TextureAnimation.decode(texture()))
        #expect(animation.frames.count == 2 && animation.duration == 1)
        #expect(animation.frames[1].imageIndex == 1)
        #expect(animation.frames[1].translation == SIMD2<Float>(0.5,0))
        #expect(animation.frames[1].rotation == SIMD4<Float>(0,1,-0.5,0))
        #expect([0.0,0.24,0.25,0.99,1.0,-0.1].map(animation.frameIndex) == [0,0,1,1,0,1])
        #expect(animation.time(atFrame: 1) == 0.25)
        #expect(abs(animation.frame(at: 0.625)-1.5) < 0.00001)
        for count in [0,8,18,55,texture().count-1] { #expect(TextureAnimation.decode(texture().prefix(count)) == nil) }
        var malformed=texture(); malformed[malformed.count-32]=2
        #expect(TextureAnimation.decode(malformed) == nil)
    }

    @Test func playbackDetachesPreservesPhaseAndRejoinsTheSharedClock() throws {
        var animation = SceneTextureAnimation(descriptor: try #require(TextureAnimation.decode(texture())))
        animation.advance(0.5,sharedTime: 0.5)
        animation.apply(["action":"pause"],sharedTime: 0.5)
        animation.advance(0.5,sharedTime: 1)
        #expect(animation.time == 0.5 && !animation.playing && !animation.joined)
        animation.apply(["action":"rate","rate":-2.0],sharedTime: 1)
        animation.apply(["action":"play"],sharedTime: 1)
        animation.advance(0.1,sharedTime: 1.1)
        #expect(abs(animation.time-0.3) < 0.00001)
        animation.apply(["action":"stop"],sharedTime: 1.1)
        #expect(animation.time == 0 && !animation.playing)
        animation.apply(["action":"setFrame","frame":1.0],sharedTime: 1.1)
        #expect(animation.time == 0.25 && !animation.playing)
        animation.apply(["action":"join"],sharedTime: 1.1)
        #expect(animation.joined && animation.playing && animation.rate == 1 && animation.time == 1.1)
    }

    @Test func layerControlsDriveFramePacketsIndependentlyForSharedTextures() throws {
        let root = try fixture(script: """
        let animation, count=0;
        export function init(value) {
            animation=thisLayer.getTextureAnimation();
            if (animation !== thisLayer.getTextureAnimation() || animation.frameCount !== 2 || animation.duration !== 1) throw new Error('texture metadata');
            animation.stop(); animation.setFrame(1); return value;
        }
        export function update(value) {
            count++;
            if (count === 2) { animation.rate=-1; animation.play(); }
            if (count === 3) animation.join();
            return value;
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene, textureAnimations: TextureAnimationLibrary(assetRoots: [root]))
        for expected: Double in [0.25,0.25,0.3,0.4] {
            let packet=runtime.step(deltaTime: 0.1)
            #expect(abs(try #require(packet.nodes[0].textureAnimationTime)-expected) < 0.00001)
            #expect(packet.nodes[1].textureAnimationTime == packet.timing.elapsedTime)
        }
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 10).nodes[0].textureAnimationTime == 0.4)
    }

    @Test func nonfiniteFramesAndRatesAreIgnoredAndSeeksClamp() throws {
        var animation = SceneTextureAnimation(descriptor: try #require(TextureAnimation.decode(texture())))
        animation.apply(["action":"setFrame","frame":Double.infinity],sharedTime: 0)
        animation.apply(["action":"rate","rate":Double.nan],sharedTime: 0)
        #expect(animation.time == 0 && animation.rate == 1)
        animation.apply(["action":"setFrame","frame":20.0],sharedTime: 0)
        #expect(animation.time == 0.25)
        animation.apply(["action":"setFrame","frame":-10.0],sharedTime: 0)
        #expect(animation.time == 0)
    }

    private func fixture(script: String) throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("WETexturePlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func json(_ name: String,_ value: Any) throws { try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name)) }
        try json("project.json",["type":"scene","file":"scene.json"])
        try json("scene.json",["camera":[:],"general":[:],"objects":[
            ["id":1,"image":"model.json","alpha":["value":1,"script":script]],
            ["id":2,"image":"model.json"],
        ]])
        try json("model.json",["material":"material.json"])
        try json("material.json",["passes":[["shader":"genericimage","textures":["frames.tex"]]]])
        try texture().write(to: root.appendingPathComponent("frames.tex")); return root
    }

    private func texture() -> Data {
        var data=Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) { var value=value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf:$0) } }
        [0,6,8,4,8,4,0].forEach { word(UInt32($0)) }
        data.append(Data("TEXB0001\0".utf8)); word(2)
        for _ in 0..<2 { word(1); word(8); word(4); word(128); data.append(Data(repeating:255,count:128)) }
        data.append(Data("TEXS0003\0".utf8)); word(2); word(4); word(4)
        word(0); [Float(0.25),0,0,4,0,0,4].forEach { word($0.bitPattern) }
        word(1); [Float(0.75),4,0,0,4,-4,0].forEach { word($0.bitPattern) }
        return data
    }
}
