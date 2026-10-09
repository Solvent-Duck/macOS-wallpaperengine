import AppKit

/// Detects when desktop windows are fully occluded by other application
/// windows, allowing the renderer to pause and save resources.
///
/// This is the single most impactful performance optimization: the wallpaper
/// is covered by other windows ~90% of the time for most users. When fully
/// occluded, rendering is completely paused (zero GPU/CPU draw).
///
/// Visibility comes from the on-screen window list: a desktop window is hidden
/// when other applications' opaque windows cover its screen's visible area.
/// That covers maximized windows and full-screen apps (the desktop window
/// joins every Space). NSWindow's `occlusionState` is unreliable for
/// desktop-level windows in both directions (it can stay "occluded" after the
/// covering window is minimized or hidden), so it only triggers a re-check, as
/// do app activation, hiding and Space changes; a once-a-second check catches
/// everything else. Sleep and screen lock are handled by the window manager.
@MainActor
class OcclusionDetector {
    private var observations: [NSKeyValueObservation] = []
    private var onVisibilityChanged: ((Bool) -> Void)?
    private var trackedWindows: [DesktopWindow] = []
    private var coverageTimer: Timer?
    private var coveredWindows: Set<ObjectIdentifier> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastReported: Bool?
    private static let debugLogging = ProcessInfo.processInfo.environment["WE_DEBUG_OCCLUSION"] != nil

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
                DispatchQueue.main.async { self?.updateWindowCoverage() }
            }
            observations.append(observation)
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindowCoverage() }
            })
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
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        coveredWindows.removeAll()
        lastReported = nil
    }

    private func updateWindowCoverage() {
        let covering = Self.coveringWindowRects()
        let covered = Set(trackedWindows.filter { window in
            guard let screen = window.screen else { return false }
            return Self.isCovered(Self.globalRect(screen.visibleFrame), by: covering)
        }.map(ObjectIdentifier.init))
        if Self.debugLogging {
            let states = trackedWindows.map { $0.occlusionState.contains(.visible) ? "visible" : "occluded" }
            print(String(format: "[Occlusion] %.1f covering=%d covered=%d state=%@", ProcessInfo.processInfo.systemUptime,
                         covering.count, covered.count, states.joined(separator: ",")))
        }
        guard covered != coveredWindows else { return }
        coveredWindows = covered
        evaluateVisibility()
    }

    private func evaluateVisibility() {
        let anyVisible = trackedWindows.contains { !coveredWindows.contains(ObjectIdentifier($0)) }
        guard anyVisible != lastReported else { return }
        lastReported = anyVisible
        onVisibilityChanged?(anyVisible)
    }

    /// Bounds (global, top-left origin) of other applications' opaque
    /// ordinary windows. Only the normal level counts: full-screen apps and
    /// maximized windows live there, while the Dock (which shows a
    /// full-screen window when windows are minimized), overlays and panels
    /// sit above it without hiding the wallpaper. Window bounds need no
    /// screen-recording permission.
    private static func coveringWindowRects() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return coveringRects(in: list, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    nonisolated static func coveringRects(in list: [[String: Any]], ownPID: Int32) -> [CGRect] {
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == normalLevel,
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
