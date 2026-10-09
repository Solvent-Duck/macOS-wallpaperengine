import AVFoundation
import Foundation
import Testing
import NativeSceneCore
import NativeSceneRuntime
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct SceneSoundPlayerTests {
    @MainActor private final class MockPlayer: SceneSoundPlayback {
        var prepared = true
        var nextPlayResult = true
        var isPlaying = false
        var currentTime: TimeInterval = 0
        var volume: Float = 0
        private(set) var prepareCalls = 0
        private(set) var playCalls = 0
        private(set) var pauseCalls = 0
        private(set) var stopCalls = 0
        func prepareToPlay() -> Bool { prepareCalls += 1; return prepared }
        func play() -> Bool { playCalls += 1; if nextPlayResult { isPlaying = true }; return nextPlayResult }
        func pause() { pauseCalls += 1; isPlaying = false }
        func stop() { stopCalls += 1; isPlaying = false }
    }

    private func transport(_ id: Int = 1, state: FrameSoundTransportState = .playing,
                           run: UInt64 = 1, gain: Float = 1) -> FrameSoundTransport {
        FrameSoundTransport(nodeID: NodeID(rawValue: id), state: state, runID: run, gain: gain)
    }
    private func spec(_ id: Int = 1, track: Int = 0, loops: Bool = false, source: URL? = URL(fileURLWithPath: "/sound")) -> SceneSoundTrackSpec {
        SceneSoundTrackSpec(nodeID: NodeID(rawValue: id), trackID: track, loops: loops, source: source)
    }

    @Test func dynamicTrackChangesPreserveExistingPlaybackAndStopDeletedLayers() {
        var mocks: [MockPlayer] = []
        let player = SceneSoundPlayer(trackSpecs: []) { _, _ in
            let mock = MockPlayer(); mocks.append(mock); return mock
        }
        defer { player.dispose() }
        player.updateTracks([spec(1)])
        player.reconcile([transport(1)], outputEnabled: false)
        #expect(mocks.isEmpty)
        player.reconcile([transport(1)], outputEnabled: true)
        #expect(mocks.count == 1 && mocks[0].playCalls == 1)
        player.updateTracks([spec(1), spec(2)])
        player.reconcile([transport(1), transport(2)], outputEnabled: true)
        #expect(mocks.count == 2 && mocks[0].playCalls == 1 && mocks[0].stopCalls == 0)
        player.updateTracks([spec(2)])
        #expect(mocks[0].stopCalls == 1 && !mocks[0].isPlaying)
        #expect(mocks[1].isPlaying && mocks[1].stopCalls == 0)
        player.reconcile([transport(2)], outputEnabled: true)
        #expect(mocks[1].playCalls == 1)
        player.updateTracks([])
        #expect(!player.hasTracks && mocks[1].stopCalls == 1)
        #expect(player.drainTerminalStatuses().isEmpty)
    }

    @Test func deletedDynamicSoundReleasesItsTemporaryAssetAndDecodeBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicSoundTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var availableBudgets: [Int] = [], files: [URL] = []
        let player = SceneSoundPlayer(trackSpecs: [], aggregateCAFBytes: 64) { url, _ in
            let mock = MockPlayer(); mock.prepared = url.pathExtension == "caf"; return mock
        } decoder: { _, _, available in
            availableBudgets.append(available)
            let file = root.appendingPathComponent("\(files.count).caf")
            try Data(repeating: 0, count: 32).write(to: file); files.append(file)
            return SceneSoundDecodedAsset(url: file, byteCount: 32)
        }
        defer { player.dispose() }
        player.updateTracks([spec(1)]); player.reconcile([transport(1)], outputEnabled: true)
        #expect(files.count == 1 && FileManager.default.fileExists(atPath: files[0].path))
        player.updateTracks([spec(2)])
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
        player.reconcile([transport(2)], outputEnabled: true)
        #expect(availableBudgets == [64, 64])
        player.updateTracks([])
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func loopModeWithSeveralSoundsPlaysThemOneAtATimeAndWraps() {
        var mocks: [MockPlayer] = [], loopFlags: [Bool] = []
        func playlistSpec(_ track: Int) -> SceneSoundTrackSpec {
            var spec = spec(1, track: track, loops: true); spec.playlist = true; return spec
        }
        let player = SceneSoundPlayer(trackSpecs: [playlistSpec(0), playlistSpec(1)]) { _, loops in
            let mock = MockPlayer(); mocks.append(mock); loopFlags.append(loops); return mock
        }
        defer { player.dispose() }
        player.reconcile([transport()], outputEnabled: true)
        #expect(mocks.count == 1 && mocks[0].isPlaying)
        player.reconcile([transport()], outputEnabled: true)
        #expect(mocks.count == 1 && mocks[0].playCalls == 1)
        mocks[0].isPlaying = false // first sound ends
        player.reconcile([transport()], outputEnabled: true)
        #expect(mocks.count == 2 && mocks[1].isPlaying && !mocks[0].isPlaying)
        mocks[1].isPlaying = false // second ends, list wraps
        player.reconcile([transport()], outputEnabled: true)
        #expect(mocks[0].isPlaying && mocks[0].playCalls == 2 && !mocks[1].isPlaying)
        #expect(loopFlags == [false, false])
        #expect(player.drainTerminalStatuses().isEmpty)
    }

    @Test func mutedAndStartSilentCommandsDoNotCreatePlayers() {
        var factories = 0
        let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in factories += 1; return MockPlayer() }
        player.reconcile([transport()], outputEnabled: false)
        #expect(factories == 0)
        player.reconcile([transport(state: .stopped)], outputEnabled: true)
        #expect(factories == 0)
        player.reconcile([transport()], outputEnabled: true)
        #expect(factories == 1)
    }

    @Test func playIsIdempotentAndAppliesResolvedGainOnce() {
        let mock = MockPlayer()
        let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in mock }
        player.reconcile([transport(gain: 0.8)], outputEnabled: true, masterVolume: 0.5)
        player.reconcile([transport(gain: 0.8)], outputEnabled: true, masterVolume: 0.5)
        #expect(mock.playCalls == 1)
        #expect(mock.volume == 0.4)
    }

    @Test func stopThenNewRunRewindsAndStartsAgain() {
        let mock = MockPlayer(); mock.currentTime = 3
        let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in mock }
        player.reconcile([transport(run: 1)], outputEnabled: true)
        mock.currentTime = 2
        player.reconcile([transport(state: .stopped, run: 1)], outputEnabled: true)
        player.reconcile([transport(run: 2)], outputEnabled: true)
        #expect(mock.stopCalls >= 2) // explicit stop plus required new-run reset
        #expect(mock.currentTime == 0)
        #expect(mock.playCalls == 2)
    }

    @Test func pauseAndGateResumePreservePositionAndRun() {
        let mock = MockPlayer(); let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in mock }
        player.reconcile([transport()], outputEnabled: true)
        mock.currentTime = 1.25
        player.reconcile([transport(state: .paused)], outputEnabled: true)
        player.reconcile([transport()], outputEnabled: true)
        #expect(mock.currentTime == 1.25)
        player.reconcile([transport()], outputEnabled: false)
        player.reconcile([transport()], outputEnabled: false)
        player.reconcile([transport()], outputEnabled: false)
        player.reconcile([transport()], outputEnabled: true)
        #expect(mock.currentTime == 1.25)
        #expect(mock.playCalls == 3) // start, command resume, gate resume; no rewind
    }

    @Test func completionBeforePauseDoesNotReplayTheSameRun() {
        let mock = MockPlayer(); let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in mock }
        player.reconcile([transport()], outputEnabled: true)
        mock.isPlaying = false
        player.reconcile([transport(state: .paused)], outputEnabled: true)
        #expect(player.drainTerminalStatuses().isEmpty)
        player.reconcile([transport()], outputEnabled: true)
        #expect(mock.playCalls == 1)
        #expect(player.drainTerminalStatuses().map { $0.2 } == [true])
    }

    @Test func finiteSiblingsCompleteOnceOnlyAfterAllViableTracksFinish() {
        let first = MockPlayer(), second = MockPlayer(); var next = 0
        let player = SceneSoundPlayer(trackSpecs: [spec(track: 0), spec(track: 1)]) { _, _ in
            defer { next += 1 }; return next == 0 ? first : second
        }
        player.reconcile([transport()], outputEnabled: true)
        first.isPlaying = false
        player.reconcile([transport()], outputEnabled: true)
        #expect(player.drainTerminalStatuses().isEmpty)
        second.isPlaying = false
        player.reconcile([transport()], outputEnabled: true)
        let completed = player.drainTerminalStatuses()
        #expect(completed.count == 1)
        #expect(completed.first?.0.rawValue == 1)
        #expect(completed.first?.1 == 1)
        #expect(completed.first?.2 == true)
        player.reconcile([transport()], outputEnabled: true)
        #expect(player.drainTerminalStatuses().isEmpty)
    }

    @Test func loopingTrackNeverReportsFiniteCompletion() {
        let loop = MockPlayer(); let player = SceneSoundPlayer(trackSpecs: [spec(loops: true)]) { _, _ in loop }
        player.reconcile([transport()], outputEnabled: true)
        player.reconcile([transport()], outputEnabled: true)
        #expect(player.drainTerminalStatuses().isEmpty)
        #expect(loop.playCalls == 1)
    }

    @Test func closedGateObservesAlreadyFinishedFiniteTrackWithoutRestartingIt() {
        let mock = MockPlayer(); let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in mock }
        player.reconcile([transport()], outputEnabled: true)
        mock.isPlaying = false
        player.reconcile([transport()], outputEnabled: false)
        #expect(player.drainTerminalStatuses().map { $0.2 } == [true])
        player.reconcile([transport()], outputEnabled: false)
        player.reconcile([transport()], outputEnabled: false)
        player.reconcile([transport()], outputEnabled: true)
        #expect(mock.playCalls == 1)
        #expect(player.drainTerminalStatuses().isEmpty)
    }

    @Test func closedGateDoesNotAttributeOldCompletionToANewRun() {
        let mock = MockPlayer(); let player = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in mock }
        player.reconcile([transport(run: 1)], outputEnabled: true)
        mock.isPlaying = false
        player.reconcile([transport(run: 2)], outputEnabled: false)
        #expect(player.drainTerminalStatuses().isEmpty)
        player.reconcile([transport(run: 2)], outputEnabled: true)
        #expect(mock.playCalls == 2)
        #expect(player.drainTerminalStatuses().isEmpty)
    }

    @Test func absentAssetAndFactoryFailureAreCachedAsOneTerminalFailure() {
        var factories = 0
        let absent = SceneSoundPlayer(trackSpecs: [spec(source: nil)]) { _, _ in factories += 1; return MockPlayer() }
        absent.reconcile([transport()], outputEnabled: true)
        absent.reconcile([transport()], outputEnabled: true)
        #expect(factories == 0)
        #expect(absent.drainTerminalStatuses().map { $0.2 } == [false])

        let failing = SceneSoundPlayer(trackSpecs: [spec()]) { _, _ in factories += 1; throw NSError(domain: "test", code: 1) } decoder: { _, _, _ in throw NSError(domain: "test", code: 2) }
        failing.reconcile([transport(run: 4)], outputEnabled: true)
        failing.reconcile([transport(run: 4)], outputEnabled: true)
        #expect(factories == 1)
        let failures = failing.drainTerminalStatuses()
        #expect(failures.count == 1)
        #expect(failures.first?.1 == 4)
        #expect(failures.first?.2 == false)
    }

    @Test func replayKeepsFailedSiblingCachedWhileViableSiblingCanComplete() {
        let viable = MockPlayer(); var factories = 0
        let player = SceneSoundPlayer(trackSpecs: [spec(track: 0, source: nil), spec(track: 1)]) { _, _ in
            factories += 1; return viable
        }
        player.reconcile([transport(run: 1)], outputEnabled: true)
        viable.isPlaying = false
        player.reconcile([transport(run: 1)], outputEnabled: true)
        #expect(player.drainTerminalStatuses().map { $0.2 } == [true])
        player.reconcile([transport(run: 2)], outputEnabled: true)
        #expect(factories == 1) // missing sibling remains unavailable for this session
        #expect(viable.playCalls == 2)
    }

    @Test func fallbackRetainsSuccessfulCAFUntilDisposeAndRemovesRejectedCapOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneSoundPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let caf = root.appendingPathComponent("decoded.caf")
        try Data([0, 1, 2]).write(to: caf)
        var factoryCalls = 0
        let fallback = MockPlayer(); fallback.prepared = true
        let player = SceneSoundPlayer(trackSpecs: [spec()], aggregateCAFBytes: 64) { _, _ in
            factoryCalls += 1
            let direct = MockPlayer(); direct.prepared = factoryCalls != 1
            return factoryCalls == 1 ? direct : fallback
        } decoder: { _, _, _ in SceneSoundDecodedAsset(url: caf, byteCount: 3) }
        player.reconcile([transport()], outputEnabled: true)
        #expect(FileManager.default.fileExists(atPath: caf.path))
        player.dispose()
        #expect(!FileManager.default.fileExists(atPath: caf.path))

        let rejected = root.appendingPathComponent("rejected.caf")
        try Data(repeating: 1, count: 8).write(to: rejected)
        let capped = SceneSoundPlayer(trackSpecs: [spec()], perAssetCAFBytes: 4) { _, _ in let p = MockPlayer(); p.prepared = false; return p } decoder: { _, _, _ in SceneSoundDecodedAsset(url: rejected, byteCount: 8) }
        capped.reconcile([transport()], outputEnabled: true)
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
        #expect(capped.drainTerminalStatuses().map { $0.2 } == [false])
    }

    @Test func productionPCMConversionPreservesFramesAcrossBufferBoundaries() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("SceneSoundPCM-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: source) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let count: AVAudioFrameCount = 32_891
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(count) {
            channels[0][frame] = Float(frame % 101) / 101
            channels[1][frame] = -Float(frame % 97) / 97
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        var converted: URL?
        let player = SceneSoundPlayer(trackSpecs: [spec(source: source)]) { url, _ in
            let result = MockPlayer()
            result.prepared = url != source // exercise the real fallback decoder
            if result.prepared { converted = url }
            return result
        }
        defer { player.dispose() }
        player.reconcile([transport()], outputEnabled: true)
        let decodedURL = try #require(converted)
        let decoded = try AVAudioFile(forReading: decodedURL)
        #expect(decoded.length == Int64(count))
        #expect(decoded.fileFormat.isInterleaved)
        let actual = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: count))
        try decoded.read(into: actual)
        #expect(actual.frameLength == count)
        let actualChannels = try #require(actual.floatChannelData)
        for channel in 0..<2 {
            #expect(Array(UnsafeBufferPointer(start: actualChannels[channel], count: Int(count))) ==
                    Array(UnsafeBufferPointer(start: channels[channel], count: Int(count))))
        }
    }
}
