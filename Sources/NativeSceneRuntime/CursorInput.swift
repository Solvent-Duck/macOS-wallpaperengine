import Foundation

/// One normalized input sample received between rendered frames.
public struct CursorInputSample: Equatable, Sendable {
    public let position: RuntimeVector2
    public let leftDown: Bool

    public init(position: RuntimeVector2, leftDown: Bool) {
        self.position = position
        self.leftDown = leftDown
    }
}

/// Retains button boundaries and the latest movement in each button state.
/// Overflow cancels capture rather than replaying an unbounded input backlog.
public struct CursorInputQueue: Sendable {
    private var samples: [CursorInputSample] = []
    private var needsReset = false
    private var latest: CursorInputSample?
    public init() {}

    public mutating func append(_ sample: CursorInputSample) {
        guard sample.position.x.isFinite, sample.position.y.isFinite, sample != latest else { return }
        latest = sample
        if samples.count >= 2,
           samples[samples.count - 1].leftDown == sample.leftDown,
           samples[samples.count - 2].leftDown == sample.leftDown {
            samples[samples.count - 1] = sample
        } else if samples.count < 128 {
            samples.append(sample)
        } else {
            samples = [sample]
            needsReset = true
        }
    }

    public mutating func cancel() {
        // Retain the state at cancellation so a subsequent new press is not
        // mistaken for the old held button when rendering resumes.
        samples = latest.map { [$0] } ?? []
        needsReset = true
    }

    public mutating func drain() -> (samples: [CursorInputSample], reset: Bool) {
        let result = (samples, needsReset)
        samples.removeAll(keepingCapacity: true)
        needsReset = false
        return result
    }
}
