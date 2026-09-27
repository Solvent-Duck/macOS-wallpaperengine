import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Metal
import NativeSceneBridge
import NativeSceneRenderer
import NativeSceneRuntime
import UniformTypeIdentifiers

@main
enum SceneNativeSnapshotTool {
    static func main() throws {
        let arguments = try parseArguments(CommandLine.arguments)

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fputs("Failed to create Metal device or command queue\n", stderr)
            Darwin.exit(1)
        }

        let scene = try SceneDescriptionAdapter.loadSceneDescription(
            wallpaperPath: arguments.wallpaperPath,
            assetsPath: arguments.assetsPath
        )
        let support = NativeSceneRenderer.support(scene: scene)
        if let reportLine = NativeSceneRenderer.supportReportLine(for: scene) {
            fputs("Native support report: \(reportLine)\n", stderr)
        }
        guard support.isSupported else {
            fputs("Scene is not supported by the native renderer: \(support.reason ?? "unknown")\n", stderr)
            Darwin.exit(1)
        }

        let wallpaperRoot = URL(fileURLWithPath: arguments.wallpaperPath, isDirectory: true)
        let assetsRoot = URL(fileURLWithPath: arguments.assetsPath, isDirectory: true)
        let renderer = try NativeSceneRenderer(
            scene: scene,
            device: device,
            assetRoots: [wallpaperRoot, assetsRoot] + scene.extractedRoots
        )

        // Perspective scenes have no authored orthographic dimensions. A 1x1
        // target hides their geometry and cannot provide a useful capture.
        let authoredWidth = scene.scene?.camera.projection.width ?? 0
        let authoredHeight = scene.scene?.camera.projection.height ?? 0
        let width = authoredWidth > 0 ? authoredWidth : 1920
        let height = authoredHeight > 0 ? authoredHeight : 1080
        let texture = makeRenderTarget(device: device, width: width, height: height)
        if let audio = arguments.audio { renderer.updateAudio(audio) }
        var lastPacket: FramePacket?

