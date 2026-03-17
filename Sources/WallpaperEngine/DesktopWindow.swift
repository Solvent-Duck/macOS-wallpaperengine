import AppKit

/// A borderless window positioned at the desktop level, behind Finder icons
/// but above the system wallpaper image. This is the rendering surface for
/// animated wallpapers.
///
/// Window configuration:
/// - Level: desktopWindow + 1 (above system wallpaper, below desktop icons)
/// - Borderless, transparent, no shadow
/// - Persists across all Spaces (canJoinAllSpaces + stationary)
/// - Does not appear in Mission Control (transient)
/// - Passes all mouse events through to Finder (ignoresMouseEvents)
class DesktopWindow: NSWindow {

    init(for screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Position above the system wallpaper, below desktop icons
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        // Persist across all Spaces and stay in place
        collectionBehavior = [
            .canJoinAllSpaces,  // Visible on every Space
            .stationary,        // Don't move with Space transitions
            .ignoresCycle,      // Skip in Cmd+Tab / window cycling
            .transient          // Don't show in Mission Control
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        canHide = false
        isReleasedWhenClosed = false
    }

    /// Update the window frame to match the screen geometry.
    /// Called when display configuration changes (resolution, arrangement).
    func updateFrame(for screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
