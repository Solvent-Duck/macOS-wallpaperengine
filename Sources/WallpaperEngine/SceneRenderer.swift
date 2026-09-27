import AppKit
import Foundation
import Metal
import MetalKit
import NativeSceneCore
import NativeSceneRenderer
import NativeSceneRuntime
import QuartzCore
import CoreVideo

/// Renders scene wallpapers through the standalone native Metal path.
///
/// ## Performance
/// - Rendering is driven by a CVDisplayLink capped at 30fps.
/// - When paused, the CVDisplayLink is stopped entirely (zero GPU cost).
/// - No pixel readback: the renderer texture is blitted directly (zero-copy Metal path).
@MainActor
class SceneRenderer: WallpaperRenderer {
    private struct RenderStartupError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    let view: NSView
    private let wallpaperPath: String
    private let wallpaperDirectoryURL: URL
    private let sceneDescription: SceneDescription?
    private let scriptStorage: SceneScriptStorage?
    private let unappliedPresetOptions: [String]
    private var nativeRenderer: NativeSceneRenderer?
    private var metalView: SceneMetalView?
    private var displayLink: CVDisplayLink?
    nonisolated private let displayLinkFrames = DisplayLinkFrameGate()
    private var automationTimer: Timer?
    private var lastRenderTime: Double = 0
    private var isPlaying = false
    private var consecutiveZeroTextureFrames = 0
    private let zeroTextureThreshold = 10
    private(set) var needsRecovery = false
    private var renderedFrameCount = 0
    private var screenshotRequest: ScreenshotRequest?
    private var benchmarkRequest: BenchmarkRequest?
    private var animationReferenceTexture: MTLTexture?
    private var animationReferenceTime: Double?
    private var propertyValues: [String: String] = [:]
    private var propertyDefinitions: [String: WallpaperProperty] = [:]
    private var startupError: Error?
    private var cursorPosition: NSPoint?
    private var cursorLeftDown = false
    private var soundPlayer: SceneSoundPlayer?
    private var latestSoundTransports: [FrameSoundTransport] = []
    private var soundSceneRevision: UInt64?
    private var latestMediaState = SceneMediaState()

    // Shared Metal device and command queue (created once, reused across context recreations).
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private struct ScreenshotRequest {
        let targetFrame: Int
        let minimumSceneTime: Double
        let outputURL: URL
        let completion: (Result<Void, Error>) -> Void
    }

    private struct BenchmarkRequest {
        let deadline: CFTimeInterval
        let outputURL: URL
        let completion: (Result<Void, Error>) -> Void
    }

    init(directoryURL: URL, sceneDescription: SceneDescription? = nil, scriptStorage: SceneScriptStorage? = nil, unappliedPresetOptions: [String] = []) {
        self.wallpaperPath = directoryURL.path
        self.wallpaperDirectoryURL = directoryURL
        self.sceneDescription = sceneDescription
        self.scriptStorage = scriptStorage
        self.unappliedPresetOptions = unappliedPresetOptions

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

        if nativeRenderer == nil {
            guard let sceneDescription else {
                let error = RenderStartupError(message: "Scene description is unavailable")
                startupError = error
                showError(error.localizedDescription)
                failPendingAutomation(with: error)
                print("[SceneRenderer] Missing native scene description for: \(wallpaperPath)")
                return
            }

            let support = NativeSceneRenderer.support(scene: sceneDescription)
            if let reportLine = Self.supportReportLine(for: sceneDescription, unappliedPresetOptions: unappliedPresetOptions) {
                print("[SceneRenderer] Native support report: \(reportLine)")
            }
            if let reason = support.reason, !reason.isEmpty {
                print("[SceneRenderer] Native scene support notes: \(reason)")
            }

            do {
                nativeRenderer = try NativeSceneRenderer(
                    scene: sceneDescription,
                    device: device,
                    assetRoots: [
                        wallpaperDirectoryURL,
                        URL(fileURLWithPath: WallpaperAssets.defaultAssetsPath, isDirectory: true),
                    ] + sceneDescription.extractedRoots,
                    scriptStorage: scriptStorage
                )
                startupError = nil
                nativeRenderer?.updateMediaState(latestMediaState)
                setupMetalView()
                if let cursorPosition {
                    nativeRenderer?.updateCursorInput(cursorPosition, leftDown: cursorLeftDown)
                }
                print("[SceneRenderer] Using standalone native renderer for: \(wallpaperPath)")
            } catch {
                startupError = error
                showError(error.localizedDescription)
                failPendingAutomation(with: error)
                print("[SceneRenderer] Native renderer initialization failed for \(wallpaperPath): \(error.localizedDescription)")
                return
            }
            applyStoredProperties()
        }

        startDisplayLink()
        isPlaying = true
        updateSoundPlayback()
        print("[SceneRenderer] Playing: \(wallpaperPath) [backend: native]")
    }