        for frame in 0..<arguments.frames {
            if let path = arguments.cursorPath {
                let sample = path[min(frame, path.count - 1)]
                renderer.updateCursorInput(CGPoint(x: sample.x, y: sample.y), leftDown: sample.leftDown)
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw SnapshotToolError.commandBufferCreationFailed
            }
            lastPacket = try renderer.renderNextFrame(deltaTime: arguments.deltaTime, into: texture, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        try writePNG(texture: texture, to: URL(fileURLWithPath: arguments.outputPath))
        if let path = arguments.frameReport, let packet = lastPacket {
            let initialIDs = Set(scene.nodes.map(\.id))
            let report: [String: Any] = [
                "initialNodeCount": scene.nodes.count, "finalNodeCount": packet.nodes.count,
                "createdNodes": packet.nodes.filter { !initialIDs.contains($0.nodeID) }.map { node in
                    ["id":node.nodeID.rawValue,"name":node.name,"visible":node.visible,
                     "position":[node.worldPosition.x,node.worldPosition.y,node.worldPosition.z],
                     "localScale":[node.localTransform.m11,node.localTransform.m22,node.localTransform.m33],
                     "alignment":node.imageAlignment as Any? ?? NSNull(),
                     "opacity":node.opacity as Any? ?? NSNull()] as [String: Any]
                },
                "textCount": packet.texts.count,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }

        if ProcessInfo.processInfo.environment["WE_DEBUG_STAGES"] != nil {
            let baseURL = URL(fileURLWithPath: arguments.outputPath).deletingPathExtension()
            for (index, dump) in renderer.debugStageDumps.enumerated() {
                let (label, buffer, width, height) = dump
                let sanitized = label.replacingOccurrences(of: "/", with: "_")
                let url = baseURL.appendingPathExtension("stage\(index)-\(sanitized).png")
                try? writePNG(buffer: buffer, width: width, height: height, to: url)
                fputs("stage dump: \(url.path)\n", stderr)
            }
        }
    }

    private static func writePNG(buffer: MTLBuffer, width: Int, height: Int, to url: URL) throws {
        let bytesPerRow = width * 4
        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotToolError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func parseArguments(_ arguments: [String]) throws -> (
        wallpaperPath: String,
        assetsPath: String,
        outputPath: String,
        frames: Int,
        deltaTime: Double,
        cursorPath: [CursorSample]?,
        audio: AudioInputState?,
        frameReport: String?
    ) {
        guard arguments.count >= 4 else {
            fputs("usage: SceneNativeSnapshotTool <wallpaper-directory> <assets-path> <output-png> [--frames N] [--delta-time seconds] [--cursor-path JSON-file] [--audio-state JSON-file] [--frame-report JSON-file]\n", stderr)
            Darwin.exit(2)
        }

        var frames = 1
        var deltaTime = 1.0 / 30.0
        var cursorPath: [CursorSample]?
        var audio: AudioInputState?
        var frameReport: String?
        var index = 4
        while index < arguments.count {
            switch arguments[index] {
            case "--frames":
                if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
                    frames = max(value, 1)
                }
                index += 2
            case "--delta-time":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    deltaTime = max(value, 0)
                }
                index += 2
            case "--cursor-path":
                guard index + 1 < arguments.count else { throw CursorPathError.invalidPath }
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
                let samples = try JSONDecoder().decode([CursorSample].self, from: data)
                guard !samples.isEmpty, samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw CursorPathError.invalidPath
                }
                cursorPath = samples
                index += 2
            case "--audio-state":
                guard index + 1 < arguments.count else { throw SnapshotToolError.invalidAudioState }
                let state = try JSONDecoder().decode(AudioInputState.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
                guard [state.overall,state.bass,state.mid,state.treble].allSatisfy(\.isFinite),
                      state.spectrum.count == 128, state.spectrum.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                    throw SnapshotToolError.invalidAudioState
                }
                audio = state
                index += 2
            case "--frame-report":
                guard index + 1 < arguments.count else { throw SnapshotToolError.missingFrameReport }
                frameReport = arguments[index + 1]
                index += 2
            default:
                index += 1
            }
        }

        return (arguments[1], arguments[2], arguments[3], frames, deltaTime, cursorPath, audio, frameReport)
    }

    /// One sample per rendered frame; hold the last sample when the path ends.
    /// Coordinates are normalized relative to the wallpaper, with Y increasing up.
    private struct CursorSample: Decodable {
        let x: Double
        let y: Double
        let leftDown: Bool

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            x = try values.decode(Double.self, forKey: .x)
            y = try values.decode(Double.self, forKey: .y)
            leftDown = try values.decodeIfPresent(Bool.self, forKey: .leftDown) ?? false
        }
        private enum CodingKeys: String, CodingKey { case x, y, leftDown }
    }

    private enum CursorPathError: LocalizedError {
        case invalidPath
        var errorDescription: String? { "--cursor-path requires a nonempty JSON array of finite x/y samples." }
    }

    private static func makeRenderTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    private static func writePNG(texture: MTLTexture, to url: URL) throws {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotToolError.imageEncodingFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotToolError.imageEncodingFailed
        }
    }
}

private enum SnapshotToolError: LocalizedError {
    case commandBufferCreationFailed
    case imageEncodingFailed
    case invalidAudioState
    case missingFrameReport

    var errorDescription: String? {
        switch self {
        case .commandBufferCreationFailed:
            return "Failed to allocate a Metal command buffer."
        case .imageEncodingFailed:
            return "Failed to encode the output PNG."
        case .invalidAudioState:
            return "--audio-state requires finite levels and 128 normalized spectrum bands."
        case .missingFrameReport:
            return "--frame-report requires an output JSON path."
        }
    }
}
