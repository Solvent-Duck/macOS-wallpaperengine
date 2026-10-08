import Foundation
import Testing
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct LibraryRefreshTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELibraryRefresh-\(UUID().uuidString)")
    private var copies: URL { root.appendingPathComponent("Wallpaper Projects") }
    private var workshop: URL { root.appendingPathComponent("431960") }

    private func makeProject(in parent: URL, id: String, title: String, type: String = "video", tags: [String] = []) throws {
        let directory = parent.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = ["title": title, "type": type, "file": "clip.mp4", "tags": tags]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("project.json"))
    }

    private func scanned() async throws -> GalleryViewModel {
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workshop, withIntermediateDirectories: true)
        let library = GalleryViewModel()
        library.scan(directories: [copies, workshop])
        let deadline = ContinuousClock.now + .seconds(10)
        while library.isScanning {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        return library
    }

    @Test func addedUpdatedAndRemovedFoldersUpdateWallpapersAndCounts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeProject(in: workshop, id: "1", title: "Beach", tags: ["Nature"])
        let library = try await scanned()
        #expect(library.wallpapers.map(\.title) == ["Beach"])

        try makeProject(in: workshop, id: "2", title: "City", type: "scene", tags: ["Urban"])
        library.refreshFolder(named: "2")
        #expect(library.wallpapers.map(\.title).sorted() == ["Beach", "City"])
        #expect(library.count(for: .scene) == 1)
        #expect(library.allTags == ["Nature", "Urban"])

        try makeProject(in: workshop, id: "1", title: "Beach at Night", tags: ["Night"])
        library.selectedPath = library.wallpapers.first { $0.title == "Beach" }?.libraryPath
        library.refreshFolder(named: "1")
        #expect(library.wallpapers.map(\.title).sorted() == ["Beach at Night", "City"])
        #expect(library.tagCount(for: "Nature") == 0)
        #expect(library.selectedWallpaper?.title == "Beach at Night")

        try FileManager.default.removeItem(at: workshop.appendingPathComponent("1"))
        library.refreshFolder(named: "1")
        #expect(library.wallpapers.map(\.title) == ["City"])
        #expect(library.selectedPath == nil)
        #expect(library.allTags == ["Urban"])

        library.refreshFolder(named: "never-existed")
        #expect(library.wallpapers.count == 1)
    }

    @Test func copiedFolderKeepsWinningOverWorkshopItem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeProject(in: copies, id: "7", title: "Copy")
        let library = try await scanned()

        try makeProject(in: workshop, id: "7", title: "Workshop")
        library.refreshFolder(named: "7")
        #expect(library.wallpapers.map(\.title) == ["Copy"])

        // Removing the copy reveals the Workshop item underneath it.
        try FileManager.default.removeItem(at: copies.appendingPathComponent("7"))
        library.refreshFolder(named: "7")
        #expect(library.wallpapers.map(\.title) == ["Workshop"])
    }

    @Test func refreshBeforeAnyScanDoesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeProject(in: workshop, id: "1", title: "Beach")
        let library = GalleryViewModel()
        library.refreshFolder(named: "1")
        #expect(library.wallpapers.isEmpty)
    }
}
