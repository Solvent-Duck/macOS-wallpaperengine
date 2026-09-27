import AVFoundation
import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing
@testable import WallpaperEngine

/// Lead-only integration check for the actual renderer packet/output/status path.
@MainActor
@Suite(.serialized)
struct SceneSoundRendererTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_SOUND_OGG_PROBE"] != nil))
    func completedSoundRestartsWithTheReplacementRuntimeAfterRecovery() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WE_SOUND_OGG_PROBE"])
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let duration = Double(input.length) / input.processingFormat.sampleRate
        try #require(duration > 0.8 && duration < 3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneSoundRenderer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(atPath: path, toPath: root.appendingPathComponent("sound.ogg").path)
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        let script = """
        export function init() { localStorage.set('initializations', (localStorage.get('initializations') || 0) + 1); }
        export function update(value) { localStorage.set('playing', thisLayer.isPlaying()); return value; }
        """
        let sceneJSON: [String: Any] = [
            "camera": ["center": "0 0 0", "eye": "0 0 1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [["id": 1, "sound": ["sound.ogg"], "playbackmode": "single", "volume": 0,
                         "origin": ["value": "0 0 0", "script": script]]],
        ]
        try JSONSerialization.data(withJSONObject: sceneJSON).write(to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let storage = try SceneScriptStorage()
        let renderer = SceneRenderer(directoryURL: root, sceneDescription: scene, scriptStorage: storage)
        defer { renderer.stop() }
        func stored(_ key: String) throws -> String? {
            try storage.request("{\"operation\":\"get\",\"key\":\"\(key)\"}")
        }
        func startClock(_ suffix: String) {
            renderer.requestScreenshot(outputURL: root.appendingPathComponent("\(suffix).png"), afterFrames: 3) { result in
                if case let .failure(error) = result { Issue.record("Offscreen sound integration frame failed: \(error)") }
            }
        }
        func waitUntilStopped() async throws {
            let deadline = ContinuousClock.now + .seconds(duration + 2)
            while try stored("playing") != "false", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(try stored("playing") == "false")
        }
        renderer.play()
        startClock("initial")
        try await Task.sleep(for: .milliseconds(250))
        #expect(try stored("initializations") == "1")
        #expect(try stored("playing") == "true") // logical activity while globally muted
        renderer.isMuted = false // authored layer gain is zero
        try await Task.sleep(for: .seconds(duration * 0.4))
        #expect(try stored("playing") == "true") // no immediate failed-player acknowledgement
        try await waitUntilStopped()
        renderer.recoverFromSleep()
        startClock("recovered")
        try await Task.sleep(for: .seconds(duration * 0.4))
        #expect(try stored("initializations") == "2")
        #expect(try stored("playing") == "true") // old completed run must not terminate the replacement
        try await waitUntilStopped()
        print("[SceneSoundRendererProbe] Both original and recovered runtime played the \(duration)-second Ogg to a terminal status through SceneRenderer; authored gain=0")
    }
}
