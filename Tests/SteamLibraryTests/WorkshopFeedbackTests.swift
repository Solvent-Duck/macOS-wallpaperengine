import Foundation
import Testing
@testable import SteamLibrary

@MainActor
@Suite(.serialized)
struct WorkshopFeedbackTests {
    let defaults = UserDefaults(suiteName: "WorkshopFeedbackTests-\(UUID().uuidString)")!

    func makeSync() -> (WorkshopSync, FakeHelper) {
        let helper = FakeHelper()
        let sync = WorkshopSync(launcher: { onEvent, onExit in
            helper.onEvent = onEvent
            helper.onExit = onExit
            return helper
        }, folderExists: { _ in true }, defaults: defaults, idleTimeout: .milliseconds(50))
        return (sync, helper)
    }

    @Test func feedbackLoadsOnlyWithAnOpenSession() {
        let (sync, helper) = makeSync()
        sync.loadFeedback(for: "5")
        #expect(!sync.isRunning)
        #expect(helper.sent.isEmpty)

        sync.sync()
        sync.loadFeedback(for: "5")
        sync.loadFeedback(for: "6")
        #expect(helper.sent == ["getvote 5", "favorites", "getvote 6"])
        helper.emit(#"{"event":"userVote","id":"5","result":1,"up":true,"down":false}"#)
        helper.emit(#"{"event":"favorites","result":1,"ids":["6","7"]}"#)
        #expect(sync.votes["5"] == .up)
        #expect(sync.favoriteIDs == ["6", "7"])
    }

    @Test func votingAndFavoritingUpdateState() {
        let (sync, helper) = makeSync()
        sync.vote("5", up: false)
        #expect(sync.isRunning)
        #expect(sync.pendingFeedback == ["5"])
        #expect(helper.sent == ["vote 5 down"])
        helper.emit(#"{"event":"voteResult","id":"5","result":1,"up":false}"#)
        #expect(sync.votes["5"] == .down)
        #expect(sync.pendingFeedback.isEmpty)

        sync.vote("5", up: false)
        #expect(helper.sent == ["vote 5 down"])

        sync.setFavorite("5", true)
        helper.emit(#"{"event":"favoriteResult","id":"5","result":1,"added":true}"#)
        #expect(sync.favoriteIDs == ["5"])
        sync.setFavorite("5", false)
        helper.emit(#"{"event":"favoriteResult","id":"5","result":1,"added":false}"#)
        #expect(sync.favoriteIDs == [])

        sync.vote("9", up: true)
        helper.emit(#"{"event":"voteResult","id":"9","result":2,"up":true}"#)
        #expect(sync.votes["9"] == nil)
        #expect(sync.lastActionError != nil)
    }

    @Test func favoritesAreForgottenWhenTheSessionEnds() {
        let (sync, helper) = makeSync()
        sync.sync()
        sync.loadFeedback(for: "1")
        helper.emit(#"{"event":"favorites","result":1,"ids":["1"]}"#)
        helper.quit()
        #expect(sync.favoriteIDs == nil)
    }
}
