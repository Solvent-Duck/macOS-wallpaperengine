import Foundation
import Testing
@testable import WallpaperEngine

@MainActor
struct WorkshopLinksTests {
    @Test func opensInSteamWhenRunning() {
        #expect(WorkshopLinks.pageURL(for: "42", steamRunning: true).absoluteString == "steam://url/CommunityFilePage/42")
        #expect(WorkshopLinks.pageURL(for: "42", steamRunning: false).absoluteString
                == "https://steamcommunity.com/sharedfiles/filedetails/?id=42")
    }

    @Test func onlySteamsOwnCopiesCountAsWorkshopItems() throws {
        func project(at path: String) throws -> WallpaperProject {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELinks-\(UUID().uuidString)")
            let folder = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"title":"T","type":"video","file":"a.mp4"}"#.write(to: folder.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: root) }
            return try WallpaperLoader.load(from: folder, metadataOnly: true)
        }
        #expect(try project(at: "steamapps/workshop/content/431960/123").steamWorkshopID == "123")
        #expect(try project(at: "Wallpaper Projects/123").steamWorkshopID == nil)
        #expect(try project(at: "steamapps/workshop/content/431960/my copy").steamWorkshopID == nil)
    }
}
