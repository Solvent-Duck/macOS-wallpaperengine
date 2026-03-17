import AppKit

/// Detects when desktop windows are fully occluded by other application
/// windows, allowing the renderer to pause and save resources.
///
/// This is the single most impactful performance optimization: the wallpaper
/// is covered by other windows ~90% of the time for most users. When fully
/// occluded, rendering is completely paused (zero GPU/CPU draw).
///
/// Uses NSWindow's `occlusionState` property which macOS updates via the
/// WindowServer — no polling required.
class OcclusionDetector {
    private var observations: [NSKeyValueObservation] = []
    private var onVisibilityChanged: ((Bool) -> Void)?
    private var trackedWindows: [DesktopWindow] = []

    /// Start observing occlusion state for the given desktop windows.
    ///
    /// - Parameter callback: Called with `true` when any desktop window becomes
    ///   visible, `false` when all are fully occluded.
    func observe(windows: [DesktopWindow], onVisibilityChanged: @escaping (Bool) -> Void) {
        stop()

        self.onVisibilityChanged = onVisibilityChanged
        self.trackedWindows = windows

        for window in windows {
            let observation = window.observe(\.occlusionState, options: [.new]) { [weak self] window, _ in
                self?.evaluateVisibility()
            }
            observations.append(observation)
        }

        // Evaluate initial state
        evaluateVisibility()
    }

    /// Stop observing.
    func stop() {
        observations.removeAll()
        trackedWindows.removeAll()
    }

    private func evaluateVisibility() {
        // Visible if ANY tracked window has the .visible flag
        let anyVisible = trackedWindows.contains { window in
            window.occlusionState.contains(.visible)
        }
        onVisibilityChanged?(anyVisible)
    }

    deinit {
        stop()
    }
}
