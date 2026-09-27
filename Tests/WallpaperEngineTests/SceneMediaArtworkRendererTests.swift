import CoreGraphics
import Foundation
import ImageIO
import NativeSceneCore
import NativeSceneRuntime
import Testing
@testable import WallpaperEngine

/// Synthetic end-to-end media delivery through the real app renderer.
@MainActor
@Suite(.serialized)
struct SceneMediaArtworkRendererTests {
    @Test func syntheticArtworkSurvivesRendererCreationAndRecoveryAndDrivesMediaScript() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "WEMediaArtworkRenderer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let storage = try SceneScriptStorage()
        let renderer = SceneRenderer(directoryURL: root, sceneDescription: scene, scriptStorage: storage)
        defer { renderer.stop() }

        let reader = Reader()
        await reader.set(.music, .sample(Self.sample(artwork: .embedded(Data([0xA])))))
        let controller = MediaIntegrationController(
            defaults: defaults,
            reader: reader,
            processID: { $0 == .music ? 7 : nil },
            pollsAutomatically: false,
            artworkLoader: { _ in Self.thumbnail() }
        )
        controller.onUpdate = { renderer.updateMediaState($0) }
        controller.start()
        defer { controller.stop() }

        // The controller publishes metadata and artwork before SceneRenderer
        // constructs its native renderer. play() must consume that retained state.
        await controller.refresh()
        try await waitFor { controller.state.thumbnail.artwork != nil }
        #expect(controller.state.properties.title == "Synthetic")
        renderer.play()
        let initial = try await screenshot(renderer, root: root, name: "initial")
        expectRGB(initial, x: 1, expected: [12, 90, 200]) // authored cover pixel
        expectRGB(initial, x: 5, expected: [255, 0, 0]) // mediaPropertiesChanged marker
        expectRGB(initial, x: 7, expected: [51, 153, 230]) // palette set by mediaThumbnailChanged

        // Recovery drops and reconstructs NativeSceneRenderer without another
        // controller publish; latestMediaState must be reapplied by play().
        renderer.recoverFromSleep()
        let recovered = try await screenshot(renderer, root: root, name: "recovered")
        expectRGB(recovered, x: 1, expected: [12, 90, 200])
        expectRGB(recovered, x: 5, expected: [255, 0, 0])
        expectRGB(recovered, x: 7, expected: [51, 153, 230])

        // A metadata-valid sample without artwork clears the current cover and
        // thumbnail callback marker while retaining the title callback marker.
        await reader.set(.music, .sample(Self.sample(artwork: .absent)))
        await controller.refresh()
        try await waitFor { !controller.state.thumbnail.hasThumbnail }
        let missingArtwork = try await screenshot(renderer, root: root, name: "missing-artwork")
        expectRGB(missingArtwork, x: 1, expected: [0, 0, 0])
        expectRGB(missingArtwork, x: 5, expected: [255, 0, 0])
        expectRGB(missingArtwork, x: 7, expected: [0, 0, 0])

