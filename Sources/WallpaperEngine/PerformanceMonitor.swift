import Foundation

/// Lightweight performance diagnostics for frame timing and lifecycle events.
///
/// Maintains ring buffers of recent frame render times and lifecycle events.
/// Access via `PerformanceMonitor.shared`. Thread-safe for frame recording
/// (called from CVDisplayLink thread).
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    // MARK: - Frame Timing

    private let frameBufferSize = 300 // ~10s at 30fps
    private var frameTimes: [Double] // render time in ms
    private var frameIndex = 0
    private var frameCount = 0
    private var droppedFrames = 0
    private let frameBudgetMs = 33.3 // 30fps budget

    // MARK: - Lifecycle Events

    private let eventBufferSize = 100
    private var events: [(Date, String)]
    private var eventIndex = 0
    private var eventCount = 0

    private let lock = NSLock()

    private init() {
        frameTimes = [Double](repeating: 0, count: frameBufferSize)
        events = [(Date, String)](repeating: (Date.distantPast, ""), count: eventBufferSize)
    }

    /// Record a single frame's render time in milliseconds.
    /// Called from the CVDisplayLink callback thread.
    func recordFrame(renderTimeMs: Double) {
        lock.lock()
        frameTimes[frameIndex % frameBufferSize] = renderTimeMs
        frameIndex += 1
        frameCount += 1
        if renderTimeMs > frameBudgetMs {
            droppedFrames += 1
        }
        lock.unlock()
    }

    /// Log a lifecycle event with a timestamp.
    func logEvent(_ description: String) {
        lock.lock()
        events[eventIndex % eventBufferSize] = (Date(), description)
        eventIndex += 1
        eventCount += 1
        lock.unlock()
    }

    /// Generate a human-readable diagnostics summary.
    func summary() -> String {
        lock.lock()
        let fc = frameCount
        let dc = droppedFrames
        let count = min(fc, frameBufferSize)
        var times = [Double]()
        if count > 0 {
            let start = frameIndex - count
            for i in start..<frameIndex {
                times.append(frameTimes[i % frameBufferSize])
            }
        }

        let ec = min(eventCount, eventBufferSize)
        var recentEvents = [(Date, String)]()
        if ec > 0 {
            let start = eventIndex - ec
            for i in start..<eventIndex {
                recentEvents.append(events[i % eventBufferSize])
            }
        }
        lock.unlock()

        var lines = [String]()
        lines.append("=== WallpaperEngine Diagnostics ===")
        lines.append("")

        // Frame stats
        if times.isEmpty {
            lines.append("Frames: no data")
        } else {
            let sorted = times.sorted()
            let avg = times.reduce(0, +) / Double(times.count)
            let p99Index = min(Int(Double(sorted.count) * 0.99), sorted.count - 1)
            let p99 = sorted[p99Index]
            let droppedPct = fc > 0 ? Double(dc) / Double(fc) * 100.0 : 0
            lines.append("Frames: \(fc) total, \(dc) dropped (\(String(format: "%.1f", droppedPct))%)")
            lines.append("Frame time: avg \(String(format: "%.1f", avg))ms, p99 \(String(format: "%.1f", p99))ms (budget \(String(format: "%.1f", frameBudgetMs))ms)")
        }

        lines.append("")

        // Lifecycle events
        if recentEvents.isEmpty {
            lines.append("Lifecycle: no events")
        } else {
            lines.append("Lifecycle events (last \(recentEvents.count)):")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for (date, desc) in recentEvents {
                lines.append("  \(formatter.string(from: date))  \(desc)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
