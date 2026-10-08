import AppKit
import SwiftUI

/// Manages the gallery window lifecycle, bridging SwiftUI into
/// the AppKit-based menu bar app.
@MainActor
class GalleryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: GalleryViewModel?

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
        vm.scan(directories: LibraryFolders.directories)
    }

    func rescan() {
        viewModel?.scan(directories: LibraryFolders.directories)
    }

    private func chooseFolder() {
        guard let window, LibraryFolders.chooseCustomFolder() else { return }
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

/// Where the gallery looks for wallpaper folders.
@MainActor
enum LibraryFolders {
    private static let defaultsKey = "wallpaperDirectory"

    /// The folders scanned when the user hasn't chosen one: the user guide's
    /// copy-in folder first (so copies win over duplicates), then Steam's workshop.
    static var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Wallpaper Projects", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960", isDirectory: true),
        ]
    }

    /// The user's chosen folder, if they picked one instead of the defaults.
    static var customDirectory: URL? {
        UserDefaults.standard.string(forKey: defaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The root directories to scan for wallpaper projects.
    static var directories: [URL] {
        if let customDirectory { return [customDirectory] }
        return defaultDirectories.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func useDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Ask for a folder; returns whether the user chose one.
    static func chooseCustomFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that contains your wallpaper folders"
        panel.directoryURL = directories.first
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
        return true
    }
}
