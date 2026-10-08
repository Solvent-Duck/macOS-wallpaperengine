import Foundation
import Testing
@testable import SteamLibrary

@MainActor
final class FakeHelper: WorkshopHelperConnection {
    var sent: [String] = []
    var onEvent: (@MainActor (WorkshopHelperEvent) -> Void)?
    var onExit: (@MainActor (Int32) -> Void)?

    func send(_ command: String) { sent.append(command) }
    func quit() { sent.append("quit"); onExit?(0) }
    func emit(_ line: String) { onEvent?(WorkshopHelperEvent.decode(line)!) }
}

struct WorkshopHelperEventTests {
    @Test func decodesHelperLines() {
        #expect(WorkshopHelperEvent.decode(#"{"event":"ready","steamID":"76561199000000000"}"#) == .ready(steamID: "76561199000000000"))
        #expect(WorkshopHelperEvent.decode(#"{"event":"progress","id":"5","state":53,"downloaded":10,"total":20}"#)
                == .progress(id: "5", state: 53, downloaded: 10, total: 20))
        #expect(WorkshopHelperEvent.decode(#"{"event":"downloadResult","id":"5","result":15}"#) == .downloadResult(id: "5", result: 15))
        guard case .subscriptions(true, let items)? = WorkshopHelperEvent.decode(
            #"{"event":"subscriptions","settled":true,"items":[{"id":"1","state":5,"folder":"/x/1","size":3,"timeUpdated":4}]}"#
        ) else { Issue.record("subscriptions"); return }
        #expect(items.first?.flags == [.subscribed, .installed])
        guard case .details(let details)? = WorkshopHelperEvent.decode(
            #"{"event":"details","items":[{"id":"1","result":1,"title":"White \"Valley\"","tags":"Scene,Anime","preview":"https://x/p.jpg","fileSize":12}]}"#
        ) else { Issue.record("details"); return }
        #expect(details.first?.title == "White \"Valley\"")
        #expect(WorkshopHelperEvent.decode("not json") == nil)
        #expect(WorkshopHelperEvent.decode(#"{"event":"future"}"#) == nil)
    }
}

@MainActor
@Suite(.serialized)
struct WorkshopSyncTests {
    let defaults = UserDefaults(suiteName: "WorkshopSyncTests-\(UUID().uuidString)")!

    func makeSync(existing: Set<String> = [], helper: FakeHelper = FakeHelper(), idle: Duration = .milliseconds(50)) -> (WorkshopSync, FakeHelper) {
        let sync = WorkshopSync(launcher: { onEvent, onExit in
            helper.onEvent = onEvent
            helper.onExit = onExit
            return helper
        }, folderExists: { existing.contains($0) }, defaults: defaults, idleTimeout: idle)
        return (sync, helper)
    }

