import AppKit

/// Tracks the global cursor position and forwards it to wallpaper renderers
/// that support mouse interaction (parallax, interactive elements).
///
/// Uses a global event monitor to receive mouse movement events without
/// requiring the desktop window to be key or first responder.
class CursorTracker {
    private var monitor: Any?
    private var onCursorMoved: ((NSPoint) -> Void)?

    /// Start tracking cursor movement.
    ///
    /// - Parameter callback: Called with the cursor position in screen
    ///   coordinates (origin at bottom-left of the primary display).
    func start(onCursorMoved: @escaping (NSPoint) -> Void) {
        self.onCursorMoved = onCursorMoved
        stop()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            let location = NSEvent.mouseLocation
            self?.onCursorMoved?(location)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Convert a screen-space cursor position to normalized coordinates
    /// (0.0–1.0) relative to a given screen.
    static func normalize(_ point: NSPoint, for screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        return NSPoint(
            x: (point.x - frame.origin.x) / frame.width,
            y: (point.y - frame.origin.y) / frame.height
        )
    }

    deinit {
        stop()
    }
}
