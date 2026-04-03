import AppKit
import Foundation
import Metal
import MetalKit
import QuartzCore
import CoreVideo
import CWEBridge

/// Renders Wallpaper Engine scene wallpapers through the embedded native bridge using Metal.
///
/// Uses `WEBridge.h` to talk to the embedded scene runtime, which handles scene parsing,
/// shader compilation, and frame rendering into `MTLTexture` objects that are blitted into
/// an `MTKView`.
///
/// ## Performance
/// - Rendering is driven by a CVDisplayLink capped at 30fps.
/// - When paused, the CVDisplayLink is stopped entirely (zero GPU cost).
/// - No pixel readback: the engine texture is blitted directly (zero-copy Metal path).
@MainActor
class SceneRenderer: WallpaperRenderer {
    let view: NSView
    private let wallpaperPath: String
    private var context: WEContextRef?
    private var metalView: SceneMetalView?
    private var displayLink: CVDisplayLink?
    private var lastRenderTime: Double = 0
    private var isPlaying = false
    private var consecutiveZeroTextureFrames = 0
    private let zeroTextureThreshold = 10
    private(set) var needsRecovery = false
    private var renderedFrameCount = 0
    private var screenshotRequest: ScreenshotRequest?
    private var benchmarkRequest: BenchmarkRequest?

    // Shared Metal device and command queue (created once, reused across context recreations).
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private struct ScreenshotRequest {
        let targetFrame: Int
        let outputURL: URL
        let completion: (Result<Void, Error>) -> Void
    }

    private struct BenchmarkRequest {
        let deadline: CFTimeInterval
        let outputURL: URL
        let completion: (Result<Void, Error>) -> Void
    }

    /// Default path to Wallpaper Engine's shared assets directory.
    /// Users can override this via UserDefaults "WEAssetsPath".
    private static var assetsPath: String {
        if let custom = UserDefaults.standard.string(forKey: "WEAssetsPath"), !custom.isEmpty {
            return custom
        }
        let candidates = [
            NSHomeDirectory() + "/wallpaper_engine/assets",
            NSHomeDirectory() + "/Library/Application Support/wallpaper_engine/assets",
            NSHomeDirectory() + "/.local/share/wallpaper_engine/assets",
            "/usr/local/share/wallpaper_engine/assets",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return candidates[0]
    }

    init(directoryURL: URL) {
        self.wallpaperPath = directoryURL.path

        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("[SceneRenderer] No Metal device available")
        }
        guard let queue = dev.makeCommandQueue() else {
            fatalError("[SceneRenderer] Failed to create MTLCommandQueue")
        }
        self.device = dev
        self.commandQueue = queue

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        self.view = container
    }

    func play() {
        if isPlaying { return }

        let frame = view.bounds.isEmpty ? NSRect(x: 0, y: 0, width: 1920, height: 1080) : view.bounds
        let width  = Int32(frame.width)
        let height = Int32(frame.height)

        if context == nil {
            print("[SceneRenderer] Creating Metal engine context: \(width)x\(height), assets: \(Self.assetsPath)")

            let devicePtr       = Unmanaged.passUnretained(device).toOpaque()
            let commandQueuePtr = Unmanaged.passUnretained(commandQueue).toOpaque()

            guard let ctx = we_create_context_metal(
                wallpaperPath, Self.assetsPath, width, height,
                devicePtr, commandQueuePtr
            ) else {
                print("[SceneRenderer] Failed to create Metal engine context for: \(wallpaperPath)")
                showError("Failed to initialize scene renderer")
                return
            }
            context = ctx
            print("[SceneRenderer] Metal engine context created successfully")

            setupMetalView(engineContext: ctx)
        }

        we_set_paused(context, 0)
        startDisplayLink()
        isPlaying = true
        print("[SceneRenderer] Playing: \(wallpaperPath)")
    }

    func pause() {
        guard isPlaying else { return }
        stopDisplayLink()
        we_set_paused(context, 1)
        isPlaying = false
        print("[SceneRenderer] Paused")
    }

    func stop() {
        stopDisplayLink()
        if let ctx = context {
            we_destroy_context(ctx)
            context = nil
        }
        metalView?.removeFromSuperview()
        metalView = nil
        isPlaying = false
        print("[SceneRenderer] Stopped")
    }

    func updateCursorPosition(_ position: NSPoint) {
        guard let ctx = context else { return }
        we_set_mouse_position(ctx, Float(position.x), Float(position.y))
    }

    var supportsAudio: Bool { true }

    var isMuted: Bool = true {
        didSet {}
    }

    func applyProperties(_ properties: [WallpaperProperty], values: [String: String]) {
        guard let ctx = context else { return }
        for prop in properties {
            let value = values[prop.key] ?? prop.defaultValue
            we_set_property(ctx, prop.key, value)
        }
    }

    func applyProperty(_ property: WallpaperProperty, value: String) {
        guard let ctx = context else { return }
        we_set_property(ctx, property.key, value)
    }

