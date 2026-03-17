import AppKit

/// Application delegate managing the menu bar item and desktop window lifecycle.
///
/// This is a menu bar-only app (no dock icon). The status item provides
/// wallpaper selection and app controls. Desktop windows are created
/// automatically on launch for each connected display.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let windowManager = DesktopWindowManager()

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
        menu.addItem(NSMenuItem(
            title: "Select Wallpaper…",
            action: #selector(selectWallpaper),
            keyEquivalent: "o"
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit WallpaperEngine",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
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
        }
    }
}
