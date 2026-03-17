import AppKit
import WebKit

/// Renders web (HTML/JS/CSS) wallpapers using WKWebView.
///
/// Wallpaper Engine web wallpapers are HTML bundles loaded from a local
/// directory. They may use a JavaScript API provided by WE for things like
/// cursor position, audio visualization, and user-configurable properties.
///
/// This renderer injects a compatibility polyfill (`wallpaperPolyfill`)
/// that stubs the most commonly used WE JS APIs so that web wallpapers
/// can run without modification.
class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate {
    let view: NSView
    private let webView: WKWebView
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        // Allow local file access for wallpaper assets
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Inject the WE JavaScript API polyfill before any page scripts run
        let polyfill = WKUserScript(
            source: Self.wallpaperPolyfill,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(polyfill)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]

        // Transparent background so the desktop shows through if the
        // wallpaper has transparent regions
        webView.setValue(false, forKey: "drawsBackground")

        view = webView

        super.init()
        webView.navigationDelegate = self
    }

    func play() {
        let directory = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
        print("[WebRenderer] Loading \(fileURL.lastPathComponent)")
    }

    func pause() {
        webView.evaluateJavaScript("document.hidden = true;", completionHandler: nil)
        print("[WebRenderer] Paused")
    }

    func stop() {
        webView.loadHTMLString("", baseURL: nil)
        print("[WebRenderer] Stopped")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[WebRenderer] Page loaded successfully")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[WebRenderer] Navigation failed: \(error.localizedDescription)")
    }

    // MARK: - Wallpaper Engine JS API Polyfill

    /// Stubs for the Wallpaper Engine JavaScript API.
    ///
    /// Web wallpapers may call these APIs for:
    /// - `window.wallpaperPropertyListener`: receive user-configurable property changes
    /// - `window.wallpaperRegisterAudioListener`: audio visualization data
    /// - Cursor position tracking
    ///
    /// This polyfill provides no-op implementations so wallpapers don't throw
    /// errors on missing APIs. Functional implementations can be added incrementally.
    private static let wallpaperPolyfill = """
    // Wallpaper Engine JS API compatibility polyfill
    (function() {
        'use strict';

        // Property listener — wallpapers register callbacks here to receive
        // user-configurable property changes
        window.wallpaperPropertyListener = window.wallpaperPropertyListener || {
            applyUserProperties: function(properties) {},
            applyGeneralProperties: function(properties) {},
            setPaused: function(isPaused) {}
        };

        // Audio listener — wallpapers register a callback to receive
        // audio frequency/waveform data for visualization
        window.wallpaperRegisterAudioListener = window.wallpaperRegisterAudioListener || function(callback) {
            // No-op: audio visualization not yet implemented
        };

        // Cursor position — some wallpapers use parallax or interactive effects
        window.wallpaperRequestCursorPosition = window.wallpaperRequestCursorPosition || function(callback) {
            // No-op: cursor tracking not yet wired up
        };

        // Random music file — some wallpapers can play background music
        window.wallpaperRequestRandomMusicFile = window.wallpaperRequestRandomMusicFile || function() {
            return '';
        };

        console.log('[WallpaperEngine] JS API polyfill loaded');
    })();
    """
}
