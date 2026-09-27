import AppKit
import Foundation
import NativeSceneRuntime

enum MediaSourceSelection: String, CaseIterable {
    case off, automatic, music, spotify

    var title: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatic"
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    var players: [MediaPlayer] {
        switch self {
        case .off: return []
        case .automatic: return MediaPlayer.allCases
        case .music: return [.music]
        case .spotify: return [.spotify]
        }
    }
}

/// One player poller serves every display. Unavailable/disabled sources clear the
/// state; stopping or changing selection invalidates outstanding asynchronous reads.
@MainActor
final class MediaIntegrationController {
    private static let preferenceKey = "MediaIntegration.Source"
    private let defaults: UserDefaults
    private let reader: any MediaPlayerReading
    private let processID: (MediaPlayer) -> Int32?
    private let artworkLoader: @Sendable (MediaArtworkPayload) async -> SceneMediaState.Thumbnail?
    private let pollsAutomatically: Bool
    private var task: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkRequest = 0
    private var pendingArtworkKey: String?
    private var generation = 0
    private var inFlight = false
    private var active = false
    private var activePlayer: MediaPlayer?
    private var trackKey: String?
    private var lastArtworkRefresh = Date.distantPast
    private var connecting = false

    private(set) var selection: MediaSourceSelection
    private(set) var state = SceneMediaState()
    private(set) var status = "Open Music or Spotify to share media"
    var onUpdate: ((SceneMediaState) -> Void)?