    func receiveAudioData(_ data: [Float]) {
        guard let ctx = context, isPlaying else { return }
        data.withUnsafeBufferPointer { ptr in
            we_set_audio_data(ctx, ptr.baseAddress, Int32(ptr.count))
        }
    }

    func recoverFromSleep() {
        print("[SceneRenderer] Recovering from sleep — destroying and recreating context")
        PerformanceMonitor.shared.logEvent("SceneRenderer: sleep recovery — recreating context")
        stopDisplayLink()
        if let ctx = context {
            we_destroy_context(ctx)
            context = nil
        }
        metalView?.removeFromSuperview()
        metalView = nil
        isPlaying = false
        consecutiveZeroTextureFrames = 0
        needsRecovery = false
        play()
    }

    func requestScreenshot(outputURL: URL, afterFrames: Int = 60, completion: @escaping (Result<Void, Error>) -> Void) {
        screenshotRequest = ScreenshotRequest(
            targetFrame: renderedFrameCount + max(afterFrames, 1),
            outputURL: outputURL,
            completion: completion
        )
    }

    func requestBenchmark(outputURL: URL, duration: TimeInterval = 5, completion: @escaping (Result<Void, Error>) -> Void) {
        PerformanceMonitor.shared.resetFrameStatistics()
        benchmarkRequest = BenchmarkRequest(
            deadline: CACurrentMediaTime() + max(duration, 0.1),
            outputURL: outputURL,
            completion: completion
        )
    }

    // MARK: - Private

    private func setupMetalView(engineContext: WEContextRef) {
        let mv = SceneMetalView(frame: view.bounds, device: device, commandQueue: commandQueue)
        mv.autoresizingMask = [.width, .height]

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(mv)
        mv.frame = view.bounds

        self.metalView = mv
    }

    private func showError(_ message: String) {
        let label = NSTextField(labelWithString: "Scene wallpaper error:\n\(message)")
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        lastRenderTime = CACurrentMediaTime()

        let renderer = Unmanaged.passUnretained(self)
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let renderer = Unmanaged<SceneRenderer>.fromOpaque(userInfo).takeUnretainedValue()
            // Dispatch to the main actor — displayLinkFired() touches MTKView and
            // NSView APIs that are @MainActor-isolated. At 30 fps the dispatch
            // overhead (~1 µs) is well within budget.
            DispatchQueue.main.async { renderer.displayLinkFired() }
            return kCVReturnSuccess
        }, renderer.toOpaque())

        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    private func displayLinkFired() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastRenderTime

        // Cap at 30fps
        guard elapsed >= (1.0 / 30.0) else { return }

        let delta = elapsed
        lastRenderTime = now

        guard let ctx = context, let mv = metalView else { return }

        let renderStart = CACurrentMediaTime()
        let timing = mv.renderFrame(engineContext: ctx, deltaTime: delta)
        let totalMs = (CACurrentMediaTime() - renderStart) * 1000.0
        renderedFrameCount += 1

        PerformanceMonitor.shared.recordFrame(
            totalMs: totalMs,
            engineMs: timing.engineMs,
            blitMs: timing.blitMs,
            intervalMs: elapsed * 1000.0
        )

        if timing.gotTexture {
            consecutiveZeroTextureFrames = 0
        } else {
            consecutiveZeroTextureFrames += 1
            if consecutiveZeroTextureFrames == zeroTextureThreshold {
                print("[SceneRenderer] Warning: \(zeroTextureThreshold) consecutive frames with no texture — triggering recovery")
                PerformanceMonitor.shared.logEvent("SceneRenderer: zero-texture threshold hit")
                needsRecovery = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.needsRecovery, self.isPlaying else { return }
                    self.recoverFromSleep()
                }
            }
        }

        if let request = screenshotRequest, renderedFrameCount >= request.targetFrame {
            screenshotRequest = nil
            do {
                let report = try mv.capturePNG(to: request.outputURL)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let reportData = try encoder.encode(report)
                try reportData.write(to: request.outputURL.appendingPathExtension("json"))
                PerformanceMonitor.shared.logEvent("Screenshot captured: \(request.outputURL.path)")
                request.completion(.success(()))
            } catch {
                request.completion(.failure(error))
            }
        }

        if let request = benchmarkRequest, now >= request.deadline {
            benchmarkRequest = nil
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(PerformanceMonitor.shared.benchmarkReport())
                try FileManager.default.createDirectory(at: request.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: request.outputURL)
                PerformanceMonitor.shared.logEvent("Benchmark captured: \(request.outputURL.path)")
                request.completion(.success(()))
            } catch {
                request.completion(.failure(error))
            }
        }
    }
}

// MARK: - SceneMetalView

