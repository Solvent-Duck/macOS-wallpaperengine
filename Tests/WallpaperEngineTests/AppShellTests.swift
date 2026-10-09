import Foundation
import Testing
@testable import WallpaperEngine

struct AppShellTests {
    private func makeWallpaper(_ root: URL, _ name: String) throws -> (URL, WallpaperProject) {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var project = WallpaperProject(title: "Title \(name)", type: .video, file: "clip.mp4", preview: "preview.jpg", description: nil, tags: nil)
        project.directoryURL = directory
        return (directory, project)
    }

    @Test func recentsAreNewestFirstDeduplicatedAndCapped() throws {
        let suite = "AppShellTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WERecents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentWallpapers(defaults: defaults)

        for index in 0..<(RecentWallpapers.limit + 2) {
            let (url, project) = try makeWallpaper(root, "w\(index)")
            store.record(project, loadedFrom: url)
        }
        let (again, project) = try makeWallpaper(root, "w3")
        store.record(project, loadedFrom: again)

        let items = store.items
        #expect(items.count == RecentWallpapers.limit)
        #expect(items.first?.title == "Title w3")
        #expect(Set(items.map(\.path)).count == items.count)
        #expect(items.first?.previewURL?.lastPathComponent == "preview.jpg")

        // Deleted wallpapers drop out of the list and are not restored.
        try FileManager.default.removeItem(at: again)
        #expect(!store.items.contains { $0.title == "Title w3" })
        #expect(store.wallpaperToRestore == nil)
    }

    @Test func restoreFollowsTheLastWallpaperAndClearing() throws {
        let suite = "AppShellTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WERestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentWallpapers(defaults: defaults)
        let (url, project) = try makeWallpaper(root, "123")

        #expect(store.restoresOnLaunch)
        store.record(project, loadedFrom: url)
        #expect(store.wallpaperToRestore?.standardizedFileURL == url.standardizedFileURL)
        store.restoresOnLaunch = false
        #expect(store.wallpaperToRestore == nil)
        store.restoresOnLaunch = true
        store.forgetLast()
        #expect(store.wallpaperToRestore == nil)
        #expect(store.items.count == 1)
    }

    @Test func loginItemWritesAndRemovesALaunchAgent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WELoginItem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = LoginItem(launchAgentsDirectory: directory, executablePath: "/opt/we/WallpaperEngine")

        #expect(!item.isEnabled)
        try item.setEnabled(true)
        #expect(item.isEnabled)
        #expect(item.registeredExecutablePath == "/opt/we/WallpaperEngine")
        let plist = try #require(NSDictionary(contentsOf: item.agentURL))
        #expect(plist["Label"] as? String == LoginItem.label)
        #expect(plist["RunAtLoad"] as? Bool == true)

        try item.setEnabled(false)
        #expect(!item.isEnabled)
        try item.setEnabled(false) // idempotent
    }
}
