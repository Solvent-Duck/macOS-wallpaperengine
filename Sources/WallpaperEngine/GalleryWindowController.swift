import AppKit
import SteamLibrary
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
///
/// Steam decides where Workshop items live, so its folders are always the
/// source for subscribed wallpapers. A folder the user adds supplements them
/// (manual installs, presets, copies) rather than replacing them.
@MainActor
enum LibraryFolders {
    private static let defaultsKey = "wallpaperDirectory"
    private static let showsWorkshopKey = "showsSteamWorkshopWallpapers"

    /// Wallpaper Engine's Workshop folder in every Steam library.
    static var workshopDirectories: [URL] {
        SteamLibraryLocator().workshopLibraries().map(\.contentDirectory)
    }

    /// The user guide's copy-in folder.
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Wallpaper Projects", isDirectory: true)
    }

    /// A folder the user added alongside Steam's and `~/Wallpaper Projects`.
    static var customDirectory: URL? {
        UserDefaults.standard.string(forKey: defaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Hiding Workshop wallpapers is a setting, not a side effect of adding a folder.
    static var showsWorkshopWallpapers: Bool {
        get { UserDefaults.standard.object(forKey: showsWorkshopKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showsWorkshopKey) }
    }

    /// The root directories to scan for wallpaper projects, in priority order.
    static var directories: [URL] {
        ordered(workshop: showsWorkshopWallpapers ? workshopDirectories : [],
                projects: projectsDirectory, custom: customDirectory).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Steam's folders come first: when the same item (folder name, which is
    /// the Workshop ID) also exists elsewhere, the scan keeps the first copy,
    /// and Steam's is the one that receives updates and goes away when the
    /// user unsubscribes. A folder listed twice is scanned once.
    nonisolated static func ordered(workshop: [URL], projects: URL, custom: URL?) -> [URL] {
        var seen = Set<String>()
        return (workshop + [projects] + (custom.map { [$0] } ?? [])).filter { url in
            seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
    }

    static func removeCustomFolder() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Ask for a folder to add; returns whether the user chose one.
    static func chooseCustomFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder that contains more wallpaper folders. Steam Workshop wallpapers are always included."
        panel.directoryURL = customDirectory ?? projectsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
        return true
    }
}
