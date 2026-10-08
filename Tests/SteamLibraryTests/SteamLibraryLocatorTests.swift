import Foundation
import Testing
@testable import SteamLibrary

/// Builds a fake Steam folder modeled on a real macOS install (IDs anonymized).
struct FakeSteam {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeSteam-\(UUID().uuidString)", isDirectory: true)
    var library: WorkshopLibrary { WorkshopLibrary(workshopDirectory: root.appendingPathComponent("steamapps/workshop", isDirectory: true)) }

    func write(_ text: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func installItem(_ id: String, in library: WorkshopLibrary? = nil, title: String = "Item") throws {
        let folder = (library ?? self.library).contentDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"title":"\#(title)","type":"video","file":"a.mp4"}"#.write(to: folder.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
    }

    func manifest(_ items: [(id: String, time: Int)]) -> String {
        let entries = items.map { "\t\t\"\($0.id)\"\n\t\t{\n\t\t\t\"size\"\t\t\"1000\"\n\t\t\t\"timeupdated\"\t\t\"\($0.time)\"\n\t\t\t\"manifest\"\t\t\"42\"\n\t\t}" }
        return "\"AppWorkshop\"\n{\n\t\"appid\"\t\t\"431960\"\n\t\"WorkshopItemsInstalled\"\n\t{\n\(entries.joined(separator: "\n"))\n\t}\n}\n"
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct SteamLibraryLocatorTests {
    @Test func listsSteamRootThenExtraLibrariesWithoutDuplicates() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.write("""
        "libraryfolders"
        {
            "0" { "path" "\(steam.root.path)" "label" "" }
            "1" { "path" "/Volumes/Games/SteamLibrary" }
        }
        """, to: "steamapps/libraryfolders.vdf")

        let locator = SteamLibraryLocator(steamRoot: steam.root)
        #expect(locator.libraryFolders().map(\.path) == [steam.root.standardizedFileURL.path, "/Volumes/Games/SteamLibrary"])
        #expect(locator.workshopLibraries().map(\.contentDirectory.path) == [
            steam.root.appendingPathComponent("steamapps/workshop/content/431960").path,
            "/Volumes/Games/SteamLibrary/steamapps/workshop/content/431960",
        ])
    }

    @Test func missingLibraryListStillYieldsSteamRoot() {
        let locator = SteamLibraryLocator(steamRoot: URL(fileURLWithPath: "/nonexistent-steam-\(UUID().uuidString)"))
        #expect(locator.libraryFolders().count == 1)
        #expect(locator.contentDirectories().isEmpty)
        #expect(locator.subscriptionsURL() == nil)
    }

    @Test func findsMostRecentAccountsSubscriptions() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.write("""
        "users"
        {
            "76561197960265829" { "AccountName" "other" "MostRecent" "0" }
            "76561199000000000" { "AccountName" "me" "MostRecent" "1" }
        }
        """, to: "config/loginusers.vdf")
        let locator = SteamLibraryLocator(steamRoot: steam.root)
        #expect(locator.currentAccountID() == 76_561_199_000_000_000 - 76_561_197_960_265_728)
        #expect(locator.subscriptionsURL()?.path.hasSuffix("userdata/1039734272/ugc/431960_subscriptions.vdf") == true)
    }

    @Test func singleAccountWithoutMostRecentIsUsed() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.write(#""users" { "76561197960265829" { "AccountName" "solo" } }"#, to: "config/loginusers.vdf")
        #expect(SteamLibraryLocator(steamRoot: steam.root).currentAccountID() == 101)
    }

    @Test func readsManifestAndSubscriptions() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.write(steam.manifest([("860265906", 1486851360), ("910422926", 1492873141)]), to: "steamapps/workshop/appworkshop_431960.acf")
        let manifest = WorkshopManifest.load(from: steam.library.manifestURL)
        #expect(manifest.items["860265906"]?.timeUpdated == 1486851360)
        #expect(manifest.items["910422926"]?.size == 1000)
        #expect(WorkshopManifest.load(from: steam.root.appendingPathComponent("missing.acf")).items.isEmpty)

        try steam.write("""
        "subscribedfiles"
        {
            "appid" "431960"
            "0" { "publishedfileid" "2157374679" "time_subscribed" "1790386203" "disabled_locally" "0" }
            "1" { "publishedfileid" "2621445832" "disabled_locally" "1" }
            "2" { "publishedfileid" "860265906" }
        }
        """, to: "subs.vdf")
        #expect(WorkshopSubscriptions.load(from: steam.root.appendingPathComponent("subs.vdf"))?.ids == ["2157374679", "860265906"])
        #expect(WorkshopSubscriptions.load(from: steam.root.appendingPathComponent("missing.vdf")) == nil)
    }
}
