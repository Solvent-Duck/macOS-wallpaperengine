import AppKit

/// Reference-counts the app's own windows so the Dock icon and key focus stay
/// available while any of them is open. This is a menu bar (accessory) app
/// otherwise; closing one window must not demote the app under another.
@MainActor
enum AppActivation {
    private static var openWindows = 0

    static func windowDidOpen() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
    }

    static func windowDidClose() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
