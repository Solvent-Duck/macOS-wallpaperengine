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
    private var isLoaded = false

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
        if isLoaded {
            // Resume without reloading — unpause JS execution
            webView.evaluateJavaScript(Self.resumeScript, completionHandler: nil)
            print("[WebRenderer] Resumed")
        } else {
            let directory = fileURL.deletingLastPathComponent()
            webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
            print("[WebRenderer] Loading \(fileURL.lastPathComponent)")
        }
    }

    func pause() {
        webView.evaluateJavaScript(Self.pauseScript, completionHandler: nil)
        print("[WebRenderer] Paused")
    }

    func stop() {
        isLoaded = false
        webView.loadHTMLString("", baseURL: nil)
        print("[WebRenderer] Stopped")
    }

    func updateCursorPosition(_ position: NSPoint) {
        let js = "if (window._weCursorCallback) { window._weCursorCallback(\(position.x), \(position.y)); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
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

        // --- Pause-aware timer wrappers ---
        window._wePaused = false;
        window._wePendingRAFs = [];
        window._wePendingTimeouts = [];
        window._wePendingIntervals = [];

        var _weOrigRAF = window.requestAnimationFrame.bind(window);
        var _weOrigSetTimeout = window.setTimeout.bind(window);
        var _weOrigSetInterval = window.setInterval.bind(window);
        var _weOrigClearTimeout = window.clearTimeout.bind(window);
        var _weOrigClearInterval = window.clearInterval.bind(window);

        window.requestAnimationFrame = function(callback) {
            if (window._wePaused) {
                window._wePendingRAFs.push(callback);
                return -1;
            }
            return _weOrigRAF(callback);
        };

        window.setTimeout = function(callback, delay) {
            if (window._wePaused && typeof callback === 'function') {
                var id = { cleared: false };
                window._wePendingTimeouts.push({ fn: callback, delay: delay || 0, id: id });
                return id;
            }
            return _weOrigSetTimeout(callback, delay);
        };

        window.setInterval = function(callback, delay) {
            if (window._wePaused && typeof callback === 'function') {
                var id = { cleared: false };
                window._wePendingIntervals.push({ fn: callback, delay: delay || 0, id: id });
                return id;
            }
            return _weOrigSetInterval(callback, delay);
        };

        window.clearTimeout = function(id) {
            if (id && typeof id === 'object' && 'cleared' in id) {
                id.cleared = true;
                return;
            }
            return _weOrigClearTimeout(id);
        };

        window.clearInterval = function(id) {
            if (id && typeof id === 'object' && 'cleared' in id) {
                id.cleared = true;
                return;
            }
            return _weOrigClearInterval(id);
        };

        // Expose originals for pause/resume scripts
        window._weOrigRAF = _weOrigRAF;
        window._weOrigSetTimeout = _weOrigSetTimeout;
        window._weOrigSetInterval = _weOrigSetInterval;

        // --- WE API stubs ---

        window.wallpaperPropertyListener = window.wallpaperPropertyListener || {
            applyUserProperties: function(properties) {},
            applyGeneralProperties: function(properties) {},
            setPaused: function(isPaused) {}
        };

        window.wallpaperRegisterAudioListener = window.wallpaperRegisterAudioListener || function(callback) {};

        window.wallpaperRequestCursorPosition = window.wallpaperRequestCursorPosition || function(callback) {
            window._weCursorCallback = function(x, y) {
                callback({x: x, y: y});
            };
        };

        window.wallpaperRequestRandomMusicFile = window.wallpaperRequestRandomMusicFile || function() {
            return '';
        };

        console.log('[WallpaperEngine] JS API polyfill loaded');
    })();
    """

    /// JS to pause all animation/timer activity.
    private static let pauseScript = """
    (function() {
        window._wePaused = true;
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.setPaused) {
            window.wallpaperPropertyListener.setPaused(true);
        }
    })();
    """

    /// JS to resume animation/timer activity without a full page reload.
    private static let resumeScript = """
    (function() {
        window._wePaused = false;

        // Flush pending requestAnimationFrame callbacks
        var rafs = window._wePendingRAFs.splice(0);
        for (var i = 0; i < rafs.length; i++) {
            window._weOrigRAF(rafs[i]);
        }

        // Restore pending timeouts
        var timeouts = window._wePendingTimeouts.splice(0);
        for (var i = 0; i < timeouts.length; i++) {
            if (!timeouts[i].id.cleared) {
                window._weOrigSetTimeout(timeouts[i].fn, timeouts[i].delay);
            }
        }

        // Restore pending intervals
        var intervals = window._wePendingIntervals.splice(0);
        for (var i = 0; i < intervals.length; i++) {
            if (!intervals[i].id.cleared) {
                window._weOrigSetInterval(intervals[i].fn, intervals[i].delay);
            }
        }

        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.setPaused) {
            window.wallpaperPropertyListener.setPaused(false);
        }
    })();
    """
}
