import AppKit

/// Application delegate managing the menu bar item and desktop window lifecycle.
///
/// This is a menu bar-only app (no dock icon). The status item provides
/// wallpaper selection and app controls. Desktop windows are created
/// automatically on launch for each connected display.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let windowManager = DesktopWindowManager()
    private var isPaused = false

    // Menu items that need dynamic updates
    private var currentWallpaperItem: NSMenuItem!
    private var pauseResumeItem: NSMenuItem!
    private var clearItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        windowManager.setupWindows()
        print("[WallpaperEngine] Ready — \(NSScreen.screens.count) display(s) detected")
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "photo.on.rectangle",
                accessibilityDescription: "Wallpaper Engine"
            )
        }

        let menu = NSMenu()
        menu.delegate = self

        // Current wallpaper info (disabled label)
        currentWallpaperItem = NSMenuItem(title: "No wallpaper loaded", action: nil, keyEquivalent: "")
        currentWallpaperItem.isEnabled = false
        menu.addItem(currentWallpaperItem)
        menu.addItem(NSMenuItem.separator())

        // Actions
        menu.addItem(NSMenuItem(
            title: "Select Wallpaper…",
            action: #selector(selectWallpaper),
            keyEquivalent: "o"
        ))

        pauseResumeItem = NSMenuItem(
            title: "Pause",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        menu.addItem(pauseResumeItem)

        clearItem = NSMenuItem(
            title: "Clear Wallpaper",
            action: #selector(clearWallpaper),
            keyEquivalent: ""
        )
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit WallpaperEngine",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        updateMenuState()
    }

    private func updateMenuState() {
        let hasWallpaper = windowManager.currentTitle != nil

        currentWallpaperItem.title = windowManager.currentTitle ?? "No wallpaper loaded"
        pauseResumeItem.title = isPaused ? "Resume" : "Pause"
        pauseResumeItem.isEnabled = hasWallpaper
        clearItem.isEnabled = hasWallpaper
    }

    // MARK: - Actions

    @objc private func selectWallpaper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a wallpaper file or Wallpaper Engine directory"

        // Bring the panel to front since we're an accessory app
        panel.level = .floating

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.windowManager.loadWallpaper(from: url)
            self?.isPaused = false
            self?.updateMenuState()
        }
    }

    @objc private func togglePause() {
        isPaused.toggle()
        if isPaused {
            windowManager.pauseWallpaper()
        } else {
            windowManager.resumeWallpaper()
        }
        updateMenuState()
    }

    @objc private func clearWallpaper() {
        windowManager.clearWallpaper()
        isPaused = false
        updateMenuState()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }
}
