import Foundation

/// Browser timers retain their public handles while native scheduling is suspended.
enum WebPlaybackScripts {
    static let timerPolyfill = """
    var _raf = window.requestAnimationFrame.bind(window);
    var _caf = window.cancelAnimationFrame.bind(window);
    var _sto = window.setTimeout.bind(window);
    var _cto = window.clearTimeout.bind(window);
    var _now = performance.now.bind(performance);
    var _nextTimerID = 1, _nextRAFID = 1;
    var _timers = new Map(), _rafs = new Map();
    window._wePaused = false;

    function scheduleTimer(timer) {
        if (timer.running) return;
        timer.deadline = _now() + timer.remaining;
        timer.nativeID = _sto(function() {
            timer.nativeID = null;
            if (!_timers.has(timer.id) || window._wePaused) return;
            if (!timer.repeating) _timers.delete(timer.id);
            timer.running = true;
            try {
                if (typeof timer.callback === 'function') timer.callback.apply(window, timer.args);
                else (0, eval)(String(timer.callback));
            } finally {
                timer.running = false;
                if (timer.repeating && _timers.has(timer.id)) {
                    timer.remaining = timer.delay;
                    if (!window._wePaused) scheduleTimer(timer);
                }
            }
        }, timer.remaining);
    }
    function addTimer(callback, delay, args, repeating) {
        delay = Math.max(0, Number(delay) >> 0);
        var timer = {id: _nextTimerID++, callback: callback, args: args, delay: delay,
            remaining: delay, repeating: repeating, nativeID: null, deadline: 0, running: false};
        _timers.set(timer.id, timer);
        if (!window._wePaused) scheduleTimer(timer);
        return timer.id;
    }
    window.setTimeout = function(callback, delay) {
        return addTimer(callback, delay, Array.prototype.slice.call(arguments, 2), false);
    };
    window.setInterval = function(callback, delay) {
        return addTimer(callback, delay, Array.prototype.slice.call(arguments, 2), true);
    };
    window.clearTimeout = window.clearInterval = function(id) {
        var timer = _timers.get(Number(id));
        if (!timer) return;
        if (timer.nativeID !== null) _cto(timer.nativeID);
        _timers.delete(timer.id);
    };
    function scheduleRAF(frame) {
        frame.nativeID = _raf(function(timestamp) {
            frame.nativeID = null;
            if (!_rafs.has(frame.id) || window._wePaused) return;
            _rafs.delete(frame.id);
            frame.callback.call(window, timestamp);
        });
    }
    window.requestAnimationFrame = function(callback) {
        if (typeof callback !== 'function') throw new TypeError('Animation callback must be a function');
        var frame = {id: _nextRAFID++, callback: callback, nativeID: null};
        _rafs.set(frame.id, frame);
        if (!window._wePaused) scheduleRAF(frame);
        return frame.id;
    };
    window.cancelAnimationFrame = function(id) {
        var frame = _rafs.get(Number(id));
        if (!frame) return;
        if (frame.nativeID !== null) _caf(frame.nativeID);
        _rafs.delete(frame.id);
    };
    window._weSetPaused = function(paused) {
        paused = !!paused;
        if (paused === window._wePaused) return;
        window._wePaused = paused;
        if (paused) {
            var now = _now();
            _timers.forEach(function(timer) {
                if (timer.nativeID !== null) {
                    timer.remaining = Math.max(0, timer.deadline - now);
                    _cto(timer.nativeID);
                    timer.nativeID = null;
                }
            });
            _rafs.forEach(function(frame) {
                if (frame.nativeID !== null) _caf(frame.nativeID);
                frame.nativeID = null;
            });
        } else {
            _timers.forEach(scheduleTimer);
            _rafs.forEach(scheduleRAF);
        }
        if (window._weSetAnimationsPaused) window._weSetAnimationsPaused(paused);
        var listener = window.wallpaperPropertyListener;
        if (listener && listener.setPaused) listener.setPaused(paused);
    };
    """

    static let animationPolyfill = """
    if (window.Animation && window.Element && document.getAnimations) {
        var _animationPlay = Animation.prototype.play;
        var _animationPause = Animation.prototype.pause;
        var _heldAnimations = new Set();
        function holdAnimation(animation) {
            if (!window._wePaused || animation.playState !== 'running') return;
            var time = animation.currentTime;
            _animationPause.call(animation);
            // Resolve a pending pause without waiting for another rendered
            // frame, including when the wallpaper's view is occluded.
            if (time !== null) animation.currentTime = time;
            _heldAnimations.add(animation);
        }
        function holdDocumentAnimations() {
            if (window._wePaused) document.getAnimations().forEach(holdAnimation);
        }
        Animation.prototype.play = function() {
            var result = _animationPlay.apply(this, arguments);
            holdAnimation(this);
            return result;
        };
        ['pause', 'cancel', 'finish'].forEach(function(name) {
            var original = Animation.prototype[name];
            Animation.prototype[name] = function() {
                var result = original.apply(this, arguments);
                _heldAnimations.delete(this);
                return result;
            };
        });
        var _animationReverse = Animation.prototype.reverse;
        Animation.prototype.reverse = function() {
            var result = _animationReverse.apply(this, arguments);
            holdAnimation(this);
            return result;
        };
        var _elementAnimate = Element.prototype.animate;
        Element.prototype.animate = function() {
            var animation = _elementAnimate.apply(this, arguments);
            holdAnimation(animation);
            return animation;
        };
        function authorPausedCSS(animation) {
            if (!window.CSSAnimation || !(animation instanceof CSSAnimation) || !animation.effect || !animation.effect.target) return false;
            var style = getComputedStyle(animation.effect.target, animation.effect.pseudoElement);
            var names = style.animationName.split(',').map(name => name.trim());
            var states = style.animationPlayState.split(',').map(state => state.trim());
            var index = names.indexOf(animation.animationName);
            return index >= 0 && states[index % states.length] === 'paused';
        }
        var _animationObserver = new MutationObserver(holdDocumentAnimations);
        document.addEventListener('animationstart', holdDocumentAnimations, true);
        document.addEventListener('transitionrun', holdDocumentAnimations, true);
        window._weSetAnimationsPaused = function(paused) {
            if (paused) {
                _animationObserver.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
                holdDocumentAnimations();
            } else {
                _animationObserver.disconnect();
                _heldAnimations.forEach(function(animation) {
                    if (animation.playState === 'paused' && !authorPausedCSS(animation)) _animationPlay.call(animation);
                });
                _heldAnimations.clear();
            }
        };
    }
    """

    static let pause = "window._weSetPaused && window._weSetPaused(true);"
    static let resume = "window._weSetPaused && window._weSetPaused(false);"
}
