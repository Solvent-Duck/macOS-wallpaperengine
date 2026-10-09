import Foundation
import Testing
@testable import WallpaperEngine

struct LibraryFoldersTests {
    private let workshop = URL(fileURLWithPath: "/Steam/steamapps/workshop/content/431960", isDirectory: true)
    private let projects = URL(fileURLWithPath: "/Users/me/Wallpaper Projects", isDirectory: true)
    private let custom = URL(fileURLWithPath: "/Volumes/Media/Wallpapers", isDirectory: true)

    @Test func steamFoldersComeFirstAndAnAddedFolderSupplementsThem() {
        #expect(LibraryFolders.ordered(workshop: [workshop], projects: projects, custom: custom) == [workshop, projects, custom])
        #expect(LibraryFolders.ordered(workshop: [workshop], projects: projects, custom: nil) == [workshop, projects])
    }

    @Test func hidingWorkshopKeepsTheOtherFolders() {
        #expect(LibraryFolders.ordered(workshop: [], projects: projects, custom: custom) == [projects, custom])
    }

    @Test func aFolderListedTwiceIsScannedOnce() {
        let sameAsWorkshop = URL(fileURLWithPath: "/Steam/steamapps/workshop/content/431960/", isDirectory: true)
        #expect(LibraryFolders.ordered(workshop: [workshop], projects: projects, custom: sameAsWorkshop) == [workshop, projects])
    }

    @Test func subscribedItemUsesSteamsCopyOverAManualCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELibraryFolders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appendingPathComponent("431960")
        let copies = root.appendingPathComponent("Wallpaper Projects")
        let added = root.appendingPathComponent("Added")
        try makeProject(in: steam, id: "100", title: "Steam")
        try makeProject(in: copies, id: "100", title: "Old copy")
        try makeProject(in: added, id: "100", title: "Another copy")
        try makeProject(in: added, id: "300", title: "Manual install")

        var seen = Set<String>()
        let projects = LibraryFolders.ordered(workshop: [steam], projects: copies, custom: added)
            .flatMap { GalleryViewModel.scanProjects(in: $0, skipping: &seen) }

        #expect(projects.map(\.title).sorted() == ["Manual install", "Steam"])
    }

    private func makeProject(in parent: URL, id: String, title: String) throws {
        let directory = parent.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("clip.mp4"))
        let json: [String: Any] = ["title": title, "type": "video", "file": "clip.mp4"]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("project.json"))
    }
}
