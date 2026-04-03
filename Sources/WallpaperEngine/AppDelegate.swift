import AppKit
import Darwin

/// Application delegate managing the menu bar item and desktop window lifecycle.
///
/// This is a menu bar-only app (no dock icon). The status item provides
/// wallpaper selection and app controls. Desktop windows are created
/// automatically on launch for each connected display.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let windowManager = DesktopWindowManager()
    private let galleryController = GalleryWindowController()
    private let launchOptions: LaunchOptions
    private var isPaused = false
    var initialWallpaperPath: String?
    private var automationController: AutomationController?

    // Menu items that need dynamic updates
    private var currentWallpaperItem: NSMenuItem!
    private var pauseResumeItem: NSMenuItem!
    private var audioToggleItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var propertiesItem: NSMenuItem!

    private var propertiesController: PropertiesWindowController?

    init(launchOptions: LaunchOptions) {
        self.launchOptions = launchOptions
        super.init()
        windowManager.automationMode = launchOptions.isAutomation
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !launchOptions.isAutomation {
            setupStatusBar()
        }
        windowManager.setupWindows()
        print("[WallpaperEngine] Ready — \(NSScreen.screens.count) display(s) detected")

        if let path = initialWallpaperPath {
            let url = URL(fileURLWithPath: path)
            windowManager.loadWallpaper(from: url)
            if !launchOptions.isAutomation {
                updateMenuState()
            }
        }

        if launchOptions.isAutomation {
            guard initialWallpaperPath != nil else {
                print("[Automation] \(AutomationError.missingWallpaperPath.localizedDescription)")
                terminateProcess(exitCode: 1)
                return
            }

            automationController = AutomationController(options: launchOptions) { [weak self] exitCode in
                self?.terminateProcess(exitCode: exitCode)
            }
            automationController?.start(with: windowManager)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Explicitly stop the CVDisplayLink and destroy the C++ engine context
        // before exit(0) is called. Without this, SDL2's atexit handler fires
        // while the main thread is in exit(), deadlocking the process.
        windowManager.teardown()
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
        let browseItem = NSMenuItem(title: "Browse Wallpapers…", action: #selector(openGallery), keyEquivalent: "b")
        browseItem.target = self
        menu.addItem(browseItem)

        let selectItem = NSMenuItem(title: "Select Wallpaper…", action: #selector(selectWallpaper), keyEquivalent: "o")
        selectItem.target = self
        menu.addItem(selectItem)

        propertiesItem = NSMenuItem(title: "Wallpaper Properties…", action: #selector(openProperties), keyEquivalent: "i")
        propertiesItem.target = self
        menu.addItem(propertiesItem)

        menu.addItem(NSMenuItem.separator())

        pauseResumeItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pauseResumeItem.target = self
        menu.addItem(pauseResumeItem)

        audioToggleItem = NSMenuItem(title: "Unmute Audio", action: #selector(toggleAudio), keyEquivalent: "m")
        audioToggleItem.target = self
        menu.addItem(audioToggleItem)

        clearItem = NSMenuItem(title: "Clear Wallpaper", action: #selector(clearWallpaper), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let diagItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "d")
        diagItem.target = self
        menu.addItem(diagItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit WallpaperEngine", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuState()
    }

    private func updateMenuState() {
        let hasWallpaper = windowManager.currentTitle != nil

        currentWallpaperItem.title = windowManager.currentTitle ?? "No wallpaper loaded"
        pauseResumeItem.title = isPaused ? "Resume" : "Pause"
        pauseResumeItem.isEnabled = hasWallpaper
        audioToggleItem.title = windowManager.isMuted ? "Unmute Audio" : "Mute Audio"
        audioToggleItem.isEnabled = hasWallpaper && windowManager.supportsAudio
        clearItem.isEnabled = hasWallpaper
        propertiesItem.isEnabled = hasWallpaper && !windowManager.currentProperties.isEmpty
    }

    // MARK: - Actions

    @objc private func openProperties() {
        let props = windowManager.currentProperties
        let vals  = windowManager.currentPropertyValues
        guard !props.isEmpty, let title = windowManager.currentTitle else { return }
        if propertiesController == nil { propertiesController = PropertiesWindowController() }
        propertiesController?.show(
            title: title,
            properties: props,
            values: vals,
            onChange: { [weak self] key, value in
                self?.windowManager.applyProperty(key: key, value: value)
            }
        )
    }

    @objc private func openGallery() {
        galleryController.showGallery { [weak self] url in
            self?.windowManager.loadWallpaper(from: url)
            self?.isPaused = false
            self?.updateMenuState()
            self?.refreshPropertiesWindowIfNeeded()
        }
    }

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
            self?.refreshPropertiesWindowIfNeeded()
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

    @objc private func toggleAudio() {
        windowManager.isMuted.toggle()
        updateMenuState()
    }

    @objc private func copyDiagnostics() {
        let summary = PerformanceMonitor.shared.summary()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        print("[WallpaperEngine] Diagnostics copied to clipboard")
    }

    @objc private func clearWallpaper() {
        windowManager.clearWallpaper()
        isPaused = false
        updateMenuState()
        propertiesController?.close()
    }

    @objc private func quitApp() {
        terminateProcess(exitCode: 0)
    }

    private func terminateProcess(exitCode: Int32) {
        // Explicitly tear down renderer/window resources before process exit.
        // The linked scene stack currently crashes during C++ global finalizers
        // (observed in glslang ShFinalize during NSApplication.terminate -> exit).
        // After manual teardown, use _exit() to bypass the broken finalizer path.
        windowManager.teardown()
        statusItem?.menu = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        for window in NSApplication.shared.windows {
            window.close()
        }
        fflush(stdout)
        fflush(stderr)
        _exit(exitCode)
    }

    /// If the properties panel is open, update it for the newly loaded wallpaper.
    /// If the new wallpaper has no properties, close the panel.
    private func refreshPropertiesWindowIfNeeded() {
        guard let controller = propertiesController else { return }
        let props = windowManager.currentProperties
        if props.isEmpty {
            controller.close()
        } else if let title = windowManager.currentTitle {
            controller.show(
                title: title,
                properties: props,
                values: windowManager.currentPropertyValues,
                onChange: { [weak self] key, value in
                    self?.windowManager.applyProperty(key: key, value: value)
                }
            )
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    @objc func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
        let fps = PerformanceMonitor.shared.currentFPS
        if fps > 0 {
            statusItem?.button?.toolTip = String(format: "Wallpaper Engine — %.1f fps", fps)
        } else {
            statusItem?.button?.toolTip = "Wallpaper Engine"
        }
    }
}
