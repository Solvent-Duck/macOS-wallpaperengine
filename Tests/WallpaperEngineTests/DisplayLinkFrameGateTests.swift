import Testing
@testable import WallpaperEngine

struct DisplayLinkFrameGateTests {
    @Test func refreshBurstsKeepOneFramePendingUntilItFinishes() throws {
        let frames = DisplayLinkFrameGate()
        #expect(frames.request() == nil)
        frames.start()
        let queued = try #require(frames.request())
        // Refreshes arrive both before dispatch and during a slow frame.
        for _ in 0..<10_000 { #expect(frames.request() == nil) }
        #expect(frames.isCurrent(queued))
        frames.complete(queued)
        let next = try #require(frames.request())
        #expect(next != queued)
        #expect(frames.isCurrent(next))
        #expect(!frames.isCurrent(queued))
    }

    @Test func pauseAndRestartDiscardOldCallbacksWithoutClearingNewWork() throws {
        let frames = DisplayLinkFrameGate()
        frames.start()
        let stale = try #require(frames.request())
        frames.stop()
        #expect(!frames.isCurrent(stale))
        #expect(frames.request() == nil)
        frames.start()
        let current = try #require(frames.request())
        frames.complete(stale)
        #expect(frames.isCurrent(current))
        #expect(frames.request() == nil)
        frames.complete(current)
        #expect(frames.request() != nil)
        frames.stop()
        frames.stop()
        #expect(frames.request() == nil)
    }

    @Test func concurrentRefreshesCannotReserveMultipleFrames() async throws {
        let frames = DisplayLinkFrameGate()
        frames.start()
        let tickets = await withTaskGroup(of: UInt64?.self, returning: [UInt64].self) { group in
            for _ in 0..<1_000 { group.addTask { frames.request() } }
            var tickets: [UInt64] = []
            for await ticket in group {
                if let ticket { tickets.append(ticket) }
            }
            return tickets
        }
        #expect(tickets.count == 1)
        let ticket = try #require(tickets.first)
        #expect(frames.isCurrent(ticket))
        frames.complete(ticket)
        #expect(frames.request() != nil)
    }
}
