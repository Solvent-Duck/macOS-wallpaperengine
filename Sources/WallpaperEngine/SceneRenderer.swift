import AppKit
import OpenGL.GL3
import CoreVideo
import CWEBridge

/// Renders Wallpaper Engine scene wallpapers via linux-wallpaperengine.
///
/// Uses a C bridge (`WEBridge.h`) to the linux-wallpaperengine C++ engine,
/// which handles scene parsing, shader compilation (HLSL → SPIRV → GLSL 330),
/// and OpenGL 3.3 rendering. The engine renders into a shared OpenGL context;
/// this class blits the result into an `NSOpenGLView` via a textured quad.
///
/// ## Performance
/// - Rendering is driven by a CVDisplayLink capped at 30fps.
/// - When paused, the CVDisplayLink is stopped entirely (zero GPU cost).
/// - The engine's output texture is used directly (zero-copy shared GL context).
class SceneRenderer: WallpaperRenderer {
    let view: NSView
    private let wallpaperPath: String
    private var context: WEContextRef?
    private var glView: SceneOpenGLView?
    private var displayLink: CVDisplayLink?
    private var lastRenderTime: Double = 0
    private var isPlaying = false
    private var consecutiveZeroTextureFrames = 0
    private let zeroTextureThreshold = 10
    private(set) var needsRecovery = false

    /// Default path to Wallpaper Engine's shared assets directory.
    /// Users can override this via UserDefaults "WEAssetsPath".
    private static var assetsPath: String {
        if let custom = UserDefaults.standard.string(forKey: "WEAssetsPath"), !custom.isEmpty {
            return custom
        }
        // Common locations for WE assets copied from a Windows install
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

        // Create the GL view first with a placeholder; we'll share the engine's context once created
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        self.view = container

        // Defer engine initialization to play() so we know the view's frame
    }

