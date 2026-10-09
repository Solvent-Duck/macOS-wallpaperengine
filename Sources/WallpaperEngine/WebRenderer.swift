import AppKit
import WebKit

/// Renders web (HTML/JS/CSS) wallpapers using WKWebView.
///
/// Wallpaper Engine web wallpapers are HTML bundles loaded from a local
/// directory. They communicate with the host via a JavaScript API provided
/// by WE. This renderer injects a compatibility polyfill at document-start
/// for supported WE callbacks, then applies user-configurable property values
/// once each wallpaper document finishes loading.
@MainActor
class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate {
    let view: NSView
    private let webView: WKWebView
    private let fileURL: URL
    private let readAccessURL: URL
    private var isLoaded = false
    private var isPlaying = false
    private var activeNavigation: WKNavigation?
    private var teardownNavigation: WKNavigation?
    private var acceptsNavigation = false
    private var isMediaSuspended = false

    /// Property definitions from project.json, set before play().
    private var wallpaperProperties: [WallpaperProperty] = []
    /// Current property values (defaults merged with user overrides).
    private var propertyValues: [String: String] = [:]

    init(fileURL: URL, readAccessURL: URL? = nil) {
        self.fileURL = fileURL
        self.readAccessURL = readAccessURL ?? fileURL.deletingLastPathComponent()

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
        acceptsNavigation = true
        isPlaying = true
        setMediaSuspended(false)
        if isLoaded {
            webView.evaluateJavaScript(Self.resumeScript, completionHandler: nil)
            print("[WebRenderer] Resumed")
        } else if activeNavigation == nil {
            activeNavigation = webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
            print("[WebRenderer] Loading \(fileURL.lastPathComponent)")
        }
    }

    func pause() {
        isPlaying = false
        setMediaSuspended(true)
        if isLoaded { webView.evaluateJavaScript(Self.pauseScript, completionHandler: nil) }
        print("[WebRenderer] Paused")
    }

    func stop() {
        acceptsNavigation = false
        isPlaying = false
        setMediaSuspended(true)
        isLoaded = false
        activeNavigation = nil
        webView.stopLoading()
        teardownNavigation = webView.loadHTMLString("", baseURL: nil)
        print("[WebRenderer] Stopped")
    }

