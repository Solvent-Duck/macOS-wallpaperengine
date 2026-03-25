import Foundation
import Darwin

/// Lightweight performance diagnostics for frame timing and lifecycle events.
///
/// Maintains ring buffers of recent frame timings (total, engine, blit, interval)
/// and timestamped lifecycle events. Access via `PerformanceMonitor.shared`.
/// Thread-safe — `recordFrame` is called from the CVDisplayLink thread.
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    // MARK: - Renderer Identity

    private var _rendererType: String = "None"
    private var _rendererStatus: String = "Stopped"

    // MARK: - Frame Timing

    private let bufferSize = 300        // ~10s at 30fps
    private var frameTimes: [Double]    // total render time ms
    private var engineTimes: [Double]   // we_render_frame ms (CPU stall ≈ GPU work)
    private var blitTimes: [Double]     // blit quad + buffer flush ms
    private var frameIntervals: [Double] // wall-clock ms between frames (for FPS)
    private var frameIndex = 0
    private var frameCount = 0
    private var droppedFrames = 0
    private let frameBudgetMs = 33.3    // 30fps target

    // MARK: - Lifecycle Events

    private let eventBufferSize = 100
    private var events: [(Date, String)]
    private var eventIndex = 0
    private var eventCount = 0

    private let lock = NSLock()

    private init() {
        frameTimes    = [Double](repeating: 0, count: bufferSize)
        engineTimes   = [Double](repeating: 0, count: bufferSize)
        blitTimes     = [Double](repeating: 0, count: bufferSize)
        frameIntervals = [Double](repeating: 0, count: bufferSize)
        events        = [(Date, String)](repeating: (Date.distantPast, ""), count: eventBufferSize)
    }

    // MARK: - Recording

    /// Record a frame's timing. All values in milliseconds.
    /// - `totalMs`: wall-clock time for the entire render call.
    /// - `engineMs`: time for `we_render_frame` (stalls until GPU finishes).
    /// - `blitMs`: time for the blit quad draw + buffer flush.
    /// - `intervalMs`: wall-clock time since the previous frame (used for FPS).
    func recordFrame(totalMs: Double, engineMs: Double = 0, blitMs: Double = 0, intervalMs: Double = 0) {
        lock.lock()
        let idx = frameIndex % bufferSize
        frameTimes[idx]    = totalMs
        engineTimes[idx]   = engineMs
        blitTimes[idx]     = blitMs
        frameIntervals[idx] = intervalMs > 0 ? intervalMs : totalMs
        frameIndex  += 1
        frameCount  += 1
        if totalMs > frameBudgetMs { droppedFrames += 1 }
        lock.unlock()
    }

    /// Backward-compatible single-argument overload.
    func recordFrame(renderTimeMs: Double) {
        recordFrame(totalMs: renderTimeMs)
    }

    func logEvent(_ description: String) {
        lock.lock()
        events[eventIndex % eventBufferSize] = (Date(), description)
        eventIndex += 1
        eventCount += 1
        lock.unlock()
    }

    /// Update the active renderer identity (call on main thread).
    func setRenderer(type: String, status: String) {
        lock.lock()
        _rendererType   = type
        _rendererStatus = status
        lock.unlock()
    }

    func setRendererStatus(_ status: String) {
        lock.lock()
        _rendererStatus = status
        lock.unlock()
    }

    // MARK: - Live Queries

    /// Approximate current FPS from the last 30 frame intervals.
    var currentFPS: Double {
        lock.lock()
        let count = min(frameCount, bufferSize)
        guard count > 0 else { lock.unlock(); return 0 }
        let sampleCount = min(count, 30)
        let start = frameIndex - sampleCount
        var sum = 0.0
        for i in start..<frameIndex {
            sum += frameIntervals[i % bufferSize]
        }
        lock.unlock()
        let avgInterval = sum / Double(sampleCount)
        return avgInterval > 0 ? 1000.0 / avgInterval : 0
    }

    // MARK: - Memory

    /// Process resident set size in bytes.
    static func processMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    // MARK: - Diagnostics Summary

    func summary() -> String {
        lock.lock()
        let fc        = frameCount
        let dc        = droppedFrames
        let rType     = _rendererType
        let rStatus   = _rendererStatus
        let count     = min(fc, bufferSize)

        var totalArr    = [Double]()
        var engineArr   = [Double]()
        var blitArr     = [Double]()
        var intervalArr = [Double]()

        if count > 0 {
            let start = frameIndex - count
            for i in start..<frameIndex {
                let idx = i % bufferSize
                totalArr.append(frameTimes[idx])
                engineArr.append(engineTimes[idx])
                blitArr.append(blitTimes[idx])
                intervalArr.append(frameIntervals[idx])
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

        let memMB = Double(Self.processMemoryBytes()) / (1024.0 * 1024.0)

        var lines = [String]()
        lines.append("=== WallpaperEngine Diagnostics ===")
        lines.append("")
        lines.append("Renderer: \(rType)  |  Status: \(rStatus)")
        lines.append("")

        if totalArr.isEmpty {
            lines.append("Frames: no data")
        } else {
            // FPS from frame intervals
            let validIntervals = intervalArr.filter { $0 > 0 }
            let recent = Array(validIntervals.suffix(30))
            let avgInterval = recent.isEmpty ? 0.0 : recent.reduce(0, +) / Double(recent.count)
            let fps = avgInterval > 0 ? 1000.0 / avgInterval : 0
            let droppedPct = fc > 0 ? Double(dc) / Double(fc) * 100.0 : 0
            let target = String(format: "%.0f", 1000.0 / frameBudgetMs)

            lines.append("FPS:     \(String(format: "%.1f", fps)) (target \(target)fps / \(String(format: "%.1f", frameBudgetMs))ms)")
            lines.append("Frames:  \(fc) total, \(dc) dropped (\(String(format: "%.1f", droppedPct))%)")
            lines.append("")

            lines.append("CPU frame timing (last \(totalArr.count) frames):")
            lines.append(timingLine("  Total ", totalArr))
            if engineArr.contains(where: { $0 > 0 }) {
                lines.append(timingLine("  Engine", engineArr))  // we_render_frame (GPU sync)
                lines.append(timingLine("  Blit  ", blitArr))    // quad draw + buffer flush
            }
        }

        lines.append("")
        lines.append(String(format: "Memory:  RSS %.1f MB", memMB))

        lines.append("")
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

    // MARK: - Helpers

    private func timingLine(_ label: String, _ arr: [Double]) -> String {
        guard !arr.isEmpty else { return "\(label):  no data" }
        let sorted = arr.sorted()
        let avg = arr.reduce(0, +) / Double(arr.count)
        let min = sorted.first!
        let max = sorted.last!
        let p99 = sorted[Swift.min(Int(Double(sorted.count) * 0.99), sorted.count - 1)]
        return String(format: "%@:  avg %5.1fms  min %5.1fms  max %5.1fms  p99 %5.1fms",
                      label, avg, min, max, p99)
    }
}
