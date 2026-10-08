import AppKit
import NativeSceneRuntime

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
@MainActor
class DesktopWindowManager {
    private var windows: [DesktopWindow] = []
    private var renderers: [WallpaperRenderer] = []
    private var currentProject: WallpaperProject?
    private var sceneScriptStorage: SceneScriptStorage?

    private var primaryRenderer: WallpaperRenderer? { renderers.first }
    private let occlusionDetector = OcclusionDetector()
    private let cursorTracker = CursorTracker()
    let audioReactivity = AudioReactivity()
    lazy var mediaIntegration: MediaIntegrationController = {
        let controller = MediaIntegrationController()
        controller.onUpdate = { [weak self] state in
            self?.renderers.forEach { $0.updateMediaState(state) }
        }
        return controller
    }()
    private var isVisible = true
    /// Whether the user paused playback (as opposed to occlusion or sleep).
    private(set) var isManuallyPaused = false
    private var isSleeping = false
    private var isTearingDown = false
    private var lastRebuildTime: Double = 0
    private var loadGeneration = 0
    private var pendingPropertySave: Task<Void, Never>?
    var automationMode = false

    /// NSProcessInfo activity token held while the wallpaper is actively rendering.
    /// Prevents macOS App Nap from throttling timer callbacks and the render loop.
    private var appNapActivity: NSObjectProtocol?

    /// Live property values for the current wallpaper (defaults merged with user overrides).
    private var propertyValues: [String: String] = [:]

    /// The title of the currently loaded wallpaper, if any.
    var currentTitle: String? { currentProject?.resolvedTitle }

    /// Property definitions for the current wallpaper.
    var currentProperties: [WallpaperProperty] { currentProject?.resolvedProperties ?? [] }

    /// Scene-native default resolution for the current wallpaper, when available.
    var currentSceneResolution: CGSize? { currentProject?.sceneResolution }

    /// Current (user-modified or default) property values.
    var currentPropertyValues: [String: String] { propertyValues }

    /// Why playback is paused, or nil while it is playing (or nothing is loaded).
    var pauseReason: String? {
        guard currentProject != nil else { return nil }
        if isManuallyPaused { return "Paused" }
        if isSleeping { return "Paused while asleep" }
        if !automationMode && !isVisible { return "Paused while covered" }
        return nil
    }

    /// Create desktop windows for all screens and start observing display changes.
    func setupWindows() {
        rebuildWindows()

        guard !automationMode else { return }

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
        let shouldHold = !renderers.isEmpty && canResume
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
        updateAudioReactivity()
    }

    private func updateAudioReactivity() {
        // Captures use explicit test inputs, independent of desktop audio.
        guard !automationMode, !isTearingDown, canResume, !renderers.isEmpty,
              currentProject?.resolvedType == .scene || currentProject?.resolvedType == .web else {
            audioReactivity.stop()
            return
        }
        audioReactivity.start { [weak self] data in
            self?.renderers.forEach { $0.receiveAudioData(data) }
        }
    }

    // MARK: - Wallpaper Loading

