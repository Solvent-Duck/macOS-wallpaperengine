import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct CursorTransitionRenderingTests {
    @Test func clickBurstsReachCallbacksWithoutExtraUpdates() throws {
        try withRenderer { renderer, render in
            let center = CGPoint(x: 0.5, y: 0.5)
            renderer.updateCursorInput(center, leftDown: false)
            _ = try render()
            for _ in 0..<3 {
                renderer.updateCursorInput(center, leftDown: true)
                renderer.updateCursorInput(center, leftDown: false)
            }
            let frame = try render()
            #expect(frame.texts.first(where: { $0.nodeID.rawValue == 2 })?.content == "3:2:3")
            #expect(try render().texts.first(where: { $0.nodeID.rawValue == 2 })?.content == "3:3:3")
        }
    }

    @Test func cancellationDoesNotReplayPendingClicks() throws {
        try withRenderer { renderer, render in
            let center = CGPoint(x: 0.5, y: 0.5)
            renderer.updateCursorInput(center, leftDown: false)
            _ = try render()
            renderer.updateCursorInput(center, leftDown: true)
            _ = try render()
            renderer.updateCursorInput(center, leftDown: false)
            renderer.cancelCursorInteraction()
            let frame = try render()
            #expect(frame.texts.first(where: { $0.nodeID.rawValue == 2 })?.content == "0:3:1")
        }
    }

    @Test func aNewClickAfterCancellationIsPreserved() throws {
        try withRenderer { renderer, render in
            let center = CGPoint(x: 0.5, y: 0.5)
            renderer.updateCursorInput(center, leftDown: false)
            _ = try render()
            renderer.cancelCursorInteraction()
            renderer.updateCursorInput(center, leftDown: true)
            renderer.updateCursorInput(center, leftDown: false)
            #expect(try render().texts.first(where: { $0.nodeID.rawValue == 2 })?.content == "1:2:1")
        }
    }

    private func withRenderer(_ body: (NativeSceneRenderer, () throws -> FramePacket) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WECursorTransition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        export function init() { shared.clicks = 0; shared.updates = 0; shared.releases = 0; }
        export function cursorClick() { shared.clicks++; }
        export function cursorUp() { shared.releases++; }
        export function update() { shared.updates++; }
        """
        let sceneJSON: [String:Any] = ["camera":[:], "general":["orthogonalprojection":["width":64,"height":64]],
            "objects":[["id":1,"text":"BUTTON","origin":"32 32 0","pointsize":10,"horizontalalign":"center","verticalalign":"center","visible":["value":true,"script":script]],
                       ["id":2,"text":["value":"","script":"export function update() { return shared.clicks + ':' + shared.updates + ':' + shared.releases; }"],"pointsize":4,"origin":"1 1 0"]]]
        for (name,value) in ["project.json":["type":"scene","file":"scene.json"],"scene.json":sceneJSON] as [String:Any] {
            try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent(name))
        }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath:root.path,assetsPath:root.path)
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene:scene,device:device,assetRoots:[root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:64,height:64,mipmapped:false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor:descriptor))
        func render() throws -> FramePacket {
            let command = try #require(queue.makeCommandBuffer())
            let packet = try renderer.renderNextFrame(deltaTime:1/30,into:texture,commandBuffer:command)
            command.commit();command.waitUntilCompleted()
            #expect(command.status == .completed)
            return packet
        }
        try body(renderer,render)
    }
}
