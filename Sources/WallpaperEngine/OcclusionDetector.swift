import AppKit

/// Detects when desktop windows are fully occluded by other application
/// windows, allowing the renderer to pause and save resources.
///
/// This is the single most impactful performance optimization: the wallpaper
/// is covered by other windows ~90% of the time for most users. When fully
/// occluded, rendering is completely paused (zero GPU/CPU draw).
///
/// Two signals are combined. NSWindow's `occlusionState` (updated by the
/// WindowServer) catches spaces, sleep and full-screen apps, but desktop-level
/// windows keep reporting visible while ordinary windows cover them. A cheap
/// once-a-second check of the on-screen window list catches that case.
@MainActor
class OcclusionDetector {
    private var observations: [NSKeyValueObservation] = []
    private var onVisibilityChanged: ((Bool) -> Void)?
    private var trackedWindows: [DesktopWindow] = []
    private var hasEverBeenVisible = false
    private var coverageTimer: Timer?
    private var coveredWindows: Set<ObjectIdentifier> = []

    /// Start observing occlusion state for the given desktop windows.
    ///
    /// - Parameter callback: Called with `true` when any desktop window becomes
    ///   visible, `false` when all are fully occluded.
    func observe(windows: [DesktopWindow], onVisibilityChanged: @escaping (Bool) -> Void) {
        stop()

        self.onVisibilityChanged = onVisibilityChanged
        self.trackedWindows = windows

        for window in windows {
            let observation = window.observe(\.occlusionState, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.evaluateVisibility() }
            }
            observations.append(observation)
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWindowCoverage() }
        }
        RunLoop.main.add(timer, forMode: .common)
        coverageTimer = timer

        // Evaluate initial state
        updateWindowCoverage()
        evaluateVisibility()
    }

    /// Stop observing.
    func stop() {
        observations.removeAll()
        trackedWindows.removeAll()
        coverageTimer?.invalidate()
        coverageTimer = nil
        coveredWindows.removeAll()
        hasEverBeenVisible = false
    }

    private func updateWindowCoverage() {
        let covering = Self.coveringWindowRects()
        let covered = Set(trackedWindows.filter { window in
            guard let screen = window.screen else { return false }
            return Self.isCovered(Self.globalRect(screen.visibleFrame), by: covering)
        }.map(ObjectIdentifier.init))
        guard covered != coveredWindows else { return }
        coveredWindows = covered
        evaluateVisibility()
    }

    private func evaluateVisibility() {
        // Desktop-level windows (below Finder icons) often report as
        // permanently occluded because macOS WindowServer treats them as
        // covered by the desktop icon layer. Until one has reported visible,
        // ignore that flag so playback isn't blocked on launch. Window
        // coverage is reliable and always applies, including at launch.
        if trackedWindows.contains(where: { $0.occlusionState.contains(.visible) }) {
            hasEverBeenVisible = true
        }
        let anyVisible = trackedWindows.contains { window in
            (!hasEverBeenVisible || window.occlusionState.contains(.visible))
                && !coveredWindows.contains(ObjectIdentifier(window))
        }

        onVisibilityChanged?(anyVisible)
    }

    /// Bounds (global, top-left origin) of other applications' opaque
    /// windows at normal levels. Window bounds need no screen-recording
    /// permission.
    private static func coveringWindowRects() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < menuLevel,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) >= 0.95,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
    }

    /// Converts a Cocoa screen rectangle (bottom-left origin) to the global
    /// top-left coordinates used by the window list.
    static func globalRect(_ frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Whether `windows` together cover `area`, checked on a sample grid.
    /// Gaps narrower than the grid spacing count as covered; that only errs
    /// toward pausing behind slivers too thin to show the wallpaper.
    nonisolated static func isCovered(_ area: CGRect, by windows: [CGRect], columns: Int = 32, rows: Int = 18) -> Bool {
        guard !area.isEmpty, !windows.isEmpty else { return false }
        let candidates = windows.filter { $0.intersects(area) }
        guard !candidates.isEmpty else { return false }
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: area.minX + (CGFloat(column) + 0.5) * area.width / CGFloat(columns),
                                    y: area.minY + (CGFloat(row) + 0.5) * area.height / CGFloat(rows))
                if !candidates.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}
