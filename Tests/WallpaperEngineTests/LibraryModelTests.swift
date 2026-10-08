import Foundation
import Testing
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct LibraryModelTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELibrary-\(UUID().uuidString)")

    private func makeProject(_ id: String, type: String, title: String, tags: [String]) throws {
        let directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = ["title": title, "type": type, "file": type == "scene" ? "scene.json" : "main.file", "tags": tags]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("project.json"))
    }

    private func scannedLibrary() async throws -> GalleryViewModel {
        try makeProject("1", type: "video", title: "Beach", tags: ["Nature"])
        try makeProject("2", type: "scene", title: "Anime Room", tags: ["Anime", "Relaxing"])
        try makeProject("3", type: "scene", title: "Forest", tags: ["Nature", "Relaxing"])
        let library = GalleryViewModel()
        library.scan(directories: [root])
        let deadline = ContinuousClock.now + .seconds(10)
        while library.isScanning || library.wallpapers.isEmpty {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        return library
    }

    @Test func sidebarFiltersCountsAndSearch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await scannedLibrary()
        library.sortOrder = .titleAscending

        #expect(library.filteredWallpapers.map(\.title) == ["Anime Room", "Beach", "Forest"])
        #expect(library.availableTypes == [.scene, .video])
        #expect(library.count(for: .scene) == 2)
        #expect(library.tagCount(for: "Relaxing") == 2)

        library.filter = .type(.scene)
        #expect(library.filteredWallpapers.map(\.title) == ["Anime Room", "Forest"])
        library.filter = .tag("Nature")
        #expect(library.filteredWallpapers.map(\.title) == ["Beach", "Forest"])
        library.searchText = "for"
        #expect(library.filteredWallpapers.map(\.title) == ["Forest"])
    }

    @Test func recentFilterKeepsRecencyOrder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await scannedLibrary()
        let paths = library.wallpapers.reduce(into: [String: String]()) { $0[$1.title] = $1.libraryPath }
        library.recentPaths = { [paths["Forest"]!, paths["Beach"]!] }
        library.filter = .recent
        #expect(library.filteredWallpapers.map(\.title) == ["Forest", "Beach"])
    }

    @Test func favoritesPersistByFolderName() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = UserDefaults.standard.object(forKey: "FavoriteWallpapers")
        defer { UserDefaults.standard.set(saved, forKey: "FavoriteWallpapers") }
        UserDefaults.standard.removeObject(forKey: "FavoriteWallpapers")

        let library = try await scannedLibrary()
        let forest = try #require(library.wallpapers.first { $0.title == "Forest" })
        library.toggleFavorite(forest)
        library.filter = .favorites
        #expect(library.filteredWallpapers.map(\.title) == ["Forest"])
        #expect(GalleryViewModel().favorites == ["3"])
        library.toggleFavorite(forest)
        #expect(library.filteredWallpapers.isEmpty)
    }

    @Test func metadataOnlyLoadSkipsTheSceneParseButKeepsListingFields() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeProject("9", type: "scene", title: "Forest", tags: ["Nature"])
        let project = try WallpaperLoader.load(from: root.appendingPathComponent("9"), metadataOnly: true)
        #expect(project.sceneDescription == nil)
        #expect(project.title == "Forest" && project.type == .scene && project.tags == ["Nature"])
        #expect(project.libraryPath == root.appendingPathComponent("9").standardizedFileURL.path)
    }
}
