import Foundation
import NativeSceneRuntime
import Testing
@testable import WallpaperEngine

@MainActor
struct MediaIntegrationControllerTests {
    @Test func inactiveMusicArtworkIsNeverLoadedAndPausedSourceBeatsStopped() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        let loads = ArtworkLoads()
        await reader.set(.music, .sample(sample("Music", playback: .paused,
            artwork: .music(processID: 7, trackKey: "Music"))))
        await reader.set(.spotify, .sample(sample("Spotify", artwork: .embedded(Data([2])))))
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { _ in 7 }, pollsAutomatically: false,
            artworkLoader: { await loads.load($0) })
        controller.start()
        defer { controller.stop() }
        for _ in 0..<3 { await controller.refresh() }
        try await waitFor { await loads.count > 0 }
        #expect(await loads.musicCount == 0)
        #expect(controller.state.properties.title == "Spotify")
        await reader.set(.spotify, .sample(sample("", playback: .stopped)))
        await controller.refresh()
        try await waitFor { await loads.musicCount == 1 }
        #expect(controller.state.properties.title == "Music")
        #expect(controller.state.playback == .paused)
    }

    @Test func automaticChoosesPlayingSourceAndExplicitSelectionPersists() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        await reader.set(.music, .sample(sample("Music", playback: .paused)))
        await reader.set(.spotify, .sample(sample("Spotify")))
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { _ in 7 }, pollsAutomatically: false)
        controller.start()
        await controller.refresh()
        #expect(controller.state.properties.title == "Spotify")
        #expect(await reader.permissionRequests == 0)
        controller.select(.music)
        await controller.refresh()
        #expect(controller.state.properties.title == "Music")
        let restored = MediaIntegrationController(defaults: defaults, reader: reader, processID: { _ in 7 }, pollsAutomatically: false)
        #expect(restored.selection == .music)
        controller.stop()
        #expect(!controller.state.enabled && controller.state.properties.title.isEmpty)
    }

    @Test func permissionAndUnavailableStatesClearMediaWithoutPrompting() async {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        await reader.set(.music, .sample(sample("A")))
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { $0 == .music ? 7 : nil }, pollsAutomatically: false)
        controller.start()
        await controller.refresh()
        #expect(controller.state.enabled)
        await reader.set(.music, .permissionRequired)
        await controller.refresh()
        #expect(!controller.state.enabled && controller.state.properties.title.isEmpty)
        #expect(controller.status == "Connect Music to share media")
        #expect(await reader.permissionRequests == 0)
        await reader.set(.music, .permissionDenied)
        await controller.refresh()
        #expect(controller.status.contains("permission denied"))
        controller.select(.off)
        let reads = await reader.reads
        await controller.refresh()
        #expect(await reader.reads == reads)
        #expect(!controller.state.enabled)
        controller.stop()
    }

    @Test func delayedOldArtworkCannotReplaceANewerTrackOrItsTimeline() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        let gate = ArtworkGate()
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { $0 == .music ? 7 : nil }, pollsAutomatically: false,
            artworkLoader: { await gate.load($0) })
        controller.start()
        defer { controller.stop() }
        await reader.set(.music, .sample(sample("A", artwork: .embedded(Data([1])))))
        await controller.refresh()
        #expect(controller.state.properties.title == "A")
        #expect(!controller.state.thumbnail.hasThumbnail)
        try await waitFor { await gate.hasRequest(1) }
        await reader.set(.music, .sample(sample("B", artwork: .embedded(Data([2])))))
        await controller.refresh()
        try await waitFor { await gate.hasRequest(2) }
        // A timeline update is delivered while the cover download is pending.
        var timeline = sample("B", artwork: .unchanged)
        timeline.state.position = 17
        await reader.set(.music, .sample(timeline))
        await controller.refresh()
        await gate.finish(1, thumbnail: thumbnail(1))
        await Task.yield()
        #expect(controller.state.properties.title == "B")
        #expect(!controller.state.thumbnail.hasThumbnail)
        await gate.finish(2, thumbnail: thumbnail(2))
        try await waitFor { controller.state.thumbnail.identifier == "2" }
        #expect(controller.state.properties.title == "B")
        #expect(controller.state.position == 17)
    }

    @Test func disablingDiscardsLateArtworkAndDoesNotReviveOnRestart() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        let gate = ArtworkGate()
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { $0 == .music ? 7 : nil }, pollsAutomatically: false,
            artworkLoader: { await gate.load($0) })
        await reader.set(.music, .sample(sample("A", artwork: .embedded(Data([1])))))
        controller.start()
        await controller.refresh()
        try await waitFor { await gate.hasRequest(1) }
        controller.select(.off)
        await gate.finish(1, thumbnail: thumbnail(1))
        await Task.yield()
        #expect(!controller.state.enabled && !controller.state.thumbnail.hasThumbnail)
        await reader.set(.music, .unavailable)
        controller.select(.music)
        await controller.refresh()
        #expect(!controller.state.enabled && !controller.state.thumbnail.hasThumbnail)
        controller.stop()
    }

    @Test func identicalArtworkIsRetainedAcrossMetadataAndPauseUpdates() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        let artwork = thumbnail(9)
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { $0 == .music ? 7 : nil }, pollsAutomatically: false,
            artworkLoader: { _ in artwork })
        controller.start()
        defer { controller.stop() }
        await reader.set(.music, .sample(sample("A", artwork: .embedded(Data([9])))))
        await controller.refresh()
        try await waitFor { controller.state.thumbnail.hasThumbnail }
        var updated = sample("A", playback: .paused, artwork: .unchanged)
        updated.state.position = 25
        await reader.set(.music, .sample(updated))
        await controller.refresh()
        #expect(controller.state.thumbnail == artwork)
        #expect(controller.state.playback == .paused && controller.state.position == 25)
        await reader.set(.music, .sample(sample("A", artwork: .absent)))
        await controller.refresh()
        #expect(!controller.state.thumbnail.hasThumbnail && controller.state.thumbnail.artwork == nil)
    }

    @Test func latePlayerReadCannotOverrideDisabledSelection() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let reader = Reader()
        await reader.suspendNextRead()
        let controller = MediaIntegrationController(defaults: defaults, reader: reader, processID: { $0 == .music ? 7 : nil }, pollsAutomatically: false)
        controller.start()
        let pending = Task { await controller.refresh() }
        try await waitFor { await reader.hasPendingRead }
        controller.select(.off)
        await reader.finishRead(.sample(sample("Late")))
        await pending.value
        #expect(!controller.state.enabled && controller.state.properties.title.isEmpty)
        #expect(controller.selection == .off)
        controller.stop()
    }

    private let defaultsSuite = "WEMediaTests-" + UUID().uuidString
    private func temporaryDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        return defaults
    }

    private func sample(_ title: String, playback: SceneMediaState.Playback = .playing,
                        artwork: MediaArtworkPayload = .absent) -> MediaPlayerSample {
        var state = SceneMediaState()
        state.enabled = true
        state.playback = playback
        state.properties.title = title
        state.duration = 180
        return MediaPlayerSample(state: state, trackKey: title, artwork: artwork)
    }

    private func thumbnail(_ value: UInt8) -> SceneMediaState.Thumbnail {
        var thumbnail = SceneMediaState.Thumbnail()
        thumbnail.hasThumbnail = true
        thumbnail.identifier = String(value)
        thumbnail.artwork = SceneMediaArtwork(width: 1, height: 1, rgba8: Data([value, 0, 0, 255]))
        return thumbnail
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition(), "asynchronous media operation did not reach its expected state")
    }

    private actor ArtworkLoads {
        var count = 0
        var musicCount = 0
        func load(_ payload: MediaArtworkPayload) -> SceneMediaState.Thumbnail? {
            count += 1
            if case .music = payload { musicCount += 1 }
            return nil
        }
    }

    private actor ArtworkGate {
        private var pending: [UInt8: CheckedContinuation<SceneMediaState.Thumbnail?, Never>] = [:]
        func load(_ payload: MediaArtworkPayload) async -> SceneMediaState.Thumbnail? {
            guard case .embedded(let bytes) = payload, let key = bytes.first else { return nil }
            return await withCheckedContinuation { pending[key] = $0 }
        }
        func hasRequest(_ key: UInt8) -> Bool { pending[key] != nil }
        func finish(_ key: UInt8, thumbnail: SceneMediaState.Thumbnail) { pending.removeValue(forKey: key)?.resume(returning: thumbnail) }
    }

    private actor Reader: MediaPlayerReading {
        private var values: [MediaPlayer: MediaPlayerReadResult] = [:]
        private var suspend = false
        private var pendingRead: CheckedContinuation<MediaPlayerReadResult, Never>?
        var permissionRequests = 0
        var reads = 0
        var hasPendingRead: Bool { pendingRead != nil }
        func set(_ player: MediaPlayer, _ result: MediaPlayerReadResult) { values[player] = result }
        func suspendNextRead() { suspend = true }
        func finishRead(_ result: MediaPlayerReadResult) { pendingRead?.resume(returning: result); pendingRead = nil }
        func read(player: MediaPlayer, processID: Int32, previousTrackKey: String?, refreshArtwork: Bool) async -> MediaPlayerReadResult {
            reads += 1
            if suspend { suspend = false; return await withCheckedContinuation { pendingRead = $0 } }
            return values[player] ?? .unavailable
        }
        func requestPermission(processID: Int32) -> Int32 { permissionRequests += 1; return 0 }
    }
}