    @Test func downloadsMissingStaleAndOutdatedItemsOnly() {
        let (sync, helper) = makeSync(existing: ["/w/1", "/w/3", "/w/4"])
        sync.sync()
        helper.emit(#"{"event":"ready","steamID":"1"}"#)
        helper.emit(#"""
        {"event":"subscriptions","settled":true,"items":[
          {"id":"1","state":5,"folder":"/w/1","size":1,"timeUpdated":1},
          {"id":"2","state":5,"folder":"/w/2","size":1,"timeUpdated":1},
          {"id":"3","state":13,"folder":"/w/3","size":1,"timeUpdated":1},
          {"id":"4","state":5,"folder":"/w/4","size":1,"timeUpdated":1},
          {"id":"5","state":1,"folder":"","size":0,"timeUpdated":0}]}
        """#.replacingOccurrences(of: "\n", with: ""))
        #expect(sync.downloads.map(\.id) == ["2", "3", "5"])
        #expect(helper.sent == ["details 2 3 5", "download 2 3 5"])
        #expect(sync.phase == .syncing)
    }

    @Test func progressDetailsAndResultsUpdateDownloads() {
        let (sync, helper) = makeSync()
        sync.sync()
        helper.emit(#"{"event":"subscriptions","settled":true,"items":[{"id":"7","state":1,"folder":"","size":0,"timeUpdated":0},{"id":"8","state":1,"folder":"","size":0,"timeUpdated":0}]}"#)
        helper.emit(#"{"event":"details","items":[{"id":"7","result":1,"title":"Lake","tags":"","preview":"https://p/7.jpg","fileSize":900},{"id":"8","result":15,"title":"","tags":"","preview":"","fileSize":0}]}"#)
        #expect(sync.downloads.first { $0.id == "7" }?.title == "Lake")
        #expect(sync.downloads.first { $0.id == "7" }?.size == 900)
        #expect(sync.downloads.first { $0.id == "8" }?.status == .unavailable)
        #expect(sync.unavailableIDs == ["8"])

        helper.emit(#"{"event":"progress","id":"7","state":53,"downloaded":300,"total":900}"#)
        #expect(sync.downloads.first?.status == .downloading(downloaded: 300, total: 900))
        helper.emit(#"{"event":"downloadResult","id":"7","result":1}"#)
        #expect(sync.activeDownloads.isEmpty)
        #expect(sync.downloads.map(\.id) == ["8"])
    }

    @Test func endsTheSessionOnceIdleAndRecordsTheSync() async throws {
        let (sync, helper) = makeSync()
        sync.sync()
        helper.emit(#"{"event":"subscriptions","settled":true,"items":[{"id":"7","state":1,"folder":"","size":0,"timeUpdated":0}]}"#)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!helper.sent.contains("quit"))

        helper.emit(#"{"event":"downloadResult","id":"7","result":1}"#)
        try await Task.sleep(for: .milliseconds(150))
        #expect(helper.sent.last == "quit")
        #expect(sync.phase == .idle)
        #expect(sync.lastSync != nil)
        #expect(!sync.isRunning)
    }

    @Test func unavailableItemsAreRememberedAndSkippedUntilRetried() {
        let (sync, helper) = makeSync()
        sync.sync()
        helper.emit(#"{"event":"subscriptions","settled":true,"items":[{"id":"9","state":1,"folder":"","size":0,"timeUpdated":0}]}"#)
        helper.emit(#"{"event":"downloadResult","id":"9","result":15}"#)
        helper.quit()

        let (again, helper2) = makeSync()
        #expect(again.unavailableIDs == ["9"])
        again.sync()
        helper2.emit(#"{"event":"subscriptions","settled":true,"items":[{"id":"9","state":1,"folder":"","size":0,"timeUpdated":0}]}"#)
        #expect(helper2.sent.isEmpty)
        #expect(again.downloads.map(\.status) == [.unavailable])

        again.retryUnavailable()
        #expect(again.downloads.isEmpty)
        again.sync()
        #expect(helper2.sent == ["refresh"])
    }

    @Test func helperErrorsBecomeProblems() {
        let (sync, helper) = makeSync()
        sync.sync()
        helper.emit(#"{"event":"error","code":"steamNotRunning","message":"no"}"#)
        helper.onExit?(3)
        #expect(sync.phase == .problem(.steamNotRunning))

        let crashing = FakeHelper()
        let (other, _) = makeSync(helper: crashing)
        other.sync()
        crashing.onExit?(9)
        guard case .problem(.failed) = other.phase else { Issue.record("expected failure"); return }

        let missing = WorkshopSync(launcher: { _, _ in throw WorkshopSync.Problem.helperMissing }, defaults: defaults)
        missing.sync()
        #expect(missing.phase == .problem(.helperMissing))
    }

    @Test func newSubscriptionDuringSessionIsDownloaded() {
        let (sync, helper) = makeSync()
        sync.sync()
        helper.emit(#"{"event":"subscriptions","settled":true,"items":[]}"#)
        helper.emit(#"{"event":"subscribed","id":"42"}"#)
        #expect(sync.downloads.map(\.id) == ["42"])
        #expect(helper.sent == ["details 42", "download 42"])
        helper.emit(#"{"event":"unsubscribed","id":"42"}"#)
        #expect(sync.downloads.isEmpty)
    }
}