/// MTKView subclass that blits the engine's rendered MTLTexture to screen.
///
/// Each frame: calls `we_render_frame()` (engine commits its own command buffer with all
/// scene render passes), then blits the resulting MTLTexture to the CAMetalLayer drawable
/// via a simple fullscreen quad.
private class SceneMetalView: MTKView {
    private let commandQueue: MTLCommandQueue
    private var blitPipelineState: MTLRenderPipelineState?
    private var quadVertexBuffer: MTLBuffer?
    private var samplerState: MTLSamplerState?
    private var isSetup = false
    private var frameCount = 0
    private var lastEngineTexture: MTLTexture?

    struct FrameTiming {
        let gotTexture: Bool
        let engineMs: Double
        let blitMs: Double
    }

    init(frame: NSRect, device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.commandQueue = commandQueue
        super.init(frame: frame, device: device)
        self.clearColor = MTLClearColorMake(0, 0, 0, 1)
        self.colorPixelFormat = .rgba8Unorm
        self.framebufferOnly = false  // allow reading back if needed in future
        self.isPaused = true          // we drive rendering manually via CVDisplayLink
        self.enableSetNeedsDisplay = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func renderFrame(engineContext ctx: WEContextRef, deltaTime: Double) -> FrameTiming {
        // Step 1: Engine renders all scene passes into its own MTLTextures and commits.
        let engineStart = CACurrentMediaTime()
        we_render_frame(ctx, deltaTime)
        let engineMs = (CACurrentMediaTime() - engineStart) * 1000.0

        // Step 2: Get the engine's output texture.
        guard let texPtr = we_get_metal_texture(ctx) else {
            frameCount += 1
            return FrameTiming(gotTexture: false, engineMs: engineMs, blitMs: 0)
        }

        // texPtr is a non-owning borrow (retained by the engine's CFBO for the duration of play()).
        let engineTex = Unmanaged<AnyObject>.fromOpaque(texPtr).takeUnretainedValue() as! MTLTexture
        lastEngineTexture = engineTex

        // Step 3: Set up the blit pipeline once.
        if !isSetup {
            setupBlitPipeline()
            isSetup = true
            print("[SceneMetalView] Blit pipeline set up")
        }

        // Step 4: Blit engine texture → drawable.
        let blitStart = CACurrentMediaTime()
        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            frameCount += 1
            return FrameTiming(gotTexture: true, engineMs: engineMs, blitMs: 0)
        }

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd),
           let pso = blitPipelineState,
           let vb = quadVertexBuffer,
           let ss = samplerState {
            enc.setRenderPipelineState(pso)
            enc.setFragmentTexture(engineTex, index: 0)
            enc.setFragmentSamplerState(ss, index: 0)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()

        let blitMs = (CACurrentMediaTime() - blitStart) * 1000.0
        frameCount += 1
        return FrameTiming(gotTexture: true, engineMs: engineMs, blitMs: blitMs)
    }

    func capturePNG(to outputURL: URL) throws -> ScreenshotReport {
        guard let texture = lastEngineTexture else {
            throw TextureSnapshotError.imageCreationFailed
        }
        return try TextureSnapshot.writePNG(from: texture, using: commandQueue, to: outputURL)
    }

    // swiftlint:disable:next function_body_length
    private func setupBlitPipeline() {
        guard let device else { return }

        // Inline MSL blit shaders.
        // Vertex input: float4 (xy = NDC position, zw = UV).
        // No V-flip: Metal NDC top-left origin matches WE scene coordinates.
        let msl = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertOut blit_vert(uint vid [[vertex_id]],
                                  constant float4* verts [[buffer(0)]]) {
            VertOut out;
            out.position = float4(verts[vid].xy, 0.0, 1.0);
            out.uv       = verts[vid].zw;
            return out;
        }

        fragment float4 blit_frag(VertOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler samp          [[sampler(0)]]) {
            return tex.sample(samp, in.uv);
        }
        """

        guard let library = try? device.makeLibrary(source: msl, options: nil) else {
            print("[SceneMetalView] Failed to compile blit library")
            return
        }

        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction   = library.makeFunction(name: "blit_vert")
        psoDesc.fragmentFunction = library.makeFunction(name: "blit_frag")
        psoDesc.colorAttachments[0].pixelFormat = self.colorPixelFormat

        do {
            blitPipelineState = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch {
            print("[SceneMetalView] Failed to create blit PSO: \(error)")
            return
        }

        // Fullscreen quad: NDC xy + UV zw (triangle strip, 4 vertices).
        // UV (0,0) at top-left, (1,1) at bottom-right.
        let verts: [Float] = [
            -1,  1,  0, 0,   // top-left
            -1, -1,  0, 1,   // bottom-left
             1,  1,  1, 0,   // top-right
             1, -1,  1, 1,   // bottom-right
        ]
        quadVertexBuffer = device.makeBuffer(bytes: verts,
                                             length: MemoryLayout<Float>.size * verts.count,
                                             options: .storageModeShared)

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter    = .linear
        sampDesc.magFilter    = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: sampDesc)
    }
}
