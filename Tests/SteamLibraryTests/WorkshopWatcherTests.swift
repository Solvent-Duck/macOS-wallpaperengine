import Foundation
import Testing
@testable import SteamLibrary

struct WorkshopSnapshotTests {
    @Test func reportsAddedUpdatedAndRemovedFolders() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.installItem("1")
        try steam.installItem("2")
        try steam.write(steam.manifest([("1", 100), ("2", 200)]), to: "steamapps/workshop/appworkshop_431960.acf")
        let before = WorkshopSnapshot.read([steam.library])
        #expect(before.installedIDs == ["1", "2"])

        try FileManager.default.removeItem(at: steam.library.contentDirectory.appendingPathComponent("1"))
        try steam.installItem("3")
        try steam.write(steam.manifest([("2", 250), ("3", 300)]), to: "steamapps/workshop/appworkshop_431960.acf")
        let after = WorkshopSnapshot.read([steam.library], previous: before)

        let changes = after.changes(since: before).map { "\($0.kind) \($0.id)" }
        #expect(changes == ["removed 1", "updated 2", "added 3"])
        #expect(after.changes(since: after).isEmpty)
    }

    @Test func ignoresFoldersWithoutProjectJSON() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try FileManager.default.createDirectory(at: steam.library.contentDirectory.appendingPathComponent("9"), withIntermediateDirectories: true)
        #expect(WorkshopSnapshot.read([steam.library]).entries.isEmpty)
    }

    @Test func itemBeingStagedKeepsItsPreviousEntry() throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.installItem("1")
        try steam.write(steam.manifest([("1", 100)]), to: "steamapps/workshop/appworkshop_431960.acf")
        let before = WorkshopSnapshot.read([steam.library])

        // Steam stages the update in downloads/ and rewrites the manifest before swapping folders.
        try FileManager.default.createDirectory(at: steam.library.downloadsDirectory.appendingPathComponent("1"), withIntermediateDirectories: true)
        try steam.write(steam.manifest([("1", 999)]), to: "steamapps/workshop/appworkshop_431960.acf")
        #expect(WorkshopSnapshot.read([steam.library], previous: before).changes(since: before).isEmpty)

        // A brand-new item that is still staging isn't reported yet.
        try steam.installItem("2")
        try FileManager.default.createDirectory(at: steam.library.downloadsDirectory.appendingPathComponent("2"), withIntermediateDirectories: true)
        #expect(WorkshopSnapshot.read([steam.library], previous: before).entries.keys.allSatisfy { !$0.hasSuffix("/2") })
    }
}

@MainActor
struct WorkshopFolderWatcherTests {
    @Test func reportsStatusThenFolderChanges() async throws {
        let steam = FakeSteam()
        defer { steam.remove() }
        try steam.write(#""users" { "76561197960265829" { "MostRecent" "1" } }"#, to: "config/loginusers.vdf")
        try steam.write(#""subscribedfiles" { "0" { "publishedfileid" "1" } "1" { "publishedfileid" "2" } }"#,
                        to: "userdata/101/ugc/431960_subscriptions.vdf")
        try steam.installItem("1")

        let watcher = WorkshopFolderWatcher(locator: SteamLibraryLocator(steamRoot: steam.root), settleDelay: 0.2)
        var deliveries: [([WorkshopChange], WorkshopStatus)] = []
        watcher.start { deliveries.append(($0, $1)) }
        defer { watcher.stop() }

        try await waitUntil { deliveries.count == 1 }
        #expect(deliveries[0].0.isEmpty)
        #expect(deliveries[0].1 == WorkshopStatus(subscribed: 2, installed: 1, notDownloadedIDs: ["2"]))

        try steam.installItem("2")
        try await waitUntil { deliveries.count >= 2 }
        #expect(deliveries[1].0.map(\.id) == ["2"])
        #expect(deliveries[1].0.first?.kind == .added)
        #expect(deliveries[1].1 == WorkshopStatus(subscribed: 2, installed: 2, notDownloadedIDs: []))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
