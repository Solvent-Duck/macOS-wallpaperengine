import AVFoundation
import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing
@testable import WallpaperEngine

/// Opt-in native output acceptance for a short, lead-selected authored Ogg.
/// Every physical player runs at zero gain; this verifies transport, not audibility.
@MainActor
@Suite(.serialized)
struct SceneSoundPlayerAudioTests {
    private final class ObservedPlayer: SceneSoundPlayback {
        let audio: AVAudioPlayer
        init(_ url: URL, loops: Bool) throws {
            audio = try AVAudioPlayer(contentsOf: url)
            audio.numberOfLoops = loops ? -1 : 0
        }
        var isPlaying: Bool { audio.isPlaying }
        var currentTime: TimeInterval { get { audio.currentTime } set { audio.currentTime = newValue } }
        var volume: Float { get { audio.volume } set { audio.volume = newValue } }
        func prepareToPlay() -> Bool { audio.prepareToPlay() }
        func play() -> Bool { audio.play() }
        func pause() { audio.pause() }
        func stop() { audio.stop() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_SOUND_OGG_PROBE"] != nil))
    func authoredOggTransportUsesPCMAndCompletesAtZeroGain() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WE_SOUND_OGG_PROBE"])
        let source = URL(fileURLWithPath: path)
        let input = try AVAudioFile(forReading: source)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        // Keep accidental selection of a full song out of this bounded probe.
        try #require(duration > 0.8 && duration < 3)
        var attempts: [(URL, ObservedPlayer)] = []
        let player = SceneSoundPlayer(trackSpecs: [SceneSoundTrackSpec(nodeID: NodeID(rawValue: 1), trackID: 0, loops: false, source: source)]) { url, loops in
            let observed = try ObservedPlayer(url, loops: loops)
            attempts.append((url, observed))
            return observed
        }
        defer { player.dispose() }
        func command(_ state: FrameSoundTransportState = .playing, run: UInt64 = 1, enabled: Bool = true) {
            player.reconcile([FrameSoundTransport(nodeID: NodeID(rawValue: 1), state: state, runID: run, gain: 0.7)],
                             outputEnabled: enabled, masterVolume: 0)
        }
        command(enabled: false)
        #expect(attempts.isEmpty)
        command()
        try #require(attempts.count == 2, "This fixture must exercise the direct-prepare failure and real PCM fallback")
        let (converted, physical) = try #require(attempts.last)
        #expect(converted != source)
        #expect(try AVAudioFile(forReading: converted).length == input.length)
        #expect(physical.volume == 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(physical.isPlaying && physical.currentTime > 0.05)
        command(.paused)
        let pausedAt = physical.currentTime
        try await Task.sleep(for: .milliseconds(120))
        #expect(abs(physical.currentTime - pausedAt) < 0.02)
        command()
        try await Task.sleep(for: .milliseconds(120))
        #expect(physical.currentTime > pausedAt + 0.04)
        command(enabled: false)
        let mutedAt = physical.currentTime
        try await Task.sleep(for: .milliseconds(120))
        command(enabled: false)
        #expect(abs(physical.currentTime - mutedAt) < 0.02)
        #expect(player.drainTerminalStatuses().isEmpty)
        command()
        let deadline = ContinuousClock.now + .seconds(4)
        while physical.isPlaying && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!physical.isPlaying)
        command()
        let terminal = player.drainTerminalStatuses()
        #expect(terminal.count == 1 && terminal.first?.1 == 1 && terminal.first?.2 == true)
        command(run: 2)
        #expect(physical.isPlaying && physical.currentTime < 0.1)
        #expect(attempts.count == 2) // reuse the successful conversion on replay
        command(.stopped, run: 2)
        #expect(!physical.isPlaying && physical.currentTime == 0)
        player.dispose()
        #expect(!FileManager.default.fileExists(atPath: converted.path))
        print("[SceneSoundAudioProbe] \(source.lastPathComponent): PCM frames=\(input.length), duration=\(duration), pause=\(pausedAt), gate=\(mutedAt), completion/replay/cleanup checked; gain=0")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_SOUND_OGG_PROBE"] != nil))
    func authoredOggLoopStaysActiveBeyondTwoClipLengthsAtZeroGain() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WE_SOUND_OGG_PROBE"])
        let source = URL(fileURLWithPath: path)
        let input = try AVAudioFile(forReading: source)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        try #require(duration > 0.8 && duration < 3)
        var physical: ObservedPlayer?
        let player = SceneSoundPlayer(trackSpecs: [SceneSoundTrackSpec(nodeID: NodeID(rawValue: 1), trackID: 0, loops: true, source: source)]) { url, loops in
            let result = try ObservedPlayer(url, loops: loops)
            physical = result
            return result
        }
        defer { player.dispose() }
        let transport = FrameSoundTransport(nodeID: NodeID(rawValue: 1), state: .playing, runID: 1, gain: 0.8)
        player.reconcile([transport], outputEnabled: true, masterVolume: 0)
        let observed = try #require(physical)
        try #require(observed.isPlaying && observed.volume == 0)
        let deadline = ContinuousClock.now + .seconds(2 * duration + 0.15)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(40))
            player.reconcile([transport], outputEnabled: true, masterVolume: 0)
        }
        #expect(observed.isPlaying && observed.audio.numberOfLoops == -1)
        #expect(player.drainTerminalStatuses().isEmpty)
        print("[SceneSoundAudioProbe] \(source.lastPathComponent): loop active beyond two \(duration)-second clips; gain=0")
    }
}