    private func setMediaSuspended(_ suspended: Bool) {
        guard suspended != isMediaSuspended else { return }
        isMediaSuspended = suspended
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    // MARK: - Audio

    var supportsAudio: Bool { true }

    /// Web wallpapers play their own audio unmuted unless the user mutes them.
    var isMuted = false {
        didSet {
            guard isMuted != oldValue, isLoaded else { return }
            injectMuteState()
            injectGeneralProperties()
        }
    }

    /// User volume, 0–1, scaling each media element's own volume.
    private var volume: Double = 1

    func applyPlayback(_ settings: PlaybackSettings) {
        guard settings.volume != volume else { return }
        volume = settings.volume
        guard isLoaded else { return }
        injectMuteState()
        injectGeneralProperties()
    }

    /// Mute every media element; elements created later are muted on play().
    /// Web Audio graphs (AudioContext) are not covered.
    private func injectMuteState() {
        webView.evaluateJavaScript("if(window._weSetMuted){window._weSetVolume(\(volume));window._weSetMuted(\(isMuted));}", completionHandler: nil)
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
            injectMuteState()
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard acceptsNavigation, let navigation, navigation !== teardownNavigation else { return }
        // Page scripts, reloads, and history can start a new document without
        // going through play(). Track it so properties and pause state follow.
        activeNavigation = navigation
        isLoaded = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !acceptsNavigation, let navigation, navigation === teardownNavigation {
            // Document-start scripts also run on the blank teardown page.
            // Suspend their heartbeat instead of leaving a stopped renderer ticking.
            webView.evaluateJavaScript(Self.pauseScript, completionHandler: nil)
            return
        }
        guard let navigation, navigation === activeNavigation else { return }
        isLoaded = true
        print("[WebRenderer] Page loaded successfully")
        injectMuteState()
        injectGeneralProperties()
        injectAllProperties()
        if !isPlaying { webView.evaluateJavaScript(Self.pauseScript, completionHandler: nil) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation else { return }
        activeNavigation = nil
        isLoaded = false
        print("[WebRenderer] Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    // MARK: - Private JS Injection

    /// Push all current property values to `wallpaperPropertyListener.applyUserProperties`.
    private func injectAllProperties() {
        let payload = WallpaperProperty.javaScriptPayload(properties: wallpaperProperties, values: propertyValues)
        let js = """
        (function(){
            var l=window.wallpaperPropertyListener;
            if(l&&l.applyUserProperties){l.applyUserProperties(\(payload));}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Push a single changed property.
    private func injectSingleProperty(_ property: WallpaperProperty, value: String) {
        let payload = WallpaperProperty.javaScriptPayload(properties: [property], values: [property.key: value])
        let js = """
        (function(){
            var l=window.wallpaperPropertyListener;
            if(l&&l.applyUserProperties){l.applyUserProperties(\(payload));}
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
                l.applyGeneralProperties({fps:30,audioprocessing:false,muted:\(isMuted),volume:\(isMuted ? 0 : Int((volume * 100).rounded()))});
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Wallpaper Engine JS API Polyfill
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

        // Pause timers already scheduled as well as timers created while paused.
        \(WebPlaybackScripts.timerPolyfill)
        \(WebPlaybackScripts.animationPolyfill)

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
            window.setInterval(function() {
                if (window._wePaused || window._weAudioCallbacks.length === 0 || window._weAudioActive) return;
                for (var i = 0; i < window._weAudioCallbacks.length; i++) {
                    try { window._weAudioCallbacks[i](zero); } catch(e) {}
                }
            }, 33);
        })();

        // --- Host mute ---
        // Remembers each element's own muted state so unmuting restores it.
        // Played elements are tracked too, so detached `new Audio()` is covered.
        window._weMuted = false;
        var playedMedia = new Set();
        window._weSetMuted = function(muted) {
            window._weMuted = !!muted;
            var media = new Set(document.querySelectorAll('audio,video'));
            playedMedia.forEach(function(el) { media.add(el); });
            media.forEach(applyHostMute);
        };
        function applyHostMute(el) {
            if (window._weMuted) {
                if (el._weOwnMuted === undefined) el._weOwnMuted = el.muted;
                el.muted = true;
            } else if (el._weOwnMuted !== undefined) {
                el.muted = el._weOwnMuted;
                el._weOwnMuted = undefined;
            }
        }
        // --- Host volume ---
        // Scales each element's own volume; reading .volume returns the authored value.
        window._weVolume = 1;
        var volumeProperty = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
        function applyHostVolume(el) {
            var own = el._weOwnVolume === undefined ? volumeProperty.get.call(el) : el._weOwnVolume;
            el._weOwnVolume = own;
            volumeProperty.set.call(el, own * window._weVolume);
        }
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
            configurable: true,
            enumerable: volumeProperty.enumerable,
            get: function() { return this._weOwnVolume === undefined ? volumeProperty.get.call(this) : this._weOwnVolume; },
            set: function(v) { this._weOwnVolume = v; volumeProperty.set.call(this, v * window._weVolume); }
        });
        window._weSetVolume = function(volume) {
            window._weVolume = Math.min(1, Math.max(0, volume));
            var media = new Set(document.querySelectorAll('audio,video'));
            playedMedia.forEach(function(el) { media.add(el); });
            media.forEach(applyHostVolume);
        };
        (function() {
            var play = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function() {
                playedMedia.add(this);
                if (window._weMuted) applyHostMute(this);
                if (window._weVolume !== 1) applyHostVolume(this);
                return play.apply(this, arguments);
            };
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

    private static let pauseScript = WebPlaybackScripts.pause
    private static let resumeScript = WebPlaybackScripts.resume
}
