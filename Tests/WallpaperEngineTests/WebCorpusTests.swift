import AppKit
import Foundation
import Testing
import WebKit
@testable import WallpaperEngine

@MainActor
struct WebCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_WEB_CORPUS_ROOT"] != nil))
    func localWebWallpaperRendersAndPauses() async throws {
        let corpus = try #require(ProcessInfo.processInfo.environment["WE_WEB_CORPUS_ROOT"])
        // The one eligible local web project. Never enumerate excluded test content.
        let project = try WallpaperLoader.load(from: URL(fileURLWithPath: corpus).appendingPathComponent("860265906"))
        let directory = try #require(ProcessInfo.processInfo.environment["WE_WEB_CORPUS_REPORT_DIR"])
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fileURL = try #require(project.fileURL)
        let renderer = WebRenderer(fileURL: fileURL)
        defer { renderer.stop() }
        let webView = try #require(renderer.view as? WKWebView)
        webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        webView.configuration.userContentController.addUserScript(WKUserScript(source: """
        window.__weProbeErrors = [];
        window.addEventListener('error', event => __weProbeErrors.push(String(event.message)));
        window.addEventListener('unhandledrejection', event => __weProbeErrors.push(String(event.reason)));
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.configuration.userContentController.addUserScript(WKUserScript(source: """
        window.__weProbeEvents = []; window.__weProbeTicks = 0;
        window.setInterval(() => window.__weProbeTicks++, 30);
        var listener = window.wallpaperPropertyListener;
        if (listener && listener.applyUserProperties) {
            var original = listener.applyUserProperties;
            listener.applyUserProperties = function(properties) {
                __weProbeEvents.push(properties); return original.call(this, properties);
            };
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        renderer.applyProperties(project.resolvedProperties, values: [:])
        renderer.play()
        let deadline = ContinuousClock.now + .seconds(30)
        var received = false
        while ContinuousClock.now < deadline {
            if (try? await webView.evaluateJavaScript("window.__weProbeEvents && window.__weProbeEvents.length > 0") as? Bool) == true {
                received = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(received, "The local web wallpaper must receive its initial properties")
        try await Task.sleep(for: .milliseconds(500))
        let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? TextureSnapshotError.imageCreationFailed) }
            }
        }
        let tiff = try #require(snapshot.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("web.png"))
        renderer.pause()
        let pausedBefore = try #require(try await webView.evaluateJavaScript("window.__weProbeTicks") as? Int)
        try await Task.sleep(for: .milliseconds(150))
        let pausedAfter = try #require(try await webView.evaluateJavaScript("window.__weProbeTicks") as? Int)
        renderer.play()
        try await Task.sleep(for: .milliseconds(150))
        let resumed = try #require(try await webView.evaluateJavaScript("window.__weProbeTicks") as? Int)
        let errors = (try await webView.evaluateJavaScript("window.__weProbeErrors") as? [String]) ?? []
        let propertyCount = (try await webView.evaluateJavaScript("Object.keys(window.__weProbeEvents[0]).length") as? Int) ?? 0
        let report: [String: Any] = ["project": "860265906", "property_count": propertyCount, "script_errors": errors,
                                   "paused_before": pausedBefore, "paused_after": pausedAfter, "resumed": resumed,
                                   "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "windows_parity_verified": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        #expect(pausedBefore == pausedAfter)
        #expect(resumed > pausedAfter)
        #expect(propertyCount == project.resolvedProperties.filter { $0.type != .text }.count)
        #expect(errors.isEmpty, "Local wallpaper script errors: \(errors)")
    }
}
