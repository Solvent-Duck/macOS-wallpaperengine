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
    private let audioReactivity = AudioReactivity()
    private var isVisible = true
    private var isManuallyPaused = false
    private var isSleeping = false
    private var lastRebuildTime: Double = 0

    /// NSProcessInfo activity token held while the wallpaper is actively rendering.
    /// Prevents macOS App Nap from throttling timer callbacks and the render loop.
    private var appNapActivity: NSObjectProtocol?

    /// Live property values for the current wallpaper (defaults merged with user overrides).
    private var propertyValues: [String: String] = [:]

    /// The title of the currently loaded wallpaper, if any.
    var currentTitle: String? { currentProject?.title }

    /// Property definitions for the current wallpaper.
    var currentProperties: [WallpaperProperty] { currentProject?.properties ?? [] }

    /// Current (user-modified or default) property values.
    var currentPropertyValues: [String: String] { propertyValues }

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

    // MARK: - App Nap

    /// Hold an NSProcessInfo activity token while rendering to prevent App Nap
    /// from throttling the render loop. Released when the wallpaper is paused or stopped.
    private func updateAppNapAssertion() {
        let shouldHold = renderer != nil && canResume
        if shouldHold && appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Rendering wallpaper animation"
            )
            print("[WallpaperEngine] App Nap assertion acquired")
        } else if !shouldHold, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
            print("[WallpaperEngine] App Nap assertion released")
        }
    }

    // MARK: - Wallpaper Loading

    /// Load a wallpaper from a file or directory URL.
    func loadWallpaper(from url: URL) {
        // Stop any existing wallpaper
        audioReactivity.stop()
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
            PerformanceMonitor.shared.setRenderer(type: project.type.rawValue.capitalized, status: "Playing")

            // Load persisted property values, merge with defaults
            let saved = loadPropertyValues(for: project)
            propertyValues = mergedValues(properties: project.properties, saved: saved)
            newRenderer.applyProperties(project.properties, values: propertyValues)

            // Set the renderer's view as content on all desktop windows
            applyRendererToWindows()

            // Start cursor tracking for interactive wallpapers
            startCursorTracking()

            // Only start playing if all conditions allow it
            if canResume {
                newRenderer.play()
            }
            updateAppNapAssertion()

            // Start audio reactivity — forwards frequency data to the renderer at ~30fps
            audioReactivity.start { [weak self] data in
                self?.renderer?.receiveAudioData(data)
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
        updateAppNapAssertion()
        PerformanceMonitor.shared.logEvent("Manual pause")
        PerformanceMonitor.shared.setRendererStatus("Paused")
    }

    /// Resume a manually paused wallpaper (still respects occlusion and sleep).
    func resumeWallpaper() {
        isManuallyPaused = false
        if canResume {
            renderer?.play()
            startCursorTracking()
            PerformanceMonitor.shared.setRendererStatus("Playing")
        }
        updateAppNapAssertion()
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
        audioReactivity.stop()
        cursorTracker.stop()
        occlusionDetector.stop()
        renderer?.stop()
        renderer = nil
        currentProject = nil
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
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
        audioReactivity.stop()
        cursorTracker.stop()
        renderer?.stop()
        renderer = nil
        currentProject = nil
        isManuallyPaused = false
        propertyValues = [:]
        updateAppNapAssertion()
        PerformanceMonitor.shared.setRenderer(type: "None", status: "Stopped")
        for window in windows {
            window.contentView = nil
        }
    }

    /// Apply a single property change from the UI and persist it.
    func applyProperty(key: String, value: String) {
        propertyValues[key] = value
        if let prop = currentProject?.properties.first(where: { $0.key == key }) {
            renderer?.applyProperty(prop, value: value)
        }
        savePropertyValues()
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
        updateAppNapAssertion()
        PerformanceMonitor.shared.logEvent("Occlusion: \(visible ? "visible" : "occluded")")
    }

    @objc private func handleSleep(_ notification: Notification) {
        guard !isSleeping else { return }
        isSleeping = true
        renderer?.pause()
        cursorTracker.stop()
        updateAppNapAssertion()
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
        updateAppNapAssertion()
        print("[WallpaperEngine] Wake/unlock — \(canResume ? "resuming" : "staying paused") (\(notification.name.rawValue))")
        PerformanceMonitor.shared.logEvent("Wake: \(notification.name.rawValue)")
    }

    // MARK: - Property Persistence

    private func userDefaultsKey(for project: WallpaperProject) -> String {
        "WallpaperProperties.\(project.directoryURL?.path ?? project.title)"
    }

    private func loadPropertyValues(for project: WallpaperProject) -> [String: String] {
        let key = userDefaultsKey(for: project)
        return UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func savePropertyValues() {
        guard let project = currentProject else { return }
        UserDefaults.standard.set(propertyValues, forKey: userDefaultsKey(for: project))
    }

    private func mergedValues(properties: [WallpaperProperty], saved: [String: String]) -> [String: String] {
        var merged = [String: String]()
        for p in properties { merged[p.key] = saved[p.key] ?? p.defaultValue }
        return merged
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
