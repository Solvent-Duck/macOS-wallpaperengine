import AppKit
import Foundation
import Testing
import WebKit
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct WebPropertyDeliveryTests {
    @Test func documentNavigationReceivesCurrentPropertiesAndPlaybackState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEWebNavigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for page in ["index", "next"] {
            try """
            <!doctype html><html><script>
            window.pageID = '\(page)'; window.events = []; window.identity = Math.random();
            window.wallpaperPropertyListener = {
                applyUserProperties(properties) { window.events.push(properties); },
                setPaused(value) { window.lastPause = value; }
            };
            </script><body>\(page)</body></html>
            """.write(to: root.appendingPathComponent("\(page).html"), atomically: true, encoding: .utf8)
        }
        let properties = WallpaperProperty.parse(from: Data(#"{"general":{"properties":{"message":{"type":"textinput","value":"initial"}}}}"#.utf8))
        let message = try #require(properties.first)
        let renderer = WebRenderer(fileURL: root.appendingPathComponent("index.html"))
        defer { renderer.stop() }
        let webView = try #require(renderer.view as? WKWebView)
        renderer.applyProperties(properties, values: [:])
        renderer.play()
        try await waitForEvents(1, in: webView, page: "index")
        renderer.pause()
        renderer.applyProperty(message, value: "changed")
        _ = try await webView.evaluateJavaScript("window.location.href = 'next.html'; true")
        try await waitForEvents(1, in: webView, page: "next")
        #expect(try await webView.evaluateJavaScript("window.events[0].message.value") as? String == "changed")
        #expect(try await webView.evaluateJavaScript("window._wePaused && window.lastPause === true") as? Bool == true)
        let identity = try #require(try await webView.evaluateJavaScript("window.identity") as? Double)
        renderer.play()
        #expect(try await webView.evaluateJavaScript("window.identity") as? Double == identity)
        #expect(try await webView.evaluateJavaScript("window._wePaused") as? Bool == false)
        renderer.stop()
        renderer.play() // A pending blank teardown must not become the active document.
        try await waitForEvents(1, in: webView, page: "index")
        #expect(try await webView.evaluateJavaScript("window.events[0].message.value") as? String == "changed")
        #expect(try await webView.evaluateJavaScript("window._wePaused") as? Bool == false)
    }

    @Test func pauseDuringNavigationIsAppliedAndStopPlayReloadsTheWallpaper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEWebLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = root.appendingPathComponent("index.html")
        try """
        <!doctype html><html><script>
        window.events = []; window.identity = Math.random();
        window.wallpaperPropertyListener = {applyUserProperties(properties) { events.push(properties); }, setPaused(value) { window.lastPause = value; }};
        </script><body>Lifecycle fixture</body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let renderer = WebRenderer(fileURL: html)
        defer { renderer.stop() }
        let webView = try #require(renderer.view as? WKWebView)
        renderer.play()
        renderer.pause()
        try await waitForEvents(1, in: webView)
        #expect(try await webView.evaluateJavaScript("window._wePaused && window.lastPause === true") as? Bool == true)
        let identity = try #require(try await webView.evaluateJavaScript("window.identity") as? Double)
        renderer.play()
        #expect(try await webView.evaluateJavaScript("window._wePaused === false && window.lastPause === false") as? Bool == true)
        renderer.stop()
        // The blank document also receives user scripts; its heartbeat must stop.
        try await waitForStoppedDocument(in: webView)
        renderer.play()
        try await waitForEvents(1, in: webView)
        let reloaded = try #require(try await webView.evaluateJavaScript("window.identity") as? Double)
        #expect(reloaded != identity)
        #expect(try await webView.evaluateJavaScript("window._wePaused") as? Bool == false)
    }

    @Test func deliversInitialAndChangedPropertiesToTheLoadedWallpaper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEWebProperties-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = root.appendingPathComponent("index.html")
        try """
        <!doctype html><html><script>
        window.events = [];
        window.wallpaperPropertyListener = { applyUserProperties(properties) { window.events.push(properties); } };
        </script><body>Property delivery fixture</body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let properties = WallpaperProperty.parse(from: Data(#"{"general":{"properties":{"mode":{"type":"combo","value":1,"options":[{"value":1,"label":"One"},{"value":2,"label":"Two"}]},"message":{"type":"textinput","value":"hello"}}}}"#.utf8))
        let renderer = WebRenderer(fileURL: html)
        defer { renderer.stop() }
        renderer.applyProperties(properties, values: ["mode": "2"])
        let webView = try #require(renderer.view as? WKWebView)
        renderer.play()
        try await waitForEvents(1, in: webView)
        let initial = try #require(try await webView.evaluateJavaScript("JSON.stringify(window.events[0])") as? String)
        let event = try #require(JSONSerialization.jsonObject(with: Data(initial.utf8)) as? [String: [String: Any]])
        #expect(event["mode"]?["value"] as? Int == 2)
        #expect(event["mode"]?["text"] as? String == "Two")
        #expect(event["message"]?["value"] as? String == "hello")
        let message = try #require(properties.first(where: { $0.key == "message" }))
        let updated = "line\nquote\"tab\tcontrol\u{1}"
        renderer.applyProperty(message, value: updated)
        try await waitForEvents(2, in: webView)
        #expect(try await webView.evaluateJavaScript("window.events[1].message.value") as? String == updated)
        #expect(try await webView.evaluateJavaScript("Object.keys(window.events[1]).length") as? Int == 1)
    }

    @Test func hostMuteSilencesMediaAndRestoresAuthoredState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEWebMute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = root.appendingPathComponent("index.html")
        try """
        <!doctype html><html><body><audio id="own" muted></audio><audio id="plain"></audio><script>
        window.events = []; window.general = [];
        window.wallpaperPropertyListener = {
            applyUserProperties(properties) { events.push(properties); },
            applyGeneralProperties(properties) { general.push(properties); }
        };
        </script></body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let renderer = WebRenderer(fileURL: html)
        defer { renderer.stop() }
        let webView = try #require(renderer.view as? WKWebView)
        #expect(renderer.supportsAudio && !renderer.isMuted)
        renderer.play()
        try await waitForEvents(1, in: webView)
        #expect(try await webView.evaluateJavaScript("general[general.length-1].muted") as? Bool == false)

        renderer.isMuted = true
        #expect(try await webView.evaluateJavaScript("own.muted && plain.muted && general[general.length-1].muted") as? Bool == true)
        // Elements created while muted are silenced when they start playing.
        _ = try await webView.evaluateJavaScript("window.late = document.createElement('audio'); late.play().catch(function(){}); true")
        #expect(try await webView.evaluateJavaScript("late.muted") as? Bool == true)

        renderer.isMuted = false
        #expect(try await webView.evaluateJavaScript("own.muted && !plain.muted && !late.muted") as? Bool == true)
        #expect(try await webView.evaluateJavaScript("general[general.length-1].muted") as? Bool == false)
    }

    private func waitForEvents(_ count: Int, in webView: WKWebView, page: String? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let currentPage = try? await webView.evaluateJavaScript("window.pageID") as? String
            let matchesPage = page == nil || currentPage == page
            if matchesPage,
               let current = try? await webView.evaluateJavaScript("window.events ? window.events.length : 0") as? Int,
               current >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "WebPropertyDeliveryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wallpaper did not receive \(count) property events within 15 seconds"])
    }

    private func waitForStoppedDocument(in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if (try? await webView.evaluateJavaScript("document.URL === 'about:blank' && document.readyState === 'complete' && window._wePaused === true") as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "WebPropertyDeliveryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stopped web document did not suspend its timers"])
    }
}
