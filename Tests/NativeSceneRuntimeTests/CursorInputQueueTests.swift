import NativeSceneRuntime
import Testing

struct CursorInputQueueTests {
    @Test func coalescingPreservesPressLocationAndRelease() {
        var queue = CursorInputQueue()
        for (x,down) in [(0.1,false),(0.2,true),(0.3,true),(0.4,true),(0.5,false)] {
            queue.append(.init(position: .init(x: Float(x), y: 0.5), leftDown: down))
        }
        let batch = queue.drain()
        #expect(batch.samples.map(\.position.x) == [0.1,0.2,0.4,0.5])
        #expect(batch.samples.map(\.leftDown) == [false,true,true,false])
        #expect(!batch.reset)
        #expect(queue.drain().samples.isEmpty)
    }
    @Test func overflowAndPauseCancelCaptureAndBoundBacklog() {
        var queue = CursorInputQueue()
        for index in 0..<1000 { queue.append(.init(position: .init(x: 0.5, y: 0.5), leftDown: index.isMultiple(of: 2))) }
        let batch = queue.drain()
        #expect(batch.reset && batch.samples.count <= 128)
        queue.append(.init(position: .init(x: 0.6, y: 0.5), leftDown: true))
        queue.cancel()
        let cancelled = queue.drain()
        #expect(cancelled.samples == [.init(position: .init(x: 0.6, y: 0.5), leftDown: true)] && cancelled.reset)
        #expect(!queue.drain().reset)
    }
    @Test func unchangedOrInvalidPositionsDoNotAccumulate() {
        var queue = CursorInputQueue()
        let sample = CursorInputSample(position: .init(x: 0.5, y: 0.5), leftDown: false)
        for _ in 0..<500 { queue.append(sample) }
        queue.append(.init(position: .init(x: .nan, y: 0), leftDown: true))
        #expect(queue.drain().samples == [sample])
    }
}
