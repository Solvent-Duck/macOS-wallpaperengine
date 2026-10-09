import Foundation

/// Wall-clock source for scene features that follow the real time of day.
///
/// Setting `WE_DETERMINISTIC` pins the clock (and, in the script host, JS
/// `Date` and `Math.random`) so headless captures are reproducible across
/// runs. Pair it with `TZ=UTC` so local-time fields match on every machine.
public enum SceneClock {
    /// 2026-01-01 12:00:00 UTC. Must match `WE_PINNED_EPOCH_MS` in
    /// ScriptHostBridge.c. Noon keeps day/night scenes in their day state.
    public static let pinnedEpoch: TimeInterval = 1_767_268_800

    public static let isPinned = ProcessInfo.processInfo.environment["WE_DETERMINISTIC"] != nil

    public static func now() -> Date {
        isPinned ? Date(timeIntervalSince1970: pinnedEpoch) : Date()
    }
}
