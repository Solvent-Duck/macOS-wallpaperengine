import Foundation
import Testing
@testable import WallpaperEngine

struct GalleryScanTests {
    @Test func earlierDirectoryWinsForDuplicateWallpaperFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEGalleryScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let copies = root.appendingPathComponent("Wallpaper Projects")
        let workshop = root.appendingPathComponent("431960")
        try makeProject(in: copies, id: "100", title: "Copied")
        try makeProject(in: workshop, id: "100", title: "Workshop")
        try makeProject(in: workshop, id: "200", title: "Only Workshop")

        var seen = Set<String>()
        let projects = GalleryViewModel.scanProjects(in: copies, skipping: &seen)
            + GalleryViewModel.scanProjects(in: workshop, skipping: &seen)

        #expect(projects.map(\.title).sorted() == ["Copied", "Only Workshop"])
    }

    @Test func missingDirectoryScansToNothing() {
        var seen = Set<String>()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("WEGalleryMissing-\(UUID().uuidString)")
        #expect(GalleryViewModel.scanProjects(in: missing, skipping: &seen).isEmpty)
    }

    private func makeProject(in parent: URL, id: String, title: String) throws {
        let directory = parent.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("clip.mp4"))
        let json: [String: Any] = ["title": title, "type": "video", "file": "clip.mp4"]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("project.json"))
    }
}
