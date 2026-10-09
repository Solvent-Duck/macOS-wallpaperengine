import AppKit
import SwiftUI

/// Manages the library window lifecycle, bridging SwiftUI into
/// the AppKit-based menu bar app.
@MainActor
class GalleryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(library: GalleryViewModel, appModel: AppModel) {
        // If already open, bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: GalleryView(library: library, appModel: appModel))
        hostingController.sceneBridgingOptions = [.title, .toolbars]

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Wallpaper Library"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.toolbarStyle = .unified
        win.setContentSize(NSSize(width: 1180, height: 720))
        win.minSize = NSSize(width: 820, height: 480)
        win.setFrameAutosaveName("WallpaperLibrary")
        if !win.setFrameUsingName("WallpaperLibrary") { win.center() }
        win.delegate = self
        win.isReleasedWhenClosed = false

        self.window = win

        // Switch to regular app so the window is focusable
        AppActivation.windowDidOpen()
        appModel.beginLiveUpdates()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        liveUpdatesModel = appModel
    }

    private weak var liveUpdatesModel: AppModel?

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        liveUpdatesModel?.endLiveUpdates()
        liveUpdatesModel = nil
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
