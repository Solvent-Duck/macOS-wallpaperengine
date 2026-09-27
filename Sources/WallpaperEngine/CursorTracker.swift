import AppKit

/// Tracks the global cursor position and forwards it to wallpaper renderers
/// that support mouse interaction (parallax, interactive elements).
///
/// Uses a global event monitor to receive mouse movement events without
/// requiring the desktop window to be key or first responder.
class CursorTracker {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var leftDown = false
    private var onCursorChanged: ((NSPoint, Bool) -> Void)?

    /// Start tracking cursor movement, dragging and left-button changes.
    ///
    /// - Parameter callback: Called with the cursor position in screen
    ///   coordinates (origin at bottom-left of the primary display) and button state.
    func start(onCursorChanged: @escaping (NSPoint, Bool) -> Void) {
        stop()
        self.onCursorChanged = onCursorChanged
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .leftMouseDown, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.receive(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.receive(event)
            return event
        }
        sample()
    }

    private func sample() {
        leftDown = NSEvent.pressedMouseButtons & 1 != 0
        onCursorChanged?(NSEvent.mouseLocation, leftDown)
    }

    private func receive(_ event: NSEvent) {
        let sample = Self.inputSample(for: event, previousLeftDown: leftDown)
        leftDown = sample.leftDown
        onCursorChanged?(sample.position, sample.leftDown)
    }

    /// Read the delivered event rather than a newer global state that may already
    /// reflect later queued movement or a release.
    static func inputSample(for event: NSEvent, previousLeftDown: Bool) -> (position: NSPoint, leftDown: Bool) {
        let position = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let down: Bool
        switch event.type {
        case .leftMouseDown, .leftMouseDragged: down = true
        case .leftMouseUp: down = false
        default: down = previousLeftDown
        }
        return (position, down)
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        onCursorChanged = nil
        leftDown = false
    }

    /// Convert a screen-space cursor position to normalized coordinates
    /// (0.0–1.0) relative to a given screen.
    static func normalize(_ point: NSPoint, for screen: NSScreen) -> NSPoint {
        normalize(point, in: screen.frame)
    }

    static func normalize(_ point: NSPoint, in frame: NSRect) -> NSPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return NSPoint(
            x: (point.x - frame.origin.x) / frame.width,
            y: (point.y - frame.origin.y) / frame.height
        )
    }

    deinit {
        stop()
    }
}
