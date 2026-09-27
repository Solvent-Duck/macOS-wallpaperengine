import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct VideoTexturePlayerTests {
    @Test func selectsFramesAtOrBeforeRequestedTimeWithoutRestartingForwardPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoTexturePlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movieURL = root.appendingPathComponent("colors.mp4")
        try await writeColorMovie(to: movieURL, frames: [
            ColorFrame(.red, presentationTime: 0, duration: 0.25),
            ColorFrame(.green, presentationTime: 0.25, duration: 0.25),
            ColorFrame(.blue, presentationTime: 0.50, duration: 0.25),
            ColorFrame(.yellow, presentationTime: 0.75, duration: 0.25),
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let player = try #require(VideoTexturePlayer(
            payload: WETexVideoPayload(data: try Data(contentsOf: movieURL), imageWidth: 16, imageHeight: 16, clampUVs: false, pointSampling: false),
            cacheURL: root.appendingPathComponent("cached.mp4"),
            device: device
        ))
        let textureIdentity = ObjectIdentifier(player.texture)

        // A frame at zero is present immediately, before the first render.
        #expect(dominantChannel(in: player.texture) == .red)
        #expect(player.readerRestartCount == 1)

        player.advance(to: 0.10)
        #expect(dominantChannel(in: player.texture) == .red)
        #expect(player.readerRestartCount == 1)
        player.advance(to: 0.24)
        #expect(dominantChannel(in: player.texture) == .red)
        #expect(player.readerRestartCount == 1)
        player.advance(to: 0.25) // Exact frame boundary.
        #expect(dominantChannel(in: player.texture) == .green)
        #expect(player.readerRestartCount == 1)

        player.advance(to: 0.63) // Skip over the 0.50 frame boundary.
        #expect(dominantChannel(in: player.texture) == .blue)
        #expect(player.readerRestartCount == 1)
        player.advance(to: 0.63) // Paused/repeated scene time.
        #expect(dominantChannel(in: player.texture) == .blue)
        #expect(player.readerRestartCount == 1)
        #expect(ObjectIdentifier(player.texture) == textureIdentity)

        player.advance(to: 0.90) // EOF holds the final 0.75 yellow frame.
        #expect(dominantChannel(in: player.texture) == .yellow)
        #expect(player.readerRestartCount == 1)
        player.advance(to: .nan)
        player.advance(to: .infinity)
        #expect(dominantChannel(in: player.texture) == .yellow)
        #expect(player.readerRestartCount == 1)

        player.advance(to: 0.25) // Explicit backward seek recreates the reader.
        #expect(dominantChannel(in: player.texture) == .green)
        #expect(player.readerRestartCount == 2)

        player.advance(to: 0.90)
        player.advance(to: 1.0) // Loop rollover recreates the reader and returns to frame zero.
        #expect(dominantChannel(in: player.texture) == .red)
        #expect(player.readerRestartCount == 3)
    }

    @Test func handlesIrregularFrameIntervals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoTexturePlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movieURL = root.appendingPathComponent("irregular.mp4")
        try await writeColorMovie(to: movieURL, frames: [
            ColorFrame(.red, presentationTime: 0, duration: 0.375),
            ColorFrame(.green, presentationTime: 0.375, duration: 0.125),
            ColorFrame(.blue, presentationTime: 0.50, duration: 0.30),
            ColorFrame(.yellow, presentationTime: 0.80, duration: 0.20),
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let player = try #require(VideoTexturePlayer(
            payload: WETexVideoPayload(data: try Data(contentsOf: movieURL), imageWidth: 16, imageHeight: 16, clampUVs: false, pointSampling: false),
            cacheURL: root.appendingPathComponent("cached.mp4"),
            device: device
        ))

        // The next sample is at 0.375, so requests before it must retain red.
        #expect(dominantChannel(in: player.texture) == .red)
        player.advance(to: 0.05)
        player.advance(to: 0.10)
        #expect(dominantChannel(in: player.texture) == .red)
        #expect(player.readerRestartCount == 1)
        player.advance(to: 0.30)
        #expect(dominantChannel(in: player.texture) == .red)
        player.advance(to: 0.375)
        #expect(dominantChannel(in: player.texture) == .green)
        player.advance(to: 0.49)
        #expect(dominantChannel(in: player.texture) == .green)
        player.advance(to: 0.50)
        #expect(dominantChannel(in: player.texture) == .blue)
        #expect(player.readerRestartCount == 1)

        // EOF retains the final frame for both advancing and repeated requests.
        player.advance(to: 0.99)
        #expect(dominantChannel(in: player.texture) == .yellow)
        player.advance(to: 0.99)
        #expect(dominantChannel(in: player.texture) == .yellow)
        #expect(player.readerRestartCount == 1)

        // A reverse request restarts so selection is again based on PTS, then
        // the one-second loop boundary restarts at the first frame.
        player.advance(to: 0.49)
        #expect(dominantChannel(in: player.texture) == .green)
        #expect(player.readerRestartCount == 2)
        player.advance(to: 1.02)
        #expect(dominantChannel(in: player.texture) == .red)
        #expect(player.readerRestartCount == 3)
    }

    @Test func scriptControlsSampleIndependentLayersAndHoldTheFinalFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoTransportRender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("colors.mp4")
        try await writeColorMovie(to: movie, frames: [
            ColorFrame(.red, presentationTime: 0, duration: 0.25),
            ColorFrame(.green, presentationTime: 0.25, duration: 0.25),
            ColorFrame(.blue, presentationTime: 0.5, duration: 0.25),
            ColorFrame(.yellow, presentationTime: 0.75, duration: 0.25),
        ])
        let payload = try Data(contentsOf: movie)
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { tex.append(contentsOf: $0) } }
        [0,2,16,16,16,16,0].forEach { word(UInt32($0)) }
        tex.append(Data("TEXB0003\0".utf8)); word(1); word(UInt32.max)
        word(1); word(16); word(16); word(0); word(UInt32(payload.count)); word(UInt32(payload.count)); tex.append(payload)
        try tex.write(to: root.appendingPathComponent("video.tex"))
        func json(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        try json("project.json", ["type":"scene", "file":"scene.json"])
        try json("scene.json", ["camera":["eye":"0 0 0", "center":"0 0 -1", "up":"0 1 0"],
            "general":["orthogonalprojection":["width":96,"height":32],"clearcolor":"0 0 0"],
            "objects":[
                ["id":1,"image":"model.json","origin":"16 16 0", "effects":[["id":1,"file":"effect.json"]],
                 "alpha":["value":1,"script": """
                 let video, frame = 0;
                 export function init(value) {
                     video = thisLayer.getVideoTexture();
                     if (video !== thisLayer.getVideoTexture() || Math.abs(video.duration - 1) > 0.01) throw new Error('metadata');
                     video.stop(); video.setCurrentTime(0.25); video.rate = 2;
                     return value;
                 }
                 export function update(value) {
                     frame++;
                     if (frame === 2) video.play();
                     if (frame === 3) video.pause();
                     if (frame === 4) video.setCurrentTime(0.5);
                     return video.isPlaying() === (frame === 2) ? value : 0;
                 }
                 """]],
                ["id":2,"image":"model.json","origin":"48 16 0", "alpha":["value":1,"script": """
                 let video, ended = 0;
                 export function init(value) {
                     video = thisLayer.getVideoTexture(); video.loop = false;
                     video.addEndedCallback(() => { ended++; if (thisLayer.name !== 'finite') throw new Error('callback owner'); });
                     return value;
                 }
                 export function update(value) {
                     if (engine.runtime >= 1 && (ended !== 1 || video.isPlaying() || video.getCurrentTime() !== video.duration)) return 0;
                     return value;
                 }
                 """], "name":"finite"],
                ["id":3,"image":"model.json","origin":"80 16 0"],
            ]])
        try json("model.json", ["material":"material.json","width":32,"height":32])
        try json("material.json", ["passes":[["shader":"copy","textures":["video.tex"],"blending":"normal"]]])
        try json("effect.json", ["passes":[["material":"effect-material.json"]]])
        try json("effect-material.json", ["passes":[["shader":"copy","blending":"normal"]]])
        try """
        attribute vec3 a_Position; attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix; varying vec2 v_TexCoord;
        void main() { v_TexCoord=a_TexCoord; gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0); }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0; varying vec2 v_TexCoord;
        void main() { gl_FragColor=texSample2D(g_Texture0,v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96, height: 32, mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let expected: [[Channel]] = [[.green,.red,.red], [.green,.green,.green], [.yellow,.blue,.blue],
                                     [.blue,.yellow,.yellow], [.blue,.yellow,.red], [.blue,.yellow,.green]]
        let firstLayerTimes = [0.25, 0.25, 0.75, 0.5, 0.5, 0.5]
        for (index, colors) in expected.enumerated() {
            let command = try #require(queue.makeCommandBuffer())
            let packet = try renderer.renderNextFrame(deltaTime: index == 0 ? 0 : 0.25, into: target, commandBuffer: command)
            #expect(packet.nodes.first(where: { $0.nodeID.rawValue == 1 })?.videoTextureTime == firstLayerTimes[index])
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            #expect(command.status == .completed)
            for (layer, color) in colors.enumerated() {
                #expect(dominantChannel(in: target, x: 16 + layer * 32, y: 16) == color, "frame \(index), layer \(layer)")
            }
        }

        // The same movie/effect path must release private decoders and text
        // textures when IDs are replaced every frame, rather than accumulate.
        try json("scene.json", ["camera":[:],
            "general":["orthogonalprojection":["width":96,"height":32],"clearcolor":"0 0 0"],
            "objects":[["id":1,"image":"model.json","visible":["value":false,"script":"""
                let frame = 0;
                export function update() {
                    if (frame++ < 12) {
                        const movie = thisScene.createLayer({image:'model.json',origin:[16,16,0],effects:[{id:1,file:'effect.json'}]});
                        const video = movie.getVideoTexture(); video.pause(); video.setCurrentTime(0.25);
                        const label = thisScene.createLayer({text:'X',pointsize:18,origin:[60,16,0]});
                        thisScene.destroyLayer(movie); thisScene.destroyLayer(label);
                    }
                    return false;
                }
                """]]]])
        let dynamicScene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let dynamicRenderer = try NativeSceneRenderer(scene: dynamicScene, device: device, assetRoots: [root])
        for index in 0..<13 {
            let command = try #require(queue.makeCommandBuffer())
            let packet = try dynamicRenderer.renderNextFrame(deltaTime: 0.01, into: target, commandBuffer: command)
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            #expect(packet.nodes.count == (index < 12 ? 3 : 1))
            #expect(dynamicRenderer.layerResourceCounts.video == (index < 12 ? 1 : 0))
            #expect(dynamicRenderer.layerResourceCounts.text == (index < 12 ? 1 : 0))
            #expect(dominantChannel(in: target, x: 16, y: 16) == (index < 12 ? .green : nil))
        }
    }

    private enum Channel { case red, green, blue, yellow }

    private struct ColorFrame {
        let channel: Channel
        let presentationTime: Double
        let duration: Double

        init(_ channel: Channel, presentationTime: Double, duration: Double) {
            self.channel = channel
            self.presentationTime = presentationTime
            self.duration = duration
        }
    }

    private func dominantChannel(in texture: MTLTexture, x: Int = 0, y: Int = 0) -> Channel? {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        let red = pixel[2]
        let green = pixel[1]
        let blue = pixel[0]
        guard max(red, green, blue) > 64 else { return nil }
        let (r, g, b) = (Int(red), Int(green), Int(blue))
        if r > b + 32, g > b + 32, abs(r - g) < 64 { return .yellow }
        if r > g + 32, r > b + 32 { return .red }
        if g > r + 32, g > b + 32 { return .green }
        if b > r + 32, b > g + 32 { return .blue }
        return nil
    }

    private func writeColorMovie(to url: URL, frames: [ColorFrame]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 1,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw VideoTestError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoTestError.cannotStartWriter }
        writer.startSession(atSourceTime: .zero)

        for frame in frames {
            try await waitUntilReady(input)
            let color = rgb(for: frame.channel)
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { throw VideoTestError.cannotCreatePixelBuffer }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<16 {
                for x in 0..<16 {
                    let offset = y * stride + x * 4
                    bytes[offset] = color.2
                    bytes[offset + 1] = color.1
                    bytes[offset + 2] = color.0
                    bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
                  let format else { throw VideoTestError.cannotCreateFormat }
            var timing = CMSampleTimingInfo(
                duration: CMTime(seconds: frame.duration, preferredTimescale: 1_000),
                presentationTimeStamp: CMTime(seconds: frame.presentationTime, preferredTimescale: 1_000),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            guard CMSampleBufferCreateForImageBuffer(
                allocator: nil,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr, let sampleBuffer else { throw VideoTestError.cannotCreateSample }
            guard input.append(sampleBuffer) else {
                throw writer.error ?? VideoTestError.cannotAppendFrame
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoTestError.cannotFinishWriter }
    }

    private func rgb(for channel: Channel) -> (UInt8, UInt8, UInt8) {
        switch channel {
        case .red: return (255, 0, 0)
        case .green: return (0, 255, 0)
        case .blue: return (0, 0, 255)
        case .yellow: return (255, 255, 0)
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        // AVAssetWriter can apply back pressure even for this tiny fixture.
        // Allow a bounded wall-clock interval for the encoder to consume input.
        for _ in 0..<500 {
            if input.isReadyForMoreMediaData { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VideoTestError.inputNotReady
    }

    private enum VideoTestError: Error {
        case cannotAddInput, cannotStartWriter, cannotCreatePixelBuffer, cannotCreateFormat, cannotCreateSample, cannotAppendFrame, cannotFinishWriter, inputNotReady
    }
}
