import AppKit
import WebKit

/// Renders web (HTML/JS/CSS) wallpapers using WKWebView.
///
/// Wallpaper Engine web wallpapers are HTML bundles loaded from a local
/// directory. They communicate with the host via a JavaScript API provided
/// by WE. This renderer injects a compatibility polyfill at document-start
/// that stubs the WE JS API to ~80% coverage, then applies user-configurable
/// property values once the page finishes loading.
class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate {
    let view: NSView
    private let webView: WKWebView
    private let fileURL: URL
    private var isLoaded = false

    /// Property definitions from project.json, set before play().
    private var wallpaperProperties: [WallpaperProperty] = []
    /// Current property values (defaults merged with user overrides).
    private var propertyValues: [String: String] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
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
        webView.setValue(false, forKey: "drawsBackground")
        view = webView

        super.init()
        webView.navigationDelegate = self
    }

    func play() {
        if isLoaded {
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
        let js = "if(window._weCursorCallback){window._weCursorCallback(\(position.x),\(position.y));}"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Property Application

    func applyProperties(_ properties: [WallpaperProperty], values: [String: String]) {
        wallpaperProperties = properties
        // Merge: stored values take priority, fall back to defaults
        var merged = [String: String]()
        for p in properties { merged[p.key] = values[p.key] ?? p.defaultValue }
        propertyValues = merged
        if isLoaded {
            injectGeneralProperties()
            injectAllProperties()
        }
    }

    func applyProperty(_ property: WallpaperProperty, value: String) {
        propertyValues[property.key] = value
        if isLoaded { injectSingleProperty(property, value: value) }
    }

    func receiveAudioData(_ data: [Float]) {
        guard isLoaded else { return }
        // Build a compact JS numeric array and dispatch to all registered audio callbacks.
        // Setting _weAudioActive=true suppresses the zero-data heartbeat in the polyfill.
        let jsArray = data.map { String(format: "%.4f", $0) }.joined(separator: ",")
        let js = """
        (function(){
            window._weAudioActive=true;
            if(window._wePaused||window._weAudioCallbacks.length===0){return;}
            var d=[\(jsArray)];
            for(var i=0;i<window._weAudioCallbacks.length;i++){
                try{window._weAudioCallbacks[i](d);}catch(e){}
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        print("[WebRenderer] Page loaded successfully")
        injectGeneralProperties()
        injectAllProperties()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[WebRenderer] Navigation failed: \(error.localizedDescription)")
    }

    // MARK: - Private JS Injection

    /// Push all current property values to `wallpaperPropertyListener.applyUserProperties`.
    private func injectAllProperties() {
        let editable = wallpaperProperties.filter { $0.type != .text }
        guard !editable.isEmpty else { return }

        let pairs = editable.map { prop -> String in
            let val = propertyValues[prop.key] ?? prop.defaultValue
            let key = prop.key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(key)\":{value:\(prop.jsLiteral(from: val))}"
        }.joined(separator: ",")

        let js = """
        (function(){
            var l=window.wallpaperPropertyListener;
            if(l&&l.applyUserProperties){l.applyUserProperties({\(pairs)});}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Push a single changed property.
    private func injectSingleProperty(_ property: WallpaperProperty, value: String) {
        let key = property.key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = """
        (function(){
            var l=window.wallpaperPropertyListener;
            if(l&&l.applyUserProperties){l.applyUserProperties({"\(key)":{value:\(property.jsLiteral(from: value))}});}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Push general WE properties (fps, volume, etc.) once per page load.
    private func injectGeneralProperties() {
        let js = """
        (function(){
            var l=window.wallpaperPropertyListener;
            if(l&&l.applyGeneralProperties){
                l.applyGeneralProperties({fps:30,audioprocessing:false,muted:false,volume:100});
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Wallpaper Engine JS API Polyfill (~80% coverage)
    //
    // Injected at document-start so it runs before any wallpaper scripts.
    // Wallpaper scripts that set window.wallpaperPropertyListener override the stubs,
    // which is the correct WE behavior — the polyfill only fills gaps.

    private static let wallpaperPolyfill = """
    (function() {
        'use strict';

        // Platform / version globals that wallpapers sometimes read
        window._weVersion  = '4.0.0';
        window._wePlatform = 'web';

        // --- Pause-aware timer wrappers ---
        // Queues RAF/setTimeout/setInterval callbacks while paused and drains on resume.
        window._wePaused           = false;
        window._wePendingRAFs      = [];
        window._wePendingTimeouts  = [];
        window._wePendingIntervals = [];

        var _raf  = window.requestAnimationFrame.bind(window);
        var _sto  = window.setTimeout.bind(window);
        var _siv  = window.setInterval.bind(window);
        var _cto  = window.clearTimeout.bind(window);
        var _civ  = window.clearInterval.bind(window);

        window.requestAnimationFrame = function(cb) {
            if (window._wePaused) { window._wePendingRAFs.push(cb); return -1; }
            return _raf(cb);
        };
        window.setTimeout = function(cb, delay) {
            if (window._wePaused && typeof cb === 'function') {
                var id = {cleared: false};
                window._wePendingTimeouts.push({fn: cb, delay: delay||0, id: id});
                return id;
            }
            return _sto(cb, delay);
        };
        window.setInterval = function(cb, delay) {
            if (window._wePaused && typeof cb === 'function') {
                var id = {cleared: false};
                window._wePendingIntervals.push({fn: cb, delay: delay||0, id: id});
                return id;
            }
            return _siv(cb, delay);
        };
        window.clearTimeout = function(id) {
            if (id && typeof id === 'object' && 'cleared' in id) { id.cleared = true; return; }
            return _cto(id);
        };
        window.clearInterval = function(id) {
            if (id && typeof id === 'object' && 'cleared' in id) { id.cleared = true; return; }
            return _civ(id);
        };

        // Expose originals for the resume script
        window._weOrigRAF = _raf;
        window._weOrigSetTimeout = _sto;
        window._weOrigSetInterval = _siv;

        // --- Core WE property listener ---
        // Wallpaper scripts replace this with their own object.
        // The stub ensures walls that check for existence don't error.
        window.wallpaperPropertyListener = window.wallpaperPropertyListener || {
            applyUserProperties:    function(props) {},
            applyGeneralProperties: function(props) {},
            setPaused:              function(paused) {}
        };

        // --- Audio listener ---
        // Stores registered callbacks and sends a zero-data heartbeat at 30fps.
        // This prevents audio-reactive walls from crashing when no audio tap is present.
        // The heartbeat is suppressed once the host starts injecting real audio data
        // (indicated by window._weAudioActive = true).
        window._weAudioCallbacks = [];
        window._weAudioActive    = false;
        window.wallpaperRegisterAudioListener = window.wallpaperRegisterAudioListener || function(cb) {
            if (typeof cb === 'function') window._weAudioCallbacks.push(cb);
        };
        window.wallpaperRegisterAudioResponsiveGroup = window.wallpaperRegisterAudioResponsiveGroup || function() {};

        (function() {
            var zero = new Array(128).fill(0);
            _siv(function() {
                if (window._wePaused || window._weAudioCallbacks.length === 0 || window._weAudioActive) return;
                for (var i = 0; i < window._weAudioCallbacks.length; i++) {
                    try { window._weAudioCallbacks[i](zero); } catch(e) {}
                }
            }, 33);
        })();

        // --- Cursor position ---
        window.wallpaperRequestCursorPosition = window.wallpaperRequestCursorPosition || function(cb) {
            window._weCursorCallback = function(x, y) { cb({x: x, y: y}); };
        };

        // --- Miscellaneous API stubs ---
        window.wallpaperRequestRandomMusicFile = window.wallpaperRequestRandomMusicFile || function() { return ''; };
        window.wallpaperGetContentRating       = window.wallpaperGetContentRating       || function() { return 'Everyone'; };
        window.wallpaperPluginInstalled        = window.wallpaperPluginInstalled        || function() { return false; };
        window.wallpaperPlaySound              = window.wallpaperPlaySound              || function(file, fadeIn, loop) {};

        // --- Media stubs ---
        // WE can push now-playing metadata from the host. We stub these so walls
        // that register for media events don't error on missing APIs.
        window.wallpaperMediaPropertiesListener = window.wallpaperMediaPropertiesListener || {
            applyMediaProperties: function(props) {}
        };
        window.wallpaperMediaThumbnailListener = window.wallpaperMediaThumbnailListener || {
            applyThumbnail: function(data) {}
        };
        window.wallpaperMediaTimelineListener = window.wallpaperMediaTimelineListener || {
            applyTimeline: function(data) {}
        };
        window.wallpaperRegisterMediaStatusListener = window.wallpaperRegisterMediaStatusListener || function(cb) {};
        window.wallpaperToggleMedia      = window.wallpaperToggleMedia      || function() {};
        window.wallpaperIsMediaAvailable = window.wallpaperIsMediaAvailable || function() { return false; };

        console.log('[WallpaperEngine] JS polyfill loaded (' + window._weVersion + ')');
    })();
    """

    /// Pause all animation/timer activity.
    private static let pauseScript = """
    (function() {
        window._wePaused = true;
        var l = window.wallpaperPropertyListener;
        if (l && l.setPaused) l.setPaused(true);
    })();
    """

    /// Resume animation/timer activity, draining all queued callbacks.
    private static let resumeScript = """
    (function() {
        window._wePaused = false;
        var rafs = window._wePendingRAFs.splice(0);
        for (var i = 0; i < rafs.length; i++) { window._weOrigRAF(rafs[i]); }
        var tos = window._wePendingTimeouts.splice(0);
        for (var i = 0; i < tos.length; i++) {
            if (!tos[i].id.cleared) window._weOrigSetTimeout(tos[i].fn, tos[i].delay);
        }
        var ivs = window._wePendingIntervals.splice(0);
        for (var i = 0; i < ivs.length; i++) {
            if (!ivs[i].id.cleared) window._weOrigSetInterval(ivs[i].fn, ivs[i].delay);
        }
        var l = window.wallpaperPropertyListener;
        if (l && l.setPaused) l.setPaused(false);
    })();
    """
}
