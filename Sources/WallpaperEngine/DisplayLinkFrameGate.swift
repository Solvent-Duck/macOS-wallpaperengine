import Foundation

/// Coalesces refresh notifications while a frame is queued or rendering.
/// CVDisplayLink calls request() off the main thread; lifecycle and completion
/// calls run on the main thread. Every field is protected by the lock.
final class DisplayLinkFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var sequence: UInt64 = 0
    private var pending: UInt64?

    func start() {
        lock.withLock {
            active = true
            pending = nil
        }
    }

    func stop() {
        lock.withLock {
            active = false
            pending = nil
        }
    }

    func request() -> UInt64? {
        lock.withLock {
            guard active, pending == nil else { return nil }
            sequence &+= 1
            pending = sequence
            return sequence
        }
    }

    func isCurrent(_ ticket: UInt64) -> Bool {
        lock.withLock { active && pending == ticket }
    }

    func complete(_ ticket: UInt64) {
        lock.withLock {
            if pending == ticket { pending = nil }
        }
    }
}
