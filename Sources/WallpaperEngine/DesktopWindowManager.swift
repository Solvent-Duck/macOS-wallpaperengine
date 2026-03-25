import AppKit

/// Manages desktop-level windows across all connected displays.
///
/// Creates one `DesktopWindow` per screen on launch and rebuilds them when
/// the display configuration changes (monitor connected/disconnected,
/// resolution change, etc.). Routes wallpaper content to each window
/// via a `WallpaperRenderer`.
///
/// Automatically pauses rendering when all desktop windows are fully
/// occluded by other application windows, and resumes when any part
/// of the desktop becomes visible again.
class DesktopWindowManager {
    private var windows: [DesktopWindow] = []
    private var renderer: WallpaperRenderer?
    private var currentProject: WallpaperProject?
    private let occlusionDetector = OcclusionDetector()
    private let cursorTracker = CursorTracker()
    private var isVisible = true
    private var isManuallyPaused = false
    private var isSleeping = false
    private var lastRebuildTime: Double = 0

    /// The title of the currently loaded wallpaper, if any.
    var currentTitle: String? { currentProject?.title }

    /// Create desktop windows for all screens and start observing display changes.
    func setupWindows() {
        rebuildWindows()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Sleep/wake notifications
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(handleSleep),
                         name: NSWorkspace.willSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(handleSleep),
                         name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(handleWake),
                         name: NSWorkspace.didWakeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(handleWake),
                         name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Screen lock / fast user switch
        wsnc.addObserver(self, selector: #selector(handleSleep),
                         name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(handleWake),
                         name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    /// Load a wallpaper from a file or directory URL.
    func loadWallpaper(from url: URL) {
        // Stop any existing wallpaper
        renderer?.stop()
        renderer = nil

        do {
            let project = try WallpaperLoader.load(from: url)
            currentProject = project
            print("[WallpaperEngine] Loaded project: \"\(project.title)\" (type: \(project.type.rawValue))")

            guard let fileURL = project.fileURL else {
                print("[WallpaperEngine] Error: Could not resolve wallpaper file URL")
                return
            }

            let newRenderer = try createRenderer(for: project, fileURL: fileURL)
            renderer = newRenderer

            // Set the renderer's view as content on all desktop windows
            applyRendererToWindows()

            // Start cursor tracking for interactive wallpapers
            startCursorTracking()

            // Only start playing if the desktop is actually visible
            if isVisible {
                newRenderer.play()
            }

        } catch {
            print("[WallpaperEngine] Error loading wallpaper: \(error.localizedDescription)")
        }
    }

    /// Manually pause the current wallpaper.
    func pauseWallpaper() {
        isManuallyPaused = true
        renderer?.pause()
        cursorTracker.stop()
        PerformanceMonitor.shared.logEvent("Manual pause")
    }

    /// Resume a manually paused wallpaper (still respects occlusion and sleep).
    func resumeWallpaper() {
        isManuallyPaused = false
        if canResume {
            renderer?.play()
            startCursorTracking()
        }
        PerformanceMonitor.shared.logEvent("Manual resume")
    }

    /// Whether the current renderer supports audio.
    var supportsAudio: Bool { renderer?.supportsAudio ?? false }

    /// Whether audio is currently muted.
    var isMuted: Bool {
        get { renderer?.isMuted ?? true }
        set { renderer?.isMuted = newValue }
    }

    /// Explicitly stop all rendering and close desktop windows before app termination.
    ///
    /// Must be called from `applicationWillTerminate` so the CVDisplayLink and C++
    /// engine context are destroyed on the main thread, before `exit(0)` runs.
    /// Without this, SDL2's atexit handler fires while the main thread is already in
    /// `exit()`, causing a deadlock that prevents the process from exiting cleanly.
    func teardown() {
        cursorTracker.stop()
        occlusionDetector.stop()
        renderer?.stop()
        renderer = nil
        currentProject = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for window in windows {
            window.close()
        }
        windows.removeAll()
        print("[WallpaperEngine] Teardown complete")
    }

    /// Stop and remove the current wallpaper.
    func clearWallpaper() {
        cursorTracker.stop()
        renderer?.stop()
        renderer = nil
        currentProject = nil
        isManuallyPaused = false
        for window in windows {
            window.contentView = nil
        }
    }

    // MARK: - Private

    private func createRenderer(for project: WallpaperProject, fileURL: URL) throws -> WallpaperRenderer {
        switch project.type {
        case .video:
            let resolvedURL: URL
            if WebMTranscoder.isWebM(fileURL) {
                resolvedURL = try WebMTranscoder.transcode(webmURL: fileURL)
            } else {
                resolvedURL = fileURL
            }
            return VideoRenderer(fileURL: resolvedURL)
        case .web:
            return WebRenderer(fileURL: fileURL)
        case .scene:
            guard let dirURL = project.directoryURL else {
                throw WallpaperError.unsupportedType(.scene)
            }
            return SceneRenderer(directoryURL: dirURL)
        case .preset, .application:
            throw WallpaperError.unsupportedType(project.type)
        }
    }

    private func startCursorTracking() {
        cursorTracker.start { [weak self] screenPoint in
            guard let self, let renderer = self.renderer else { return }
            // Normalize relative to the primary screen
            if let screen = NSScreen.main {
                let normalized = CursorTracker.normalize(screenPoint, for: screen)
                renderer.updateCursorPosition(normalized)
            }
        }
    }

    private func applyRendererToWindows() {
        guard let renderer else { return }

        for window in windows {
            // All windows share the same renderer view for now.
            // For multi-monitor with independent wallpapers, each window
            // would get its own renderer instance.
            window.contentView = renderer.view
            renderer.view.frame = window.contentView?.bounds ?? window.frame
            renderer.view.autoresizingMask = [.width, .height]
        }
    }

    private func rebuildWindows() {
        lastRebuildTime = CACurrentMediaTime()
        occlusionDetector.stop()

        for window in windows {
            window.close()
        }
        windows.removeAll()

        for screen in NSScreen.screens {
            let window = DesktopWindow(for: screen)
            window.orderFront(nil)
            windows.append(window)
        }

        // Re-apply the current renderer to the new windows
        applyRendererToWindows()

        // Start occlusion tracking on the new windows.
        // Note: Desktop-level windows may not get reliable occlusionState
        // updates from macOS, so we also default isVisible to true.
        isVisible = true
        occlusionDetector.observe(windows: windows) { [weak self] visible in
            self?.handleVisibilityChange(visible)
        }

        print("[WallpaperEngine] Created \(windows.count) desktop window(s)")
    }

    /// Whether all conditions are met to resume rendering.
    private var canResume: Bool {
        isVisible && !isManuallyPaused && !isSleeping
    }

    private func handleVisibilityChange(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible

        if visible && !isManuallyPaused && !isSleeping {
            renderer?.play()
            startCursorTracking()
            print("[WallpaperEngine] Desktop visible — resuming renderer")
        } else if !visible {
            renderer?.pause()
            cursorTracker.stop()
            print("[WallpaperEngine] Desktop fully occluded — pausing renderer")
        }
        PerformanceMonitor.shared.logEvent("Occlusion: \(visible ? "visible" : "occluded")")
    }

    @objc private func handleSleep(_ notification: Notification) {
        guard !isSleeping else { return }
        isSleeping = true
        renderer?.pause()
        cursorTracker.stop()
        print("[WallpaperEngine] Sleep/lock — pausing renderer (\(notification.name.rawValue))")
        PerformanceMonitor.shared.logEvent("Sleep: \(notification.name.rawValue)")
    }

    @objc private func handleWake(_ notification: Notification) {
        guard isSleeping else { return }
        isSleeping = false
        if canResume {
            // Check if the scene renderer flagged that it needs recovery
            if let sceneRenderer = renderer as? SceneRenderer, sceneRenderer.needsRecovery {
                sceneRenderer.recoverFromSleep()
            } else {
                renderer?.play()
            }
            startCursorTracking()
        }
        print("[WallpaperEngine] Wake/unlock — \(canResume ? "resuming" : "staying paused") (\(notification.name.rawValue))")
        PerformanceMonitor.shared.logEvent("Wake: \(notification.name.rawValue)")
    }

    @objc private func screensDidChange(_ notification: Notification) {
        // Debounce: creating/closing windows can itself trigger this notification.
        // Ignore rapid-fire events within 1 second of the last rebuild.
        let now = CACurrentMediaTime()
        guard now - lastRebuildTime > 1.0 else { return }
        print("[WallpaperEngine] Display configuration changed — rebuilding windows")
        PerformanceMonitor.shared.logEvent("Display reconfig")
        rebuildWindows()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        occlusionDetector.stop()
        renderer?.stop()
    }
}
