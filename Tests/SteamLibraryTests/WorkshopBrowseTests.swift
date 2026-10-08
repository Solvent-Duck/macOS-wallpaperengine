import Foundation
import Testing
@testable import SteamLibrary

@MainActor
@Suite(.serialized)
struct WorkshopBrowseTests {
    let defaults = UserDefaults(suiteName: "WorkshopBrowseTests-\(UUID().uuidString)")!

    func makeSync(idle: Duration = .milliseconds(50)) -> (WorkshopSync, FakeHelper) {
        let helper = FakeHelper()
        let sync = WorkshopSync(launcher: { onEvent, onExit in
            helper.onEvent = onEvent
            helper.onExit = onExit
            return helper
        }, folderExists: { _ in true }, defaults: defaults, idleTimeout: idle)
        return (sync, helper)
    }

    static func item(_ id: String, state: Int = 0) -> String {
        #"{"id":"\#(id)","result":1,"title":"Item \#(id)","tags":"Scene,Nature,Everyone","preview":"https://p/\#(id).jpg","fileSize":10,"description":"[b]Hi[/b] there","votesUp":90,"votesDown":10,"score":0.9,"subscriptions":1000,"timeUpdated":1700000000,"state":\#(state)}"#
    }

    @Test func queryCommandEncodesFiltersAndText() {
        let query = WorkshopQuery(sort: .popular, text: "rain & window", type: nil, tag: "Pixel art", ratings: ["Everyone", "Questionable"])
        #expect(query.command(request: 3, page: 2)
                == "browse request=3 sort=popular page=2 days=7 types=Scene%2CVideo%2CWeb ratings=Everyone%2CQuestionable tag=Pixel%20art text=rain%20%26%20window")
        #expect(WorkshopQuery(type: "Video").command(request: 1, page: 1).contains("types=Video "))
    }

    @Test func decodesCatalogueItems() throws {
        guard case .browseResults(7, 1, 1234, let items)? = WorkshopHelperEvent.decode(
            #"{"event":"browseResults","request":7,"result":1,"total":1234,"items":[\#(Self.item("5", state: 1))]}"#
        ) else { Issue.record("browseResults"); return }
        let item = try #require(items.first)
        #expect(item.tags == ["Scene", "Nature", "Everyone"])
        #expect(item.type == "Scene")
        #expect(item.rating == "Everyone")
        #expect(item.previewURL == URL(string: "https://p/5.jpg"))
        #expect(item.timeUpdated == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func searchPagesAndIgnoresStaleResults() {
        let (sync, helper) = makeSync()
        sync.search(WorkshopQuery())
        #expect(sync.isRunning)
        #expect(sync.browse.isLoading)
        #expect(helper.sent.last?.hasPrefix("browse request=1 ") == true)

        // A newer search makes request 1's answer stale.
        sync.search(WorkshopQuery(text: "lake"))
        helper.emit(#"{"event":"browseResults","request":1,"result":1,"total":9,"items":[\#(Self.item("1"))]}"#)
        #expect(sync.browse.items.isEmpty)

        helper.emit(#"{"event":"browseResults","request":2,"result":1,"total":3,"items":[\#(Self.item("1")),\#(Self.item("2", state: 1))]}"#)
        #expect(sync.browse.items.map(\.id) == ["1", "2"])
        #expect(sync.subscribedIDs == ["2"])
        #expect(sync.browse.canLoadMore)

        sync.loadMore()
        #expect(helper.sent.last?.contains("request=3 ") == true)
        #expect(helper.sent.last?.contains("page=2 ") == true)
        helper.emit(#"{"event":"browseResults","request":3,"result":1,"total":3,"items":[\#(Self.item("2")),\#(Self.item("3"))]}"#)
        #expect(sync.browse.items.map(\.id) == ["1", "2", "3"])
        #expect(!sync.browse.canLoadMore)
        sync.loadMore()
        #expect(helper.sent.last?.contains("request=3 ") == true)
    }

    @Test func failedQueryReportsAnError() {
        let (sync, helper) = makeSync()
        sync.search(WorkshopQuery())
        helper.emit(#"{"event":"browseResults","request":1,"result":2,"total":0,"items":[]}"#)
        #expect(!sync.browse.isLoading)
        #expect(sync.browse.error != nil)
    }

    @Test func subscribingDownloadsEvenWhenAutomaticSyncIsOff() {
        let (sync, helper) = makeSync()
        sync.downloadsSubscriptions = false
        sync.subscribe("42")
        #expect(sync.pendingSubscriptionChanges == ["42"])
        #expect(helper.sent == ["subscribe 42"])

        // Automatic sync is off, so a missing subscription isn't fetched…
        helper.emit(#"{"event":"subscriptions","settled":true,"items":[{"id":"9","state":1,"folder":"","size":0,"timeUpdated":0}]}"#)
        #expect(sync.downloads.isEmpty)
        #expect(sync.subscribedIDs == ["9"])

        // …but the one the user just subscribed to is.
        helper.emit(#"{"event":"subscribeResult","id":"42","result":1}"#)
        #expect(sync.pendingSubscriptionChanges.isEmpty)
        #expect(sync.subscribedIDs == ["9", "42"])
        #expect(sync.downloads.map(\.id) == ["42"])
        #expect(helper.sent.suffix(2) == ["details 42", "download 42"])
    }

    @Test func unsubscribeAndRefusals() {
        let (sync, helper) = makeSync()
        sync.subscribe("1")
        helper.emit(#"{"event":"subscribeResult","id":"1","result":15}"#)
        #expect(sync.lastSubscriptionError != nil)
        #expect(!sync.subscribedIDs.contains("1"))

        helper.emit(#"{"event":"subscriptions","settled":true,"items":[{"id":"2","state":5,"folder":"/w/2","size":1,"timeUpdated":1}]}"#)
        sync.unsubscribe("2")
        #expect(sync.lastSubscriptionError == nil)
        helper.emit(#"{"event":"unsubscribeResult","id":"2","result":1}"#)
        #expect(sync.subscribedIDs.isEmpty)
    }

    @Test func browsingKeepsTheSessionOpen() async throws {
        let (sync, helper) = makeSync()
        sync.beginBrowsing()
        sync.search(WorkshopQuery())
        helper.emit(#"{"event":"subscriptions","settled":true,"items":[]}"#)
        helper.emit(#"{"event":"browseResults","request":1,"result":1,"total":0,"items":[]}"#)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sync.isRunning)

        sync.endBrowsing()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!sync.isRunning)
        #expect(helper.sent.last == "quit")
    }
}
