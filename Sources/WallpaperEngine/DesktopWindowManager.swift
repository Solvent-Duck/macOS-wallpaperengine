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
    private var isVisible = true
    private var isManuallyPaused = false

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
    }

    /// Resume a manually paused wallpaper (still respects occlusion).
    func resumeWallpaper() {
        isManuallyPaused = false
        if isVisible {
            renderer?.play()
        }
    }

    /// Stop and remove the current wallpaper.
    func clearWallpaper() {
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
            return VideoRenderer(fileURL: fileURL)
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

        // Start occlusion tracking on the new windows
        occlusionDetector.observe(windows: windows) { [weak self] visible in
            self?.handleVisibilityChange(visible)
        }

        print("[WallpaperEngine] Created \(windows.count) desktop window(s)")
    }

    private func handleVisibilityChange(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible

        if visible && !isManuallyPaused {
            renderer?.play()
            print("[WallpaperEngine] Desktop visible — resuming renderer")
        } else if !visible {
            renderer?.pause()
            print("[WallpaperEngine] Desktop fully occluded — pausing renderer")
        }
    }

    @objc private func screensDidChange(_ notification: Notification) {
        print("[WallpaperEngine] Display configuration changed — rebuilding windows")
        rebuildWindows()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        occlusionDetector.stop()
        renderer?.stop()
    }
}
