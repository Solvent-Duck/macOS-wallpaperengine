import AppKit
import AVFoundation
import ImageIO
import NativeSceneCore
import Testing
import WebKit
@testable import WallpaperEngine

/// Lead-only GPU/WebKit checks. Synthetic PCM crosses the real audio controller
/// and renderer APIs; these do not claim to establish live system capture.
@MainActor
@Suite(.serialized)
struct AudioRendererDeliveryTests {
    @Test func pcmDrivesAuthoredSceneVisibilityAndStopClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioScene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        try json("project.json", ["type":"scene", "file":"scene.json", "general":["supportsaudioprocessing":true]])
        try json("scene.json", ["camera":[:],"general":["orthogonalprojection":["width":8,"height":8],"clearcolor":"0 0 0"],
            "objects":[["id":1,"image":"model.json","origin":"4 4 0","visible":["value":true,"script":"""
                const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64);
                export function update() { return audio.average.some(value => value > 0.1); }
                """]]]])
        try json("model.json", ["material":"material.json","width":8,"height":8])
        try json("material.json", ["passes":[["shader":"red","blending":"normal"]]])
        try "attribute vec3 a_Position; uniform mat4 g_ModelViewProjectionMatrix; void main() { gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1); }"
            .write(to: root.appendingPathComponent("shaders/red.vert"), atomically: true, encoding: .utf8)
        try "void main() { gl_FragColor=vec4(1,0,0,1); }"
            .write(to: root.appendingPathComponent("shaders/red.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let renderer = SceneRenderer(directoryURL: root, sceneDescription: scene)
        defer { renderer.stop() }
        let suite = "AudioSceneDelivery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = PCMSource()
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false, factory: { _ in input })
        defer { controller.stop() }
        renderer.play()
        controller.start { renderer.receiveAudioData($0) }
        try await waitFor { controller.isRunning }
        #expect(try await redPixel(renderer, root: root, name: "silence") < 5)
        try input.tone()
        controller.deliver()
        #expect(try await redPixel(renderer, root: root, name: "tone") > 250)
        controller.stop()
        #expect(try await redPixel(renderer, root: root, name: "stopped") < 5)
    }

    @Test func pcmReachesWebAudioListenerAndUpdatesVisibleStyle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioWeb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try """
        <!doctype html><html><body style="background:black"><script>
        wallpaperRegisterAudioListener(function(bands) {
            window.lastBands=bands;
            document.body.style.backgroundColor=Math.max(...bands)>0.1?'rgb(255, 0, 0)':'rgb(0, 0, 0)';
        });
        window.wallpaperPropertyListener={applyUserProperties(){window.ready=true;}};
        </script></body></html>
        """.write(to: file, atomically: true, encoding: .utf8)
        let renderer = WebRenderer(fileURL: file)
        let web = try #require(renderer.view as? WKWebView)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:64,height:64), styleMask:[.borderless], backing:.buffered, defer:false)
        window.contentView = web; window.orderBack(nil)
        defer { renderer.stop(); window.orderOut(nil) }
        renderer.play()
        try await waitFor { (try? await web.evaluateJavaScript("window.ready === true")) as? Bool == true }
        let suite = "AudioWebDelivery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let input = PCMSource()
        let controller = AudioReactivity(defaults:defaults, automaticallyDelivers:false, factory:{ _ in input })
        defer { controller.stop() }
        controller.start { renderer.receiveAudioData($0) }
        try await waitFor { controller.isRunning }
        try input.tone(); controller.deliver()
        try await waitFor { (try? await web.evaluateJavaScript("lastBands.length === 128 && document.body.style.backgroundColor === 'rgb(255, 0, 0)'")) as? Bool == true }
        controller.stop()
        try await waitFor { (try? await web.evaluateJavaScript("lastBands.every(x=>x===0) && document.body.style.backgroundColor === 'rgb(0, 0, 0)'")) as? Bool == true }
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        try #require(await condition(), "Audio delivery did not reach the renderer")
    }

    private func redPixel(_ renderer:SceneRenderer, root:URL, name:String) async throws -> UInt8 {
        let file=root.appendingPathComponent("\(name).png")
        var result: Result<Void,Error>?
        renderer.requestScreenshot(outputURL:file,afterFrames:3) { result=$0 }
        try await waitFor { result != nil }
        try result?.get()
        let source=try #require(CGImageSourceCreateWithURL(file as CFURL,nil))
        let image=try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
        var pixel=[UInt8](repeating:0,count:4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context=try #require(CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
        }
        return pixel[0]
    }
}

@MainActor
private final class PCMSource: AudioCaptureSession {
    private var samples:(@Sendable (StereoAudioSamples)->Void)?
    func start(samples:@escaping @Sendable (StereoAudioSamples)->Void, invalidated:@escaping @Sendable ()->Void) async throws { self.samples=samples }
    func stop() { samples=nil }
    func tone() throws {
        let format=try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:true))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2048));buffer.frameLength=2048
        let values=try #require(buffer.floatChannelData)[0]
        for frame in 0..<2048 {
            let value=0.5*sin(Float(frame*32)*2 * .pi/2048)
            values[frame*2]=value;values[frame*2+1]=value
        }
        let decoder=try AudioPCMDecoder(format:format.streamDescription.pointee)
        samples?(try #require(decoder.stereo(buffer.audioBufferList)))
    }
}
