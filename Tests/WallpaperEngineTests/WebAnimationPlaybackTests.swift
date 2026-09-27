import AppKit
import Foundation
import Testing
import WebKit
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct WebAnimationPlaybackTests {
    @Test func pausesCSSAndWebAnimationsWithoutRestartingAuthoredPausedAnimations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEWebAnimations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try """
        <!doctype html><html><style>
        @keyframes fade { from { opacity: 0.2; } to { opacity: 1; } }
        .moving { width: 20px; height: 20px; background: red; animation: fade 10s infinite; }
        </style><body><div id="css" class="moving"></div><div id="cssHeld" class="moving" style="animation-play-state: paused"></div>
        <div id="cssChanged" class="moving"></div><div id="target"></div><script>
        window.cssAnimation = document.getElementById('css').getAnimations()[0];
        window.cssAuthoredPause = document.getElementById('cssHeld').getAnimations()[0];
        window.cssChangedPause = document.getElementById('cssChanged').getAnimations()[0];
        window.running = target.animate([{opacity: 0}, {opacity: 1}], {duration: 10000, iterations: Infinity});
        window.authoredPaused = target.animate([{opacity: 1}, {opacity: 0}], 10000);
        authoredPaused.pause();
        window.wallpaperPropertyListener = {applyUserProperties() { window.ready = true; }};
        </script></body></html>
        """.write(to: file, atomically: true, encoding: .utf8)
        let renderer = WebRenderer(fileURL: file)
        let webView = try #require(renderer.view as? WKWebView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer { renderer.stop(); window.orderOut(nil) }
        renderer.play()
        try await waitFor("window.ready === true", in: webView)
        renderer.pause()
        try await waitFor("window._wePaused === true", in: webView)
        #expect(try await webView.evaluateJavaScript("cssAnimation.playState") as? String == "paused")
        #expect(try await webView.evaluateJavaScript("running.playState") as? String == "paused")
        #expect(try await webView.evaluateJavaScript("authoredPaused.playState") as? String == "paused")

        _ = try await webView.evaluateJavaScript("""
        window.added = target.animate([{opacity: 0}, {opacity: 1}], 10000);
        var extra = document.createElement('div'); extra.className = 'moving'; document.body.appendChild(extra);
        window.addedCSS = extra.getAnimations()[0];
        window.canceled = target.animate([{opacity: 0}, {opacity: 1}], 10000); canceled.cancel();
        window.userPaused = target.animate([{opacity: 0}, {opacity: 1}], 10000); userPaused.pause();
        window.finished = target.animate([{opacity: 0}, {opacity: 1}], 10000); finished.finish();
        window.replayed = target.animate([{opacity: 0}, {opacity: 1}], 10000); replayed.pause(); replayed.play();
        window.reversed = target.animate([{opacity: 0}, {opacity: 1}], 10000); reversed.currentTime = 500; reversed.reverse();
        document.getElementById('cssChanged').style.animationPlayState = 'paused';
        var box = document.createElement('div'); box.style.cssText = 'width: 20px; height: 20px; transition: width 10s';
        document.body.appendChild(box); getComputedStyle(box).width; box.style.width = '80px';
        window.transition = box.getAnimations()[0];
        true;
        """)
        let held = "[cssAnimation, running, added, addedCSS, replayed, reversed, transition]"
        try await waitFor("\(held).every(a => a && !a.pending)", in: webView)
        #expect(try await webView.evaluateJavaScript("\(held).every(a => a.playState === 'paused')") as? Bool == true)
        _ = try await webView.evaluateJavaScript("window.heldTimes = \(held).map(a => a.currentTime); true")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await webView.evaluateJavaScript("\(held).every((a, i) => a.currentTime === heldTimes[i])") as? Bool == true)
        renderer.play()
        try await waitFor("window._wePaused === false", in: webView)
        #expect(try await webView.evaluateJavaScript("\(held).every(a => a.playState === 'running')") as? Bool == true)
        #expect(try await webView.evaluateJavaScript("[authoredPaused, userPaused, cssAuthoredPause, cssChangedPause].every(a => a.playState === 'paused') && canceled.playState === 'idle' && finished.playState === 'finished'") as? Bool == true)
    }

    private func waitFor(_ predicate: String, in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? await webView.evaluateJavaScript(predicate) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "WebAnimationPlaybackTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Web animation state did not settle: \(predicate)"])
    }
}
