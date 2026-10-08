import AppKit
import SwiftUI

/// Manages the gallery window lifecycle, bridging SwiftUI into
/// the AppKit-based menu bar app.
@MainActor
class GalleryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: GalleryViewModel?

    private static let directoryDefaultsKey = "wallpaperDirectory"

    /// The folders scanned when the user hasn't chosen one: the user guide's
    /// copy-in folder first (so copies win over duplicates), then Steam's workshop.
    static var defaultWallpaperDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Wallpaper Projects", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960", isDirectory: true),
        ]
    }

    /// The root directories to scan for wallpaper projects.
    var wallpaperDirectories: [URL] {
        if let saved = UserDefaults.standard.string(forKey: Self.directoryDefaultsKey) {
            return [URL(fileURLWithPath: saved, isDirectory: true)]
        }
        return Self.defaultWallpaperDirectories.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    func showGallery(onSelect: @escaping @MainActor (URL) async -> Void) {
        // If already open, bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = GalleryViewModel(onSelect: onSelect)
        vm.onChooseFolder = { [weak self] in self?.chooseFolder() }
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
        AppActivation.windowDidOpen()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Scan for wallpapers
        vm.scan(directories: wallpaperDirectories)
    }

    func rescan() {
        viewModel?.scan(directories: wallpaperDirectories)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that contains your wallpaper folders"
        panel.directoryURL = wallpaperDirectories.first
        guard let window, panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.directoryDefaultsKey)
        window.makeKeyAndOrderFront(nil)
        rescan()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        viewModel = nil
        // Revert to menu bar-only accessory app unless another window is open
        AppActivation.windowDidClose()
    }
}
