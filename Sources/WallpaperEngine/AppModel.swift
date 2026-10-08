import AppKit
import Observation

/// Single source of truth for the app's UI surfaces (menu bar popover, settings,
/// gallery, properties panel). Playback state lives in `DesktopWindowManager`;
/// this model mirrors it into an observable snapshot and owns the user actions.
@MainActor
@Observable
final class AppModel {
    /// What the UI shows about the desktop. Refreshed after every action and
    /// periodically while a surface is visible, since occlusion, sleep and audio
    /// permission changes happen without user action.
    struct Snapshot: Equatable {
        var title: String?
        var previewURL: URL?
        var directoryPath: String?
        var pauseReason: String?
        var isManuallyPaused = false
        var isMuted = true
        var supportsAudio = false
        var fps: Double = 0
        var audioSelection: AudioResponseSource = .off
        var audioStatus = ""
        var mediaSelection: MediaSourceSelection = .off
        var mediaStatus = ""
    }

    private(set) var snapshot = Snapshot()
    private(set) var loadingName: String?
    private(set) var recents: [RecentWallpaper] = []
    private(set) var libraryFolders: [URL] = []
    private(set) var usesCustomLibraryFolder = false
    private(set) var loginItemEnabled = false

    var restoresOnLaunch: Bool {
        get { access(keyPath: \.restoresOnLaunch); return recentStore.restoresOnLaunch }
        set { withMutation(keyPath: \.restoresOnLaunch) { recentStore.restoresOnLaunch = newValue } }
    }

    @ObservationIgnored let windowManager: DesktopWindowManager
    /// Set by the app delegate, which owns orderly process termination.
    @ObservationIgnored var onQuit: (() -> Void)?
    @ObservationIgnored private let recentStore = RecentWallpapers()
    @ObservationIgnored private let loginItem = LoginItem()
    @ObservationIgnored private let galleryController = GalleryWindowController()
    @ObservationIgnored private var propertiesController: PropertiesWindowController?
    @ObservationIgnored private var settingsController: SettingsWindowController?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var refreshClients = 0

    init(windowManager: DesktopWindowManager) {
        self.windowManager = windowManager
        refresh()
    }

    // MARK: - State

    func refresh() {
        let manager = windowManager
        let project = manager.currentProject
        let next = Snapshot(
            title: manager.currentTitle,
            previewURL: project?.previewURL,
            directoryPath: project?.directoryURL?.standardizedFileURL.path,
            pauseReason: manager.pauseReason,
            isManuallyPaused: manager.isManuallyPaused,
            isMuted: manager.isMuted,
            supportsAudio: manager.supportsAudio,
            fps: manager.currentTitle == nil ? 0 : PerformanceMonitor.shared.currentFPS,
            audioSelection: manager.audioReactivity.selection,
            audioStatus: manager.audioReactivity.status,
            mediaSelection: manager.mediaIntegration.selection,
            mediaStatus: manager.mediaIntegration.status
        )
        if next != snapshot { snapshot = next }
        let items = recentStore.items
        if items != recents { recents = items }
        let folders = LibraryFolders.directories
        if folders != libraryFolders { libraryFolders = folders }
        let custom = LibraryFolders.customDirectory != nil
        if custom != usesCustomLibraryFolder { usesCustomLibraryFolder = custom }
        if loginItem.isEnabled != loginItemEnabled { loginItemEnabled = loginItem.isEnabled }
    }

    /// Keep the snapshot live while at least one surface is on screen.
    func beginLiveUpdates() {
        refreshClients += 1
        refresh()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func endLiveUpdates() {
        refreshClients = max(0, refreshClients - 1)
        guard refreshClients == 0 else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    var hasWallpaper: Bool { snapshot.title != nil }

    // MARK: - Loading

    /// Load at launch: an explicit path wins, otherwise the last wallpaper if enabled.
    func loadInitialWallpaper(path: String?) {
        if let path {
            Task { await load(URL(fileURLWithPath: path)) }
        } else if let url = recentStore.wallpaperToRestore {
            Task { await load(url, reportsErrors: false) }
        }
    }

    func load(_ url: URL, reportsErrors: Bool = true) async {
        let name = url.lastPathComponent
        loadingName = name
        defer {
            if loadingName == name { loadingName = nil }
            refresh()
        }
        do {
            try await windowManager.loadWallpaper(from: url)
            if let project = windowManager.currentProject {
                recentStore.record(project, loadedFrom: url)
            }
        } catch is CancellationError {
            return
        } catch {
            if reportsErrors { presentLoadError(error, for: url) }
        }
        refreshPropertiesWindowIfNeeded()
    }

    func chooseWallpaperFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a wallpaper file or Wallpaper Engine directory"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    private func presentLoadError(_ error: Error, for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t load “\(url.lastPathComponent)”"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Playback

    func togglePause() {
        if windowManager.isManuallyPaused {
            windowManager.resumeWallpaper()
        } else {
            windowManager.pauseWallpaper()
        }
        refresh()
    }

    func toggleMute() {
        windowManager.isMuted.toggle()
        refresh()
    }

    func clearWallpaper() {
        windowManager.clearWallpaper()
        recentStore.forgetLast()
        propertiesController?.close()
        refresh()
    }

    func selectAudioResponse(_ source: AudioResponseSource) {
        windowManager.audioReactivity.select(source)
        refresh()
    }

    func selectMediaSource(_ source: MediaSourceSelection) {
        windowManager.mediaIntegration.select(source)
        refresh()
    }

    func connect(_ player: MediaPlayer) {
        Task {
            await windowManager.mediaIntegration.connect(player)
            refresh()
        }
    }

    // MARK: - Windows

    func openGallery() {
        galleryController.showGallery { [weak self] url in
            await self?.load(url)
        }
    }

    func openProperties() {
        guard let title = windowManager.currentTitle else { return }
        if propertiesController == nil { propertiesController = PropertiesWindowController() }
        showProperties(title: title)
    }

    /// If the properties panel is open, update it for the newly loaded wallpaper.
    /// Keep Reset available for scene storage even without authored properties.
    private func refreshPropertiesWindowIfNeeded() {
        guard propertiesController != nil else { return }
        if let title = windowManager.currentTitle {
            showProperties(title: title)
        } else {
            propertiesController?.close()
        }
    }

    private func showProperties(title: String) {
        propertiesController?.show(
            title: title,
            properties: windowManager.currentProperties,
            values: windowManager.currentPropertyValues,
            onChange: { [weak self] key, value in
                self?.windowManager.applyProperty(key: key, value: value)
            },
            onReset: { [weak self] in
                self?.windowManager.resetProperties() ?? false
            }
        )
    }

    func openSettings() {
        if settingsController == nil { settingsController = SettingsWindowController(model: self) }
        settingsController?.show()
    }

    // MARK: - Settings

    func chooseLibraryFolder() {
        guard LibraryFolders.chooseCustomFolder() else { return }
        galleryController.rescan()
        refresh()
    }

    func useDefaultLibraryFolders() {
        LibraryFolders.useDefaults()
        galleryController.rescan()
        refresh()
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    var loginItemExecutablePath: String { loginItem.executablePath }

    func quit() {
        onQuit?()
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PerformanceMonitor.shared.summary(), forType: .string)
        print("[WallpaperEngine] Diagnostics copied to clipboard")
    }
}