    init(defaults: UserDefaults = .standard, reader: any MediaPlayerReading = AppleEventMediaPlayerReader(),
         processID: @escaping (MediaPlayer) -> Int32? = { player in
             NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).first?.processIdentifier
         }, pollsAutomatically: Bool = true,
         artworkLoader: @escaping @Sendable (MediaArtworkPayload) async -> SceneMediaState.Thumbnail? = MediaIntegrationController.loadArtwork) {
        self.defaults = defaults
        self.reader = reader
        self.processID = processID
        self.pollsAutomatically = pollsAutomatically
        self.artworkLoader = artworkLoader
        selection = defaults.string(forKey: Self.preferenceKey).flatMap(MediaSourceSelection.init(rawValue:)) ?? .automatic
    }

    func select(_ value: MediaSourceSelection) {
        guard value != selection else { return }
        selection = value
        defaults.set(value.rawValue, forKey: Self.preferenceKey)
        let wasActive = active
        stop()
        if wasActive { start() }
    }

    func start() {
        guard !active else { return }
        active = true
        guard selection != .off else { status = "Media integration is off"; return }
        guard pollsAutomatically else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop() {
        active = false
        generation += 1
        task?.cancel()
        task = nil
        cancelArtwork()
        activePlayer = nil
        trackKey = nil
        lastArtworkRefresh = .distantPast
        status = selection == .off ? "Media integration is off" : "Media integration is inactive"
        publish(SceneMediaState())
    }

    /// Called only by an explicit menu action; ordinary polling never prompts.
    func connect(_ player: MediaPlayer) async {
        guard !connecting else { return }
        guard let pid = processID(player) else { status = "Open \(player.name), then choose Connect"; return }
        connecting = true
        let revision = generation
        status = "Waiting for \(player.name) permission"
        let result = await reader.requestPermission(processID: pid)
        connecting = false
        guard revision == generation else { return }
        if result == 0 {
            select(player == .music ? .music : .spotify)
            status = "Connected to \(player.name)"
            await refresh()
        } else {
            status = "Allow \(player.name) in System Settings → Privacy & Security → Automation"
        }
    }

    func refresh() async {
        guard active, selection != .off, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let revision = generation
        let forceArtwork = Date().timeIntervalSince(lastArtworkRefresh) >= 5
        var samples: [(MediaPlayer, MediaPlayerSample)] = []
        var issues: [String] = []
        for player in selection.players {
            guard let pid = processID(player) else { continue }
            let result = await reader.read(player: player, processID: pid,
                previousTrackKey: player == activePlayer ? trackKey : nil, refreshArtwork: forceArtwork)
            guard active, revision == generation, !Task.isCancelled else { return }
            switch result {
            case .sample(let sample): samples.append((player, sample))
            case .permissionRequired: issues.append("Connect \(player.name) to share media")
            case .permissionDenied: issues.append("\(player.name) permission denied — see Automation settings")
            case .unavailable: break
            case .failed(let code): issues.append("\(player.name) is unavailable (\(code))")
            }
        }
        // Keep the current playing source stable when two apps are playing.
        // An explicit selection always wins; paused sources remain available.
        let chosen = samples.first { $0.0 == activePlayer && $0.1.state.playback == .playing }
            ?? samples.first { $0.1.state.playback == .playing }
            ?? samples.first { $0.0 == activePlayer && $0.1.state.playback == .paused }
            ?? samples.first { $0.1.state.playback == .paused }
            ?? samples.first { $0.0 == activePlayer }
            ?? samples.first
        guard let (player, sample) = chosen else {
            cancelArtwork()
            activePlayer = nil
            trackKey = nil
            publish(SceneMediaState())
            status = issues.first ?? "Open Music or Spotify to share media"
            return
        }
        var next = sample.state
        // Thumbnail events have their own asynchronous lifecycle. Keep the
        // accepted image during a replacement fetch so old/new covers can blend.
        next.thumbnail = state.thumbnail
        if case .absent = sample.artwork {
            cancelArtwork()
            next.thumbnail = SceneMediaState.Thumbnail()
        }
        activePlayer = player
        trackKey = sample.trackKey
        status = "Connected to \(player.name)"
        publish(next)
        switch sample.artwork {
        case .unchanged, .absent: break
        case .embedded, .remote, .music:
            if pendingArtworkKey == sample.trackKey { return }
            cancelArtwork()
            lastArtworkRefresh = Date()
            pendingArtworkKey = sample.trackKey
            let request = artworkRequest
            let loader = artworkLoader
            artworkTask = Task { [weak self] in
                let thumbnail = await loader(sample.artwork)
                guard let self, !Task.isCancelled, self.active, self.generation == revision,
                      self.artworkRequest == request, self.activePlayer == player,
                      self.trackKey == sample.trackKey else { return }
                self.artworkTask = nil
                self.pendingArtworkKey = nil
                var updated = self.state
                updated.thumbnail = thumbnail ?? SceneMediaState.Thumbnail()
                self.publish(updated)
            }
        }
    }

    private func cancelArtwork() {
        artworkRequest += 1
        artworkTask?.cancel()
        artworkTask = nil
        pendingArtworkKey = nil
    }

    private func publish(_ next: SceneMediaState) {
        guard next != state else { return }
        state = next
        onUpdate?(next)
    }

    /// Decode and network reads stay off the main/render actor. The ephemeral
    /// session has no stored cookies or credentials, and response size is bounded.
    @concurrent
    private static func loadArtwork(_ payload: MediaArtworkPayload) async -> SceneMediaState.Thumbnail? {
        switch payload {
        case .unchanged, .absent: return nil
        case .embedded(let data): return MediaArtworkDecoder.decode(data)
        case .music(let processID, let trackKey):
            guard !Task.isCancelled,
                  let data = await AppleEventMediaPlayerReader.musicArtwork(processID: processID, trackKey: trackKey),
                  !Task.isCancelled else { return nil }
            return MediaArtworkDecoder.decode(data)
        case .remote(let url):
            guard MediaArtworkURLPolicy.allows(url) else { return nil }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 10
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            let session = URLSession(configuration: config, delegate: MediaArtworkURLPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let (bytes, response) = try await session.bytes(from: url)
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                      MediaArtworkURLPolicy.allows(response.url),
                      response.expectedContentLength <= MediaArtworkDecoder.maximumInputBytes else { return nil }
                var data = Data()
                for try await byte in bytes {
                    guard !Task.isCancelled, data.count < MediaArtworkDecoder.maximumInputBytes else { return nil }
                    data.append(byte)
                }
                return MediaArtworkDecoder.decode(data)
            } catch { return nil }
        }
    }
}
