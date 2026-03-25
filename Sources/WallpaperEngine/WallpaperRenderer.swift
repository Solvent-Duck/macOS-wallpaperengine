import AppKit

/// Protocol for wallpaper rendering backends.
///
/// Each wallpaper type (video, web, scene) implements this protocol.
/// The renderer provides an NSView that is set as the content of a
/// DesktopWindow for display.
protocol WallpaperRenderer: AnyObject {
    /// The view to display in the desktop window.
    var view: NSView { get }

    /// Start or resume rendering.
    func play()

    /// Pause rendering (e.g. when the desktop is fully occluded).
    func pause()

    /// Stop rendering and release resources.
    func stop()

    /// Update the cursor position for interactive wallpapers.
    /// Coordinates are normalized (0.0–1.0) relative to the screen.
    /// Default implementation is a no-op for non-interactive renderers.
    func updateCursorPosition(_ position: NSPoint)

    /// Whether this renderer supports audio output.
    var supportsAudio: Bool { get }

    /// Whether audio is currently muted.
    var isMuted: Bool { get set }

    /// Attempt recovery after display sleep/wake if rendering is broken.
    /// Default implementation is a no-op. Only SceneRenderer overrides this.
    func recoverFromSleep()

    /// Apply the full set of user properties. Called once after the wallpaper
    /// loads and again whenever the user resets to defaults.
    func applyProperties(_ properties: [WallpaperProperty], values: [String: String])

    /// Apply a single user property change at runtime.
    func applyProperty(_ property: WallpaperProperty, value: String)

    /// Forward audio frequency data from the host to the wallpaper.
    ///
    /// `data` contains `bandCount` normalized amplitude values (0.0–1.0),
    /// matching Wallpaper Engine's 128-band format.
    func receiveAudioData(_ data: [Float])
}

extension WallpaperRenderer {
    func updateCursorPosition(_ position: NSPoint) {}
    var supportsAudio: Bool { false }
    var isMuted: Bool {
        get { true }
        set {}
    }
    func recoverFromSleep() {}
    func applyProperties(_ properties: [WallpaperProperty], values: [String: String]) {}
    func applyProperty(_ property: WallpaperProperty, value: String) {}
    func receiveAudioData(_ data: [Float]) {}
}