    /// Load a wallpaper from a file or directory URL.
    ///
    /// The current wallpaper keeps playing while the project is parsed and any
    /// WebM source is transcoded off the main thread. Throws `CancellationError`
    /// when a newer load superseded this one while it was preparing.
    func loadWallpaper(from url: URL) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let project = try WallpaperLoader.load(from: url)
            guard let fileURL = project.fileURL else {
                throw WallpaperError.fileNotFound(url)
            }
            var mediaURL = fileURL
            if project.resolvedType == .video, WebMTranscoder.isWebM(fileURL) {
                mediaURL = try await Task.detached(priority: .userInitiated) {
                    try WebMTranscoder.transcode(webmURL: fileURL)
                }.value
                guard generation == loadGeneration else { throw CancellationError() }
            }
            try activate(project, mediaURL: mediaURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[WallpaperEngine] Error loading wallpaper: \(error.localizedDescription)")
            throw error
        }
    }

    private func activate(_ project: WallpaperProject, mediaURL: URL) throws {
        // Stop any existing wallpaper
        flushPendingPropertySave()
        audioReactivity.stop()
        mediaIntegration.stop()
        let previousRenderers = renderers
        renderers = []
        previousRenderers.forEach { $0.stop() }
        // Choosing a wallpaper is an explicit request to play it.
        isManuallyPaused = false

        do {
            currentProject = project
            print("[WallpaperEngine] Loaded project: \"\(project.resolvedTitle)\" (type: \(project.resolvedType.rawValue))")

            sceneScriptStorage = nil
            if project.resolvedType == .scene {
                let directory = automationMode ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("WallpaperEngine/SceneScriptStorage", isDirectory: true)
                let identity = SceneScriptStorage.wallpaperIdentity(
                    workshopID: project.type == .preset ? nil : project.sceneDescription?.metadata.workshopId,
                    directory: project.directoryURL ?? mediaURL
                )
                sceneScriptStorage = try SceneScriptStorage(directory: directory, wallpaperID: identity)
            }
            let newRenderers = try windows.map { window in
                try createRenderer(for: project, fileURL: mediaURL, screen: window.screen)
            }
            renderers = newRenderers
            PerformanceMonitor.shared.setRenderer(type: project.resolvedType.rawValue.capitalized, status: "Playing")

            // Load persisted property values, merge with defaults
            let saved = loadPropertyValues(for: project)
            let resolvedProperties = project.resolvedProperties
            propertyValues = mergedValues(properties: resolvedProperties, saved: saved)
            newRenderers.forEach { $0.applyProperties(resolvedProperties, values: propertyValues) }
            startMediaIntegrationIfNeeded()

            // Set the renderer's view as content on all desktop windows
            applyRendererToWindows()

            // Start cursor tracking for interactive wallpapers
            startCursorTracking()

            // Only start playing if all conditions allow it
            if canResume {
                newRenderers.forEach { $0.play() }
            }
            updateAppNapAssertion()
        } catch {
            // The previous wallpaper is already stopped; don't report it as current.
            clearWallpaper()
            throw error
        }
    }

    /// Manually pause the current wallpaper.
    func pauseWallpaper() {
        isManuallyPaused = true
        renderers.forEach { $0.pause() }
        cursorTracker.stop()
        updateAppNapAssertion()
        PerformanceMonitor.shared.logEvent("Manual pause")
        PerformanceMonitor.shared.setRendererStatus("Paused")
    }

    /// Resume a manually paused wallpaper (still respects occlusion and sleep).
    func resumeWallpaper() {
        isManuallyPaused = false
        if canResume {
            renderers.forEach { $0.play() }
            startCursorTracking()
            PerformanceMonitor.shared.setRendererStatus("Playing")
        }
        updateAppNapAssertion()
        PerformanceMonitor.shared.logEvent("Manual resume")
    }

    /// Whether the current renderer supports audio.
    var supportsAudio: Bool { primaryRenderer?.supportsAudio ?? false }

    /// Whether audio is currently muted.
    var isMuted: Bool {
        get { primaryRenderer?.isMuted ?? true }
        set { renderers.forEach { $0.isMuted = newValue } }
    }

    /// Explicitly stop all rendering and close desktop windows before app termination.
    ///
    /// Must be called from `applicationWillTerminate` so the CVDisplayLink and C++
    /// engine context are destroyed on the main thread, before `exit(0)` runs.
    /// Without this, SDL2's atexit handler fires while the main thread is already in
    /// `exit()`, causing a deadlock that prevents the process from exiting cleanly.
    func teardown() {
        guard !isTearingDown else {
            print("[WallpaperEngine] Teardown already in progress")
            return
        }
        isTearingDown = true
        flushPendingPropertySave()
        audioReactivity.stop()
        mediaIntegration.stop()
        cursorTracker.stop()
        occlusionDetector.stop()
        let activeRenderers = renderers
        renderers = []
        activeRenderers.forEach { $0.stop() }
        currentProject = nil
        propertyValues = [:]
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
        flushPendingPropertySave()
        audioReactivity.stop()
        mediaIntegration.stop()
        cursorTracker.stop()
        let activeRenderers = renderers
        renderers = []
        activeRenderers.forEach { $0.stop() }
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
        if let prop = currentProject?.resolvedProperties.first(where: { $0.key == key }) {
            renderers.forEach { $0.applyProperty(prop, value: value) }
        }
        schedulePropertySave()
    }

    func resetProperties() -> Bool {
        guard let project = currentProject else { return false }
        // Finish destroy callbacks before clearing storage; they can save data.
        let restartScene = sceneScriptStorage != nil
        if restartScene { renderers.forEach { $0.stop() } }
        do { try sceneScriptStorage?.reset() }
        catch {
            print("[WallpaperEngine] Could not reset script storage: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
            if canResume { renderers.forEach { $0.play() } }
            return false
        }
        pendingPropertySave?.cancel()
        pendingPropertySave = nil
        propertyValues = mergedValues(properties: project.resolvedProperties, saved: [:])
        renderers.forEach { $0.applyProperties(project.resolvedProperties, values: propertyValues) }
        savePropertyValues()
        if restartScene && canResume { renderers.forEach { $0.play() } }
        return true
    }

    func requestScreenshot(outputURL: URL, afterFrames: Int, minimumSceneTime: TimeInterval = 0, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sceneRenderer = primaryRenderer as? SceneRenderer else {
            completion(.failure(AutomationError.unsupportedRenderer))
            return
        }
        sceneRenderer.requestScreenshot(outputURL: outputURL, afterFrames: afterFrames, minimumSceneTime: minimumSceneTime, completion: completion)
    }

    func requestBenchmark(outputURL: URL, duration: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sceneRenderer = primaryRenderer as? SceneRenderer else {
            completion(.failure(AutomationError.unsupportedRenderer))
            return
        }
        sceneRenderer.requestBenchmark(outputURL: outputURL, duration: duration, completion: completion)
    }

    // MARK: - Private

    private func createRenderer(for project: WallpaperProject, fileURL: URL, screen: NSScreen?) throws -> WallpaperRenderer {
        switch project.resolvedType {
        case .video:
            return VideoRenderer(fileURL: fileURL)
        case .web:
            return WebRenderer(fileURL: fileURL, readAccessURL: project.type == .preset ? project.directoryURL?.deletingLastPathComponent() : nil)
        case .scene:
            guard let dirURL = project.contentDirectoryURL ?? project.directoryURL else {
                throw WallpaperError.unsupportedType(.scene)
            }
            let screenID: String
            if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
                screenID = CFUUIDCreateString(nil, uuid) as String
            } else {
                screenID = screen?.localizedName ?? "default"
            }
            return SceneRenderer(directoryURL: dirURL, sceneDescription: project.sceneDescription,
                                 scriptStorage: sceneScriptStorage?.forScreen(screenID),
                                 unappliedPresetOptions: Array(project.presetSettings.keys))
        case .preset, .application:
            throw WallpaperError.unsupportedType(project.type)
        }
    }

    private func startCursorTracking() {
        cursorTracker.start { [weak self] screenPoint, leftDown in
            guard let self else { return }
            for (window, renderer) in zip(self.windows, self.renderers) {
                let normalized = CursorTracker.normalize(screenPoint, in: window.frame)
                renderer.updateCursorInput(normalized, leftDown: leftDown)
            }
        }
    }

    private func applyRendererToWindows() {
        for (index, window) in windows.enumerated() {
            guard index < renderers.count else { break }
            let r = renderers[index]
            window.contentView = r.view
            r.view.frame = window.contentView?.bounds ?? window.frame
            r.view.autoresizingMask = [.width, .height]
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
        (automationMode || isVisible) && !isManuallyPaused && !isSleeping
    }

    private func startMediaIntegrationIfNeeded() {
        // Automation captures use their explicitly supplied inputs, independent
        // of whichever media a user might be playing on the desktop.
        guard !automationMode, !isSleeping, currentProject?.resolvedType == .scene else { return }
        renderers.forEach { $0.updateMediaState(mediaIntegration.state) }
        mediaIntegration.start()
    }

    private func handleVisibilityChange(_ visible: Bool) {
        if automationMode {
            return
        }
        guard visible != isVisible else { return }
        isVisible = visible

        if visible && !isManuallyPaused && !isSleeping {
            renderers.forEach { $0.play() }
            startCursorTracking()
            print("[WallpaperEngine] Desktop visible — resuming renderer")
        } else if !visible {
            renderers.forEach { $0.pause() }
            cursorTracker.stop()
            print("[WallpaperEngine] Desktop fully occluded — pausing renderer")
        }
        updateAppNapAssertion()
        PerformanceMonitor.shared.logEvent("Occlusion: \(visible ? "visible" : "occluded")")
    }

    @objc private func handleSleep(_ notification: Notification) {
        guard !isSleeping else { return }
        isSleeping = true
        mediaIntegration.stop()
        renderers.forEach { $0.pause() }
        cursorTracker.stop()
        updateAppNapAssertion()
        print("[WallpaperEngine] Sleep/lock — pausing renderer (\(notification.name.rawValue))")
        PerformanceMonitor.shared.logEvent("Sleep: \(notification.name.rawValue)")
    }

    @objc private func handleWake(_ notification: Notification) {
        guard isSleeping else { return }
        isSleeping = false
        startMediaIntegrationIfNeeded()
        if canResume {
            // Check if any scene renderer flagged that it needs recovery
            let sceneRenderers = renderers.compactMap { $0 as? SceneRenderer }
            if sceneRenderers.contains(where: { $0.needsRecovery }) {
                sceneRenderers.forEach { $0.recoverFromSleep() }
            } else {
                renderers.forEach { $0.play() }
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

    /// Slider and colour drags change values every frame; persist once they settle.
    private func schedulePropertySave() {
        pendingPropertySave?.cancel()
        pendingPropertySave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.pendingPropertySave = nil
            self.savePropertyValues()
        }
    }

    private func flushPendingPropertySave() {
        guard let pending = pendingPropertySave else { return }
        pending.cancel()
        pendingPropertySave = nil
        savePropertyValues()
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

}
