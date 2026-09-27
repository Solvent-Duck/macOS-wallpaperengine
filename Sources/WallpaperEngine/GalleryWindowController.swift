import AppKit
import SwiftUI

/// Manages the gallery window lifecycle, bridging SwiftUI into
/// the AppKit-based menu bar app.
@MainActor
class GalleryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: GalleryViewModel?

    /// The root directory to scan for wallpaper projects.
    var wallpaperDirectory: URL {
        if let saved = UserDefaults.standard.string(forKey: "wallpaperDirectory") {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960")
    }

    func showGallery(onSelect: @escaping (URL) -> Void) {
        // If already open, bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = GalleryViewModel(onSelect: onSelect)
        self.viewModel = vm

        let galleryView = GalleryView(viewModel: vm)
        let hostingController = NSHostingController(rootView: galleryView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Wallpaper Gallery"
        win.setContentSize(NSSize(width: 900, height: 600))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.minSize = NSSize(width: 500, height: 400)
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false

        self.window = win

        // Switch to regular app so the window is focusable
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Scan for wallpapers
        vm.scan(directory: wallpaperDirectory)
    }

    func rescan() {
        viewModel?.scan(directory: wallpaperDirectory)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        viewModel = nil
        // Revert to menu bar-only accessory app
        NSApp.setActivationPolicy(.accessory)
    }
}
