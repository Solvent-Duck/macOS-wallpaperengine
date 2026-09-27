import Foundation
import JavaScriptCore
import Testing
@testable import WallpaperEngine

struct WebPlaybackTests {
    @Test func pendingTimersFreezeRemainingTimeAndPreserveArguments() throws {
        let context = try makeContext()
        try run(context, """
        var events = [], pauseEvents = [];
        wallpaperPropertyListener = {setPaused: value => pauseEvents.push(value)};
        var id = setTimeout(function(a, b) { events.push([a, b, this === window]); }, 200, 'a', 42);
        advance(50); _weSetPaused(true); _weSetPaused(true); advance(1000);
        check(events.length === 0 && nativeTimers.size === 0, 'pause cancels native scheduling');
        _weSetPaused(false); _weSetPaused(false); advance(149);
        check(events.length === 0, 'remaining delay retained');
        advance(1);
        check(JSON.stringify(events) === '[[' + '"a",42,true]]', 'callback arguments and receiver');
        check(JSON.stringify(pauseEvents) === '[true,false]', 'one event per state change');
        """)
    }

    @Test func timerHandlesRemainCancelableAcrossPauseAndResume() throws {
        let context = try makeContext()
        try run(context, """
        var fired = 0;
        _weSetPaused(true);
        var timeout = setTimeout(() => fired++, 50);
        var interval = setInterval(() => fired++, 50);
        check(typeof timeout === 'number' && typeof interval === 'number', 'numeric handles');
        clearInterval(timeout);
        _weSetPaused(false);
        advance(50); check(fired === 1, 'interval fires once');
        clearTimeout(interval); advance(500); check(fired === 1, 'cross-clear interval after resume');
        var before = setTimeout(() => fired++, 50);
        advance(10); _weSetPaused(true); clearTimeout(before); _weSetPaused(false);
        advance(100); check(fired === 1, 'cancel timer that was pending before pause');
        """)
    }

    @Test func animationFramesRetainHandlesTimestampsAndCancellation() throws {
        let context = try makeContext()
        try run(context, """
        var events = [];
        var canceled = requestAnimationFrame(() => events.push('bad'));
        var retained = requestAnimationFrame(function(time) { events.push([time, this === window]); });
        _weSetPaused(true);
        check(nativeFrames.size === 0, 'cancel native frames while paused');
        var added = requestAnimationFrame(() => events.push('added'));
        cancelAnimationFrame(canceled);
        tickFrame(100); check(events.length === 0, 'no frames during pause');
        _weSetPaused(false); cancelAnimationFrame(added); tickFrame(200); tickFrame(300);
        check(JSON.stringify(events) === '[[200,true]]', 'single resumed frame with current timestamp');
        """)
    }

    @Test func intervalCallbacksCanPauseResumeAndCancelWithoutDuplicating() throws {
        let context = try makeContext()
        try run(context, """
        var count = 0;
        var interval = setInterval(function() {
            count++; _weSetPaused(true); _weSetPaused(false);
            if (count === 3) clearInterval(interval);
        }, 20);
        advance(100); check(count === 3 && nativeTimers.size === 0, 'no duplicate interval scheduling');
        setTimeout('count += 10', 5); advance(5); check(count === 13, 'string timer callback');
        """)
    }

    private func makeContext() throws -> JSContext {
        let context = try #require(JSContext())
        try run(context, """
        var window = this, clock = 0, nextNative = 1;
        var performance = {now: () => clock}, nativeTimers = new Map(), nativeFrames = new Map();
        window.setTimeout = function(callback, delay) {
            var id = nextNative++; nativeTimers.set(id, {callback: callback, due: clock + Math.max(1, delay)}); return id;
        };
        window.clearTimeout = id => nativeTimers.delete(id);
        window.requestAnimationFrame = function(callback) { var id = nextNative++; nativeFrames.set(id, callback); return id; };
        window.cancelAnimationFrame = id => nativeFrames.delete(id);
        function advance(delta) {
            var target = clock + delta, iterations = 0;
            while (true) {
                var next = Array.from(nativeTimers).filter(pair => pair[1].due <= target).sort((a,b) => a[1].due - b[1].due)[0];
                if (!next) break;
                if (++iterations > 1000) throw new Error('runaway timer');
                clock = next[1].due; nativeTimers.delete(next[0]); next[1].callback();
            }
            clock = target;
        }
        function tickFrame(time) { var callbacks = Array.from(nativeFrames.values()); nativeFrames.clear(); callbacks.forEach(callback => callback(time)); }
        function check(value, message) { if (!value) throw new Error(message); }
        """)
        try run(context, "(function(){\(WebPlaybackScripts.timerPolyfill)})();")
        return context
    }

    private func run(_ context: JSContext, _ script: String) throws {
        context.exception = nil
        context.evaluateScript(script)
        if let error = context.exception {
            throw NSError(domain: "WebPlaybackTests", code: 1, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "JavaScript failed"])
        }
    }
}