        // Stopping the controller delivers the disabled state, hiding both
        // authored event markers and preventing stale artwork revival.
        controller.stop()
        let stopped = try await screenshot(renderer, root: root, name: "stopped")
        expectRGB(stopped, x: 1, expected: [0, 0, 0])
        expectRGB(stopped, x: 5, expected: [0, 0, 0])
        expectRGB(stopped, x: 7, expected: [0, 0, 0])
    }

    private func screenshot(_ renderer: SceneRenderer, root: URL, name: String) async throws -> [UInt8] {
        let output = root.appendingPathComponent("\(name).png")
        let waiter = ScreenshotWaiter()
        renderer.requestScreenshot(outputURL: output, afterFrames: 3) { result in
            switch result {
            case .success:
                do { waiter.finish(.success(try readPNG(output))) }
                catch { waiter.finish(.failure(error)) }
            case .failure(let error):
                waiter.finish(.failure(error))
            }
        }
        let timeout = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
                waiter.finish(.failure(ScreenshotTimeout()))
            } catch {
                // The screenshot completed first.
            }
        }
        defer { timeout.cancel() }
        return try await waiter.wait()
    }

    private func expectRGB(_ pixels: [UInt8], x: Int, expected: [UInt8]) {
        let offset = (4 * 8 + x) * 4
        for channel in 0..<3 {
            #expect(abs(Int(pixels[offset + channel]) - Int(expected[channel])) <= 1)
        }
    }

    private func readPNG(_ url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 8 && image.height == 8)
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 8 * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        if let directory = ProcessInfo.processInfo.environment["WE_MEDIA_REPORT_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in [url, url.appendingPathExtension("json")] {
                try Data(contentsOf: file).write(to: destination.appendingPathComponent(file.lastPathComponent))
            }
        }
        return rgba
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEMediaArtworkRenderer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func json(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        let titleScript = "export function mediaPropertiesChanged(e) { thisLayer.visible = e.title === 'Synthetic'; }"
        let thumbnailScript = "export function mediaThumbnailChanged(e) { thisLayer.visible = e.hasThumbnail; thisLayer.color = e.primaryColor; }"
        try json("scene.json", [
            "camera": [:],
            "general": ["orthogonalprojection": ["width": 8, "height": 8], "clearcolor": "0 0 0"],
            "objects": [
                ["id": 1, "image": "cover-model.json", "origin": "2 4 0"],
                ["id": 2, "image": "title-model.json", "origin": "5 4 0",
                 "visible": ["value": false, "script": titleScript]],
                ["id": 3, "image": "thumbnail-model.json", "origin": "7 4 0",
                 "visible": ["value": false, "script": thumbnailScript],
                 "color": ["value": "0 0 0", "script": thumbnailScript]],
            ],
        ])
        try json("cover-model.json", ["material": "cover-material.json", "width": 4, "height": 8])
        try json("title-model.json", ["material": "title-material.json", "width": 2, "height": 8])
        try json("thumbnail-model.json", ["material": "thumbnail-material.json", "width": 2, "height": 8])
        try json("cover-material.json", ["passes": [[
            "shader": "cover", "blending": "normal",
            "usertextures": [["name": "$mediaThumbnail", "type": "system"]],
        ]]])
        try json("title-material.json", ["passes": [["shader": "title", "blending": "normal"]]])
        try json("thumbnail-material.json", ["passes": [["shader": "thumbnail", "blending": "normal"]]])
        let vertex = "attribute vec3 a_Position; uniform mat4 g_ModelViewProjectionMatrix; void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }"
        for name in ["cover", "title", "thumbnail"] {
            try vertex.write(to: root.appendingPathComponent("shaders/\(name).vert"), atomically: true, encoding: .utf8)
        }
        try "uniform sampler2D g_Texture0; void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5, 0.5)); }"
            .write(to: root.appendingPathComponent("shaders/cover.frag"), atomically: true, encoding: .utf8)
        try "void main() { gl_FragColor = vec4(1, 0, 0, 1); }"
            .write(to: root.appendingPathComponent("shaders/title.frag"), atomically: true, encoding: .utf8)
        try "uniform vec3 g_Color; uniform float g_Alpha; void main() { gl_FragColor = vec4(g_Color, g_Alpha); }"
            .write(to: root.appendingPathComponent("shaders/thumbnail.frag"), atomically: true, encoding: .utf8)
        return root
    }

    private static func sample(artwork: MediaArtworkPayload) -> MediaPlayerSample {
        var state = SceneMediaState()
        state.enabled = true
        state.playback = .playing
        state.properties.title = "Synthetic"
        return MediaPlayerSample(state: state, trackKey: "synthetic-track", artwork: artwork)
    }

    nonisolated private static func thumbnail() -> SceneMediaState.Thumbnail {
        var thumbnail = SceneMediaState.Thumbnail()
        thumbnail.identifier = "synthetic-cover"
        thumbnail.hasThumbnail = true
        thumbnail.artwork = SceneMediaArtwork(width: 2, height: 2,
            rgba8: Data(Array(repeating: [12, 90, 200, 255], count: 4).flatMap { $0 }))
        thumbnail.primaryColor = RuntimeVector3(x: 0.2, y: 0.6, z: 0.9)
        return thumbnail
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "synthetic media update did not arrive")
    }

    @MainActor
    private final class ScreenshotWaiter {
        private var result: Result<[UInt8], Error>?
        private var continuation: CheckedContinuation<[UInt8], Error>?

        func wait() async throws -> [UInt8] {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(_ result: Result<[UInt8], Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private struct ScreenshotTimeout: LocalizedError {
        var errorDescription: String? { "Timed out waiting for SceneRenderer offscreen screenshot" }
    }

    private actor Reader: MediaPlayerReading {
        private var values: [MediaPlayer: MediaPlayerReadResult] = [:]

        func set(_ player: MediaPlayer, _ value: MediaPlayerReadResult) { values[player] = value }
        func read(player: MediaPlayer, processID: Int32, previousTrackKey: String?, refreshArtwork: Bool) async -> MediaPlayerReadResult {
            values[player] ?? .unavailable
        }
        func requestPermission(processID: Int32) async -> Int32 { 0 }
    }
}