    func play() {
        if isPlaying { return }

        let frame = view.bounds.isEmpty ? NSRect(x: 0, y: 0, width: 1920, height: 1080) : view.bounds
        let width = Int32(frame.width)
        let height = Int32(frame.height)

        // Create the C++ engine context if not already done
        if context == nil {
            print("[SceneRenderer] Creating engine context: \(width)x\(height), assets: \(Self.assetsPath)")
            guard let ctx = we_create_context(wallpaperPath, Self.assetsPath, width, height) else {
                print("[SceneRenderer] Failed to create engine context for: \(wallpaperPath)")
                showError("Failed to initialize scene renderer")
                return
            }
            context = ctx
            print("[SceneRenderer] Engine context created successfully")

            // Set up the shared GL view
            if let nsglContext = we_get_gl_context(ctx) {
                print("[SceneRenderer] Got NSGL context for sharing")
                setupGLView(sharingContext: nsglContext, engineContext: ctx)
            } else {
                print("[SceneRenderer] Warning: Could not get GL context for sharing")
                setupGLView(sharingContext: nil, engineContext: ctx)
            }
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
        glView?.removeFromSuperview()
        glView = nil
        isPlaying = false
        print("[SceneRenderer] Stopped")
    }

    func updateCursorPosition(_ position: NSPoint) {
        guard let ctx = context else { return }
        we_set_mouse_position(ctx, Float(position.x), Float(position.y))
    }

    var supportsAudio: Bool { true }

    var isMuted: Bool = true {
        didSet {
            // Audio muting would be handled through the engine's audio context
            // For v1, audio plays through SDL independently
        }
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
        glView?.removeFromSuperview()
        glView = nil
        isPlaying = false
        consecutiveZeroTextureFrames = 0
        needsRecovery = false
        play()
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func setupGLView(sharingContext: UnsafeMutableRawPointer?, engineContext: WEContextRef) {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 24,
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            0
        ]

        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attrs) else {
            print("[SceneRenderer] Failed to create pixel format")
            return
        }

        // Create a shared context if we have the engine's NSGL context
        let sharedContext: NSOpenGLContext?
        if let nsgl = sharingContext {
            sharedContext = Unmanaged<NSOpenGLContext>.fromOpaque(nsgl).takeUnretainedValue()
        } else {
            sharedContext = nil
        }

        let openGLView = SceneOpenGLView(
            frame: view.bounds,
            pixelFormat: pixelFormat,
            sharedContext: sharedContext,
            engineContext: engineContext
        )
        openGLView.autoresizingMask = [.width, .height]

        // Remove any existing subviews (error labels, etc.)
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(openGLView)
        openGLView.frame = view.bounds

        self.glView = openGLView
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
        CVDisplayLinkSetOutputCallback(link, { (_, inNow, inOutputTime, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let renderer = Unmanaged<SceneRenderer>.fromOpaque(userInfo).takeUnretainedValue()
            renderer.displayLinkFired()
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

        // Cap at 30fps: skip frames when less than ~33ms have elapsed
        guard elapsed >= (1.0 / 30.0) else { return }

        let delta = elapsed
        lastRenderTime = now

        guard let ctx = context, let glView = glView else { return }

        let renderStart = CACurrentMediaTime()
        let timing = glView.renderFrame(engineContext: ctx, deltaTime: delta)
        let totalMs = (CACurrentMediaTime() - renderStart) * 1000.0
        let intervalMs = elapsed * 1000.0
        PerformanceMonitor.shared.recordFrame(
            totalMs: totalMs,
            engineMs: timing.engineMs,
            blitMs: timing.blitMs,
            intervalMs: intervalMs
        )

        // Track consecutive frames with no texture output (possible broken GL state after wake)
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
    }
}

// MARK: - SceneOpenGLView

/// NSOpenGLView subclass that displays the engine's rendered output.
///
/// Shares the OpenGL context with the C++ engine so the engine's output texture
/// is directly accessible. Draws a fullscreen textured quad each frame.
private class SceneOpenGLView: NSOpenGLView {
    private var engineContext: WEContextRef?
    private var blitProgram: GLuint = 0
    private var quadVAO: GLuint = 0
    private var quadVBO: GLuint = 0
    private var texUniform: GLint = 0
    private var isSetup = false
    private var frameCount = 0

    init(frame: NSRect, pixelFormat: NSOpenGLPixelFormat,
         sharedContext: NSOpenGLContext?, engineContext: WEContextRef) {
        self.engineContext = engineContext
        super.init(frame: frame, pixelFormat: pixelFormat)!

        // If we have a shared context, replace the auto-created one
        if let shared = sharedContext {
            let ctx = NSOpenGLContext(format: pixelFormat, share: shared)
            self.openGLContext = ctx
        }

        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    struct FrameTiming {
        let gotTexture: Bool
        let engineMs: Double   // time for we_render_frame (CPU stall ≈ GPU work)
        let blitMs: Double     // time for blit quad draw + buffer flush
    }

    /// Render a frame. Returns timing breakdown and whether a texture was drawn.
    func renderFrame(engineContext ctx: WEContextRef, deltaTime: Double) -> FrameTiming {
        guard let glContext = openGLContext else {
            if frameCount == 0 { print("[SceneRenderer] No openGLContext on view") }
            return FrameTiming(gotTexture: false, engineMs: 0, blitMs: 0)
        }
        let cglContext = glContext.cglContextObj!

        CGLLockContext(cglContext)

        // Step 1: Engine renders into its own GLFW context.
        // we_render_frame calls glfwMakeContextCurrent + glFinish internally,
        // so this wall-clock time is the true GPU render time for the scene.
        let engineStart = CACurrentMediaTime()
        we_render_frame(ctx, deltaTime)
        let engineMs = (CACurrentMediaTime() - engineStart) * 1000.0

        // Step 2: Switch to the view's shared context to blit the texture.
        glContext.makeCurrentContext()

        if !isSetup {
            setupBlitShader()
            print("[SceneRenderer] Blit shader set up, program: \(blitProgram)")
            isSetup = true
        }

        // Get the engine's output texture (shared between contexts)
        let texture = we_get_texture(ctx)
        let gotTexture = texture != 0

        frameCount += 1

        let blitStart = CACurrentMediaTime()
        if gotTexture {
            let bounds = self.convertToBacking(self.bounds)
            glViewport(0, 0, GLsizei(bounds.width), GLsizei(bounds.height))
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

            glUseProgram(blitProgram)
            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(GLenum(GL_TEXTURE_2D), texture)
            glUniform1i(texUniform, 0)
            glBindVertexArray(quadVAO)
            glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
            glBindVertexArray(0)
            glUseProgram(0)
        }

        glContext.flushBuffer()
        let blitMs = (CACurrentMediaTime() - blitStart) * 1000.0

        CGLUnlockContext(cglContext)
        return FrameTiming(gotTexture: gotTexture, engineMs: engineMs, blitMs: blitMs)
    }

    private func setupBlitShader() {
        // Fullscreen quad vertices: position (xy) + texcoord (uv)
        // V is flipped (1→0 top-to-bottom) because the engine renders into an OpenGL FBO
        // whose Y=0 is at the bottom, while the scene's coordinate system has Y increasing downward.
        let vertices: [GLfloat] = [
            -1, -1,  0, 1,
             1, -1,  1, 1,
            -1,  1,  0, 0,
             1,  1,  1, 0,
        ]

        glGenVertexArrays(1, &quadVAO)
        glBindVertexArray(quadVAO)

        glGenBuffers(1, &quadVBO)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), quadVBO)
        glBufferData(GLenum(GL_ARRAY_BUFFER), MemoryLayout<GLfloat>.size * vertices.count,
                     vertices, GLenum(GL_STATIC_DRAW))

        // Position attribute (location 0)
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                              GLsizei(4 * MemoryLayout<GLfloat>.size), nil)
        // TexCoord attribute (location 1)
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),
                              GLsizei(4 * MemoryLayout<GLfloat>.size),
                              UnsafeRawPointer(bitPattern: 2 * MemoryLayout<GLfloat>.size))

