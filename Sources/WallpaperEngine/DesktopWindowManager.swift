import AppKit

/// Manages desktop-level windows across all connected displays.
///
/// Creates one `DesktopWindow` per screen on launch and rebuilds them when
/// the display configuration changes (monitor connected/disconnected,
/// resolution change, etc.).
class DesktopWindowManager {
    private var windows: [DesktopWindow] = []

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
        // TODO: Detect wallpaper type from url/project.json and create the
        //       appropriate renderer (video, web, scene).
        print("[WallpaperEngine] Loading wallpaper from: \(url.path)")
    }

    // MARK: - Private

    private func rebuildWindows() {
        for window in windows {
            window.close()
        }
        windows.removeAll()

        for screen in NSScreen.screens {
            let window = DesktopWindow(for: screen)
            window.orderFront(nil)
            windows.append(window)
        }

        print("[WallpaperEngine] Created \(windows.count) desktop window(s)")
    }

    @objc private func screensDidChange(_ notification: Notification) {
        print("[WallpaperEngine] Display configuration changed — rebuilding windows")
        rebuildWindows()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