    static func supportReportLine(for scene: SceneDescription, unappliedPresetOptions: [String]) -> String? {
        guard let original = NativeSceneRenderer.supportReportLine(for: scene) else { return nil }
        guard !unappliedPresetOptions.isEmpty,
              var report = try? JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any] else { return original }
        if report["parityStatus"] as? String != "unsupported" { report["parityStatus"] = "partial" }
        var subsystems = report["placeholderSubsystems"] as? [String] ?? []
        subsystems.append("preset-options")
        report["placeholderSubsystems"] = Array(Set(subsystems)).sorted()
        report["unappliedPresetOptions"] = unappliedPresetOptions.sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return original }
        return String(data: data, encoding: .utf8)
    }

    func pause() {
        nativeRenderer?.cancelCursorInteraction()
        guard isPlaying else { return }
        stopDisplayLink()
        isPlaying = false
        updateSoundPlayback()
        print("[SceneRenderer] Paused")
    }

    func stop() {
        stopDisplayLink()
        nativeRenderer = nil
        metalView?.removeFromSuperview()
        metalView = nil
        isPlaying = false
        startupError = nil
        soundPlayer?.dispose()
        soundPlayer = nil
        latestSoundTransports = []
        soundSceneRevision = nil
        print("[SceneRenderer] Stopped")
    }

    func updateCursorPosition(_ position: NSPoint) {
        updateCursorInput(position, leftDown: cursorLeftDown)
    }

    func updateMediaState(_ state: SceneMediaState) {
        latestMediaState = state
        nativeRenderer?.updateMediaState(state)
    }

    func updateCursorInput(_ position: NSPoint, leftDown: Bool) {
        guard position.x.isFinite, position.y.isFinite else { return }
        cursorPosition = position
        cursorLeftDown = leftDown
        nativeRenderer?.updateCursorInput(position, leftDown: leftDown)
    }

    var supportsAudio: Bool { true }

    var isMuted: Bool = true {
        didSet {
            updateSoundPlayback()
        }
    }

    /// Physical output is gated independently from the runtime's logical
    /// per-layer state. Muting or pausing never rewrites a layer command.
    private func updateSoundPlayback() {
        let enabled = !isMuted && isPlaying
        let soundScene = nativeRenderer?.scene ?? sceneDescription
        let revision = nativeRenderer?.sceneRevision
        func roots(for scene: SceneDescription) -> [URL] {
            [wallpaperDirectoryURL, URL(fileURLWithPath: WallpaperAssets.defaultAssetsPath, isDirectory: true)]
                + scene.extractedRoots
        }
        // Wait for the first evaluated packet, including authored startup
        // scripts, before realizing any sound. Keep a player with unavailable
        // assets so its failure cache and terminal feedback survive frames.
        if enabled, !latestSoundTransports.isEmpty, soundPlayer == nil, let soundScene {
            soundPlayer = SceneSoundPlayer(scene: soundScene, assetRoots: roots(for: soundScene))
            soundSceneRevision = revision
        } else if let soundPlayer, let soundScene, revision != soundSceneRevision {
            soundPlayer.updateScene(soundScene, assetRoots: roots(for: soundScene))
            soundSceneRevision = revision
        }
        soundPlayer?.reconcile(latestSoundTransports, outputEnabled: enabled)
        guard let nativeRenderer else { return }
        for (nodeID, runID, finished) in soundPlayer?.drainTerminalStatuses() ?? [] {
            nativeRenderer.updateSoundPlaybackStatus(nodeID: nodeID, runID: runID, finished: finished)
        }
    }

    private func reconcileSoundTransport(_ transports: [FrameSoundTransport]) {
        latestSoundTransports = transports
        updateSoundPlayback()
    }


    func applyProperties(_ properties: [WallpaperProperty], values: [String: String]) {
        for prop in properties {
            propertyDefinitions[prop.key] = prop
            propertyValues[prop.key] = values[prop.key] ?? prop.defaultValue
        }
        applyStoredProperties()
    }

    func applyProperty(_ property: WallpaperProperty, value: String) {
        propertyDefinitions[property.key] = property
        propertyValues[property.key] = value
        applyStoredProperties()
    }

    func receiveAudioData(_ data: [Float]) {
        guard isPlaying else { return }

        if let nativeRenderer {
            nativeRenderer.updateAudio(Self.makeAudioState(from: data))
        }
    }

    func recoverFromSleep() {
        print("[SceneRenderer] Recovering from sleep — recreating native renderer")
        PerformanceMonitor.shared.logEvent("SceneRenderer: sleep recovery — recreating native renderer")
        // The replacement runtime starts fresh run IDs. Dispose its old sound
        // realization too, so a completed run cannot terminate the new one.
        stop()
        consecutiveZeroTextureFrames = 0
        needsRecovery = false
        play()
    }

    func requestScreenshot(outputURL: URL, afterFrames: Int = 60, minimumSceneTime: TimeInterval = 0, completion: @escaping (Result<Void, Error>) -> Void) {
        if let startupError {
            completion(.failure(startupError))
            return
        }
        screenshotRequest = ScreenshotRequest(
            targetFrame: renderedFrameCount + max(afterFrames, 1),
            minimumSceneTime: minimumSceneTime.isFinite ? max(minimumSceneTime, 0) : 0,
            outputURL: outputURL,
            completion: completion
        )
        startAutomationClock()
    }

    func requestBenchmark(outputURL: URL, duration: TimeInterval = 5, completion: @escaping (Result<Void, Error>) -> Void) {
        if let startupError {
            completion(.failure(startupError))
            return
        }
        PerformanceMonitor.shared.resetFrameStatistics()
        benchmarkRequest = BenchmarkRequest(
            deadline: CACurrentMediaTime() + max(duration, 0.1),
            outputURL: outputURL,
            completion: completion
        )
        startAutomationClock()
    }

    // MARK: - Private

    private func setupMetalView() {
        let mv = SceneMetalView(frame: view.bounds, device: device, commandQueue: commandQueue)
        mv.autoresizingMask = [.width, .height]

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(mv)
        mv.frame = view.bounds

        mv.onFramePacket = { [weak self] packet in self?.reconcileSoundTransport(packet.soundTransports) }
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
        displayLinkFrames.start()

        let renderer = Unmanaged.passUnretained(self)
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let renderer = Unmanaged<SceneRenderer>.fromOpaque(userInfo).takeUnretainedValue()
            let frames = renderer.displayLinkFrames
            guard let ticket = frames.request() else { return kCVReturnSuccess }
            // Slow wallpapers must not accumulate main-queue work on every
            // refresh tick. Keep the slot until rendering finishes, and reject
            // work queued before a pause, stop or switch to the capture clock.
            DispatchQueue.main.async { [weak renderer] in
                defer { frames.complete(ticket) }
                guard frames.isCurrent(ticket) else { return }
                renderer?.displayLinkFired()
            }
            return kCVReturnSuccess
        }, renderer.toOpaque())

        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLinkFrames.stop()
        automationTimer?.invalidate()
        automationTimer = nil
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    /// Capture jobs must continue when macOS suspends display refresh (for
    /// example, while the monitor sleeps). They render into an offscreen
    /// texture at the scene's authored resolution instead of requesting a
    /// window drawable. Interactive playback retains its display link.
    private func startAutomationClock() {
        guard automationTimer == nil else { return }
        stopDisplayLink()
        lastRenderTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayLinkFired() }
        }
        automationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        print("[SceneRenderer] Automation uses offscreen rendering at the authored scene resolution")
    }

    private func displayLinkFired() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastRenderTime

        // Display links can run faster than 30 Hz. The automation timer is
        // already capped, so small timer jitter must not discard every other frame.
        guard automationTimer != nil || elapsed >= (1.0 / 30.0) else { return }

        let delta = elapsed
        lastRenderTime = now

        guard let mv = metalView else { return }

        let renderStart = CACurrentMediaTime()
        let timing: SceneMetalView.FrameTiming
        do {
            guard let nativeRenderer else {
                return
            }
            let projection = sceneDescription?.scene?.camera.projection
            let automaticProjection = projection?.isAuto ?? true
            let captureSize = automationTimer == nil ? nil : CGSize(
                width: automaticProjection ? 1920 : max(projection?.width ?? 1920, 1),
                height: automaticProjection ? 1080 : max(projection?.height ?? 1080, 1)
            )
            timing = try mv.renderFrame(nativeRenderer: nativeRenderer, deltaTime: delta, captureSize: captureSize)
        } catch {
            stopDisplayLink()
            isPlaying = false
            showError(error.localizedDescription)
            failPendingAutomation(with: error)
            print("[SceneRenderer] Render failure: \(error.localizedDescription)")
            return
        }
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

        if let request = screenshotRequest, let sceneTime = timing.sceneTime,
           renderedFrameCount >= request.targetFrame, sceneTime >= request.minimumSceneTime {
            if animationReferenceTexture == nil {
                // First trigger: remember this frame, then let playback advance
                // so the capture can also measure animation motion.
                animationReferenceTexture = mv.snapshotEngineTexture()
                animationReferenceTime = sceneTime
                screenshotRequest = ScreenshotRequest(
                    targetFrame: renderedFrameCount + 24,
                    minimumSceneTime: request.minimumSceneTime,
                    outputURL: request.outputURL,
                    completion: request.completion
                )
            } else {
                screenshotRequest = nil
                do {
                    var report = try mv.capturePNG(to: request.outputURL)
                    report.scene_elapsed_time = sceneTime
                    report.rendered_frames = renderedFrameCount
                    report.reference_scene_elapsed_time = animationReferenceTime
                    if let reference = animationReferenceTexture {
                        report.animation_delta = mv.animationDelta(against: reference)
                    }
                    animationReferenceTexture = nil
                    animationReferenceTime = nil
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

    private func applyStoredProperties() {
        if let nativeRenderer {
            nativeRenderer.updatePropertyOverrides(makeNativePropertyOverrides())
        }
    }

    private func makeNativePropertyOverrides() -> [String: FrameValue] {
        var overrides: [String: FrameValue] = [:]
        for (key, value) in propertyValues {
            guard let property = propertyDefinitions[key] else {
                continue
            }
            overrides[key] = Self.frameValue(for: property, value: value)
        }
        return overrides
    }

    private static func frameValue(for property: WallpaperProperty, value: String) -> FrameValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch property.type {
        case .slider:
            if let intValue = Int(trimmed), !trimmed.contains(".") {
                return .int(intValue)
            }
            return .double(Double(trimmed) ?? 0)
        case .bool:
            return .bool(["1", "true", "yes", "on"].contains(trimmed.lowercased()))
        case .color:
            let normalized = WallpaperProperty.normalizeColorString(trimmed)
            let components = normalized.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            return .vec3(Array(components.prefix(3)))
        case .combo:
            if let intValue = Int(trimmed) {
                return .int(intValue)
            }
            if let doubleValue = Double(trimmed) {
                return .double(doubleValue)
            }
            return .string(trimmed)
        case .text, .textinput, .file, .scenetexture:
            return .string(trimmed)
        }
    }

    static func makeAudioState(from data: [Float]) -> AudioInputState {
        guard !data.isEmpty else {
            return .silent
        }

        let levels = data.count == 128 ? (0..<64).map { (data[$0] + data[$0 + 64]) * 0.5 } : data
        func average(in range: Range<Int>) -> Double {
            guard !range.isEmpty else { return 0 }
            let clamped = range.clamped(to: 0..<levels.count)
            guard !clamped.isEmpty else { return 0 }
            let sum = clamped.reduce(0.0) { partial, index in
                partial + Double(levels[index])
            }
            return sum / Double(clamped.count)
        }

        let count = levels.count
        let quarter = max(count / 4, 1)
        let half = max(count / 2, 1)
        let threeQuarter = max((count * 3) / 4, 1)

        return AudioInputState(
            overall: average(in: 0..<count),
            bass: average(in: 0..<quarter),
            mid: average(in: quarter..<threeQuarter),
            treble: average(in: half..<count),
            spectrum: data
        )
    }

    private func failPendingAutomation(with error: Error) {
        if let request = screenshotRequest {
            screenshotRequest = nil
            request.completion(.failure(error))
        }

        if let request = benchmarkRequest {
            benchmarkRequest = nil
            request.completion(.failure(error))
        }
    }

}

// MARK: - SceneMetalView

/// MTKView subclass that blits the native renderer's `MTLTexture` to screen.
private class SceneMetalView: MTKView {
    var onFramePacket: ((FramePacket) -> Void)?
    private let commandQueue: MTLCommandQueue
    private var blitPipelineState: MTLRenderPipelineState?
    private var quadVertexBuffer: MTLBuffer?
    private var samplerState: MTLSamplerState?
    private var isSetup = false
    private var frameCount = 0
    private var lastEngineTexture: MTLTexture?
    private var nativeRenderTarget: MTLTexture?

    struct FrameTiming {
        let gotTexture: Bool
        let engineMs: Double
        let blitMs: Double
        var sceneTime: Double? = nil
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

    func renderFrame(nativeRenderer renderer: NativeSceneRenderer, deltaTime: Double, captureSize: CGSize? = nil) throws -> FrameTiming {
        if !isSetup {
            setupBlitPipeline()
            isSetup = true
            print("[SceneMetalView] Blit pipeline set up")
        }

        let drawable = captureSize == nil ? currentDrawable : nil
        guard captureSize != nil || drawable != nil,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let renderTarget = makeNativeRenderTarget(
                width: captureSize.map { Int($0.width) } ?? drawable!.texture.width,
                height: captureSize.map { Int($0.height) } ?? drawable!.texture.height
              ) else {
            frameCount += 1
            return FrameTiming(gotTexture: false, engineMs: 0, blitMs: 0)
        }

        let engineStart = CACurrentMediaTime()
        let packet = try renderer.renderNextFrame(deltaTime: deltaTime, into: renderTarget, commandBuffer: cmdBuf)
        onFramePacket?(packet)
        let engineMs = (CACurrentMediaTime() - engineStart) * 1000.0
        lastEngineTexture = renderTarget

        let blitStart = CACurrentMediaTime()
        if drawable != nil, let rpd = currentRenderPassDescriptor,
           let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd),
           let pso = blitPipelineState,
           let vb = quadVertexBuffer,
           let ss = samplerState {
            enc.setRenderPipelineState(pso)
            enc.setFragmentTexture(renderTarget, index: 0)
            enc.setFragmentSamplerState(ss, index: 0)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        if let drawable { cmdBuf.present(drawable) }
        cmdBuf.commit()
        if captureSize != nil {
            cmdBuf.waitUntilCompleted()
            if let error = cmdBuf.error { throw error }
        }

        let blitMs = (CACurrentMediaTime() - blitStart) * 1000.0
        frameCount += 1
        return FrameTiming(gotTexture: true, engineMs: engineMs, blitMs: blitMs, sceneTime: packet.timing.elapsedTime)
    }

    func capturePNG(to outputURL: URL) throws -> ScreenshotReport {
        guard let texture = lastEngineTexture else {
            throw TextureSnapshotError.imageCreationFailed
        }
        return try TextureSnapshot.writePNG(from: texture, using: commandQueue, to: outputURL)
    }

    /// Clones the current engine texture so a later frame can be diffed
    /// against it for the animation-motion report.
    func snapshotEngineTexture() -> MTLTexture? {
        guard let source = lastEngineTexture, let device else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let copy = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return copy
    }

    func animationDelta(against earlier: MTLTexture) -> Double? {
        guard let texture = lastEngineTexture else {
            return nil
        }
        return TextureSnapshot.meanAbsoluteDifference(earlier, texture, using: commandQueue)
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

    private func makeNativeRenderTarget(width: Int, height: Int) -> MTLTexture? {
        if let nativeRenderTarget,
           nativeRenderTarget.width == width,
           nativeRenderTarget.height == height {
            return nativeRenderTarget
        }

        guard let device else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        nativeRenderTarget = device.makeTexture(descriptor: descriptor)
        return nativeRenderTarget
    }
}