        glBindVertexArray(0)

        // Compile blit shader
        let vertSrc = """
        #version 330 core
        layout(location = 0) in vec2 a_Position;
        layout(location = 1) in vec2 a_TexCoord;
        out vec2 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 0.0, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """

        let fragSrc = """
        #version 330 core
        in vec2 v_TexCoord;
        out vec4 FragColor;
        uniform sampler2D u_Texture;
        void main() {
            FragColor = texture(u_Texture, v_TexCoord);
        }
        """

        let vertShader = compileShader(type: GLenum(GL_VERTEX_SHADER), source: vertSrc)
        let fragShader = compileShader(type: GLenum(GL_FRAGMENT_SHADER), source: fragSrc)

        blitProgram = glCreateProgram()
        glAttachShader(blitProgram, vertShader)
        glAttachShader(blitProgram, fragShader)
        glLinkProgram(blitProgram)

        glDeleteShader(vertShader)
        glDeleteShader(fragShader)

        texUniform = glGetUniformLocation(blitProgram, "u_Texture")
    }

    private func compileShader(type: GLenum, source: String) -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { ptr in
            var p: UnsafePointer<GLchar>? = ptr
            glShaderSource(shader, 1, &p, nil)
        }
        glCompileShader(shader)

        var success: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &success)
        if success == 0 {
            var logLength: GLint = 0
            glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &logLength)
            if logLength > 0 {
                var log = [GLchar](repeating: 0, count: Int(logLength))
                glGetShaderInfoLog(shader, logLength, nil, &log)
                print("[SceneRenderer] Shader compile error: \(String(cString: log))")
            }
        }
        return shader
    }

    deinit {
        if blitProgram != 0 { glDeleteProgram(blitProgram) }
        if quadVAO != 0 { glDeleteVertexArrays(1, &quadVAO) }
        if quadVBO != 0 { glDeleteBuffers(1, &quadVBO) }
    }
}
