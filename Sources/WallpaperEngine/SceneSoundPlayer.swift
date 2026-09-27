import AVFoundation
import Foundation
import NativeSceneCore
import NativeSceneRuntime

/// Narrow seam for transport tests. The production factory wraps `AVAudioPlayer`.
@MainActor
protocol SceneSoundPlayback: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

@MainActor
private final class AVSoundPlayback: SceneSoundPlayback {
    let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
    var isPlaying: Bool { player.isPlaying }
    var currentTime: TimeInterval { get { player.currentTime } set { player.currentTime = newValue } }
    var volume: Float { get { player.volume } set { player.volume = newValue } }
    func prepareToPlay() -> Bool { player.prepareToPlay() }
    @discardableResult func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
}

@MainActor
struct SceneSoundTrackSpec {
    let nodeID: NodeID
    let trackID: Int
    let loops: Bool
    let source: URL?
}

@MainActor
struct SceneSoundDecodedAsset {
    let url: URL
    let byteCount: Int
}

/// App-owned realization of the runtime's per-layer logical transport. The
/// renderer gate suspends physical output only; suspension is not completion.
@MainActor
final class SceneSoundPlayer {
    typealias PlayerFactory = @MainActor (URL, Bool) throws -> any SceneSoundPlayback
    typealias Decoder = @MainActor (URL, Int, Int) throws -> SceneSoundDecodedAsset

    private enum PlaybackState { case idle, playing, paused, completed }
    private final class Track {
        let spec: SceneSoundTrackSpec
        var player: (any SceneSoundPlayback)?
        var temporaryURL: URL?
        var retainedBytes = 0
        var physicalRunID: UInt64?
        var state: PlaybackState = .idle
        var gatePaused = false
        var unavailable = false
        init(_ spec: SceneSoundTrackSpec) { self.spec = spec }
    }

    private var tracks: [NodeID: [Track]] = [:]
    private var latest: [NodeID: FrameSoundTransport] = [:]
    private var terminal: [(NodeID, UInt64, Bool)] = []
    private var deliveredTerminal: [NodeID: (runID: UInt64, finished: Bool)] = [:]
    private let fileManager: FileManager
    private let playerFactory: PlayerFactory
    private let decoder: Decoder
    /// Conversion caps are intentional compatibility limits for compressed
    /// fallback assets, and bound retained temporary PCM per player session.
    private let perAssetCAFBytes: Int
    private let aggregateCAFBytes: Int
    private var retainedCAFBytes = 0

    convenience init(scene: SceneDescription, assetRoots: [URL]) {
        self.init(trackSpecs: Self.trackSpecs(scene: scene, assetRoots: assetRoots))
    }

    private static func trackSpecs(scene: SceneDescription, assetRoots: [URL]) -> [SceneSoundTrackSpec] {
        scene.nodes.compactMap { node -> [SceneSoundTrackSpec]? in
            guard let sound = node.sound else { return nil }
            let mode = (sound.playbackMode ?? "loop").lowercased()
            let loops = mode != "single" && mode != "onetime" && mode != "once"
            return sound.sounds.enumerated().map { index, path in
                SceneSoundTrackSpec(nodeID: node.id, trackID: index, loops: loops,
                                    source: Self.resolve(path, roots: assetRoots))
            }
        }.flatMap { $0 }
    }

    func updateScene(_ scene: SceneDescription, assetRoots: [URL]) {
        updateTracks(Self.trackSpecs(scene: scene, assetRoots: assetRoots))
    }

    /// Preserve live players for unchanged nodes. Deleted/reconfigured layers
    /// release their players and temporary PCM before any new output is opened.
    func updateTracks(_ specs: [SceneSoundTrackSpec]) {
        let groups = Dictionary(grouping: specs, by: \.nodeID)
        for id in Array(tracks.keys) {
            let old = tracks[id] ?? [], next = groups[id] ?? []
            let same = old.count == next.count && zip(old, next).allSatisfy { track, spec in
                track.spec.trackID == spec.trackID && track.spec.loops == spec.loops && track.spec.source == spec.source
            }
            guard !same else { continue }
            for track in old { track.player?.stop(); removeTemporaryAsset(for: track) }
            tracks[id] = nil; latest[id] = nil; deliveredTerminal[id] = nil
            terminal.removeAll { $0.0 == id }
        }
        for (id, specs) in groups where tracks[id] == nil { tracks[id] = specs.map(Track.init) }
    }

    /// Internal initializer keeps tests independent of the audio service and decoder.
    init(trackSpecs: [SceneSoundTrackSpec], fileManager: FileManager = .default,
         perAssetCAFBytes: Int = 128 * 1024 * 1024, aggregateCAFBytes: Int = 256 * 1024 * 1024,
         playerFactory: @escaping PlayerFactory = SceneSoundPlayer.directPlayer,
         decoder: @escaping Decoder = SceneSoundPlayer.decodeToTemporaryCAF) {
        self.fileManager = fileManager
        self.perAssetCAFBytes = perAssetCAFBytes
        self.aggregateCAFBytes = aggregateCAFBytes
        self.playerFactory = playerFactory
        self.decoder = decoder
        for spec in trackSpecs { tracks[spec.nodeID, default: []].append(Track(spec)) }
    }

    var hasTracks: Bool { !tracks.isEmpty }

    func reconcile(_ transports: [FrameSoundTransport], outputEnabled: Bool, masterVolume: Float = 1) {
        for transport in transports { latest[transport.nodeID] = transport }
        guard outputEnabled else {
            // A finite player may already have ended in the interval before a
            // mute/occlusion callback. Observe that terminal state before pause
            // so a later gate reopen cannot restart the completed run.
            for nodeTracks in tracks.values { for track in nodeTracks where track.state == .playing {
                if track.gatePaused {
                    continue
                } else if !track.spec.loops, let player = track.player, !player.isPlaying {
                    track.state = .completed
                } else {
                    track.player?.pause(); track.gatePaused = true
                }
            }}
            for transport in latest.values where transport.state == .playing {
                if let nodeTracks = tracks[transport.nodeID] {
                    reportCompletion(nodeTracks, transport: transport)
                }
            }
            return
        }

        for transport in latest.values {
            guard let nodeTracks = tracks[transport.nodeID] else {
                if transport.state == .playing { reportOnce(transport.nodeID, transport.runID, false) }
                continue
            }
            reconcile(nodeTracks, transport: transport, masterVolume: masterVolume)
        }
    }

    func drainTerminalStatuses() -> [(NodeID, UInt64, Bool)] {
        defer { terminal.removeAll() }
        return terminal
    }

    func dispose() {
        for nodeTracks in tracks.values { for track in nodeTracks {
            track.player?.stop()
            removeTemporaryAsset(for: track)
        }}
        tracks.removeAll(); latest.removeAll(); terminal.removeAll(); deliveredTerminal.removeAll(); retainedCAFBytes = 0
    }

    private func reconcile(_ nodeTracks: [Track], transport: FrameSoundTransport, masterVolume: Float) {
        for track in nodeTracks where track.physicalRunID != transport.runID {
            track.player?.stop(); track.player?.currentTime = 0
            track.physicalRunID = transport.runID
            track.state = .idle; track.gatePaused = false
            deliveredTerminal[transport.nodeID] = nil
        }

        // Observe an end that preceded a pause command before changing the
        // physical state. Otherwise pause/resume can restart a finished clip.
        for track in nodeTracks where !track.spec.loops && track.state == .playing && !track.gatePaused {
            if let player = track.player, !player.isPlaying { track.state = .completed }
        }

        switch transport.state {
        case .paused:
            for track in nodeTracks where track.state == .playing { track.player?.pause(); track.state = .paused; track.gatePaused = false }
            return
        case .stopped:
            for track in nodeTracks { track.player?.stop(); track.player?.currentTime = 0; track.state = .idle; track.gatePaused = false }
            return
        case .failed:
            return
        case .playing:
            break
        }

        let gain = max(0, min(1, transport.gain * masterVolume))
        var viable = 0
        for track in nodeTracks where !track.unavailable {
            if track.state == .completed { viable += 1; continue }
            guard let player = player(for: track) else { continue }
            player.volume = gain
            viable += 1
            if track.state == .idle || track.state == .paused || track.gatePaused {
                track.gatePaused = false
                guard player.play() else { markUnavailable(track, reason: "player rejected play request"); viable -= 1; continue }
                track.state = .playing
            }
        }

        if viable == 0 { reportOnce(transport.nodeID, transport.runID, false); return }
        reportCompletion(nodeTracks, transport: transport)
    }

    private func reportCompletion(_ nodeTracks: [Track], transport: FrameSoundTransport) {
        // A looping track has no terminal completion for its run. Finite layers
        // complete only when every viable sibling finished this same run. A
        // newer logical run may be waiting behind the closed output gate.
        let viable = nodeTracks.filter { !$0.unavailable }
        if !viable.isEmpty, viable.allSatisfy({ !$0.spec.loops && $0.state == .completed && $0.physicalRunID == transport.runID }) {
            reportOnce(transport.nodeID, transport.runID, true)
        }
    }

    private func player(for track: Track) -> (any SceneSoundPlayback)? {
        if let player = track.player { return player }
        guard !track.unavailable else { return nil }
        guard let source = track.spec.source else {
            markUnavailable(track, reason: "asset is absent from configured roots")
            return nil
        }
        var directReason = "direct player preparation failed"
        do {
            let direct = try playerFactory(source, track.spec.loops)
            if direct.prepareToPlay() { track.player = direct; return direct }
        } catch { directReason = "direct player failed: \(error.localizedDescription)" }

        do {
            let available = aggregateCAFBytes - retainedCAFBytes
            guard available >= 0 else {
                markUnavailable(track, reason: "aggregate PCM cap exhausted")
                return nil
            }
            let decoded = try decoder(source, perAssetCAFBytes, available)
            guard decoded.byteCount > 0, decoded.byteCount <= perAssetCAFBytes,
                  decoded.byteCount <= available else {
                try? fileManager.removeItem(at: decoded.url)
                markUnavailable(track, reason: "decoded PCM exceeds configured cap")
                return nil
            }
            do {
                let fallback = try playerFactory(decoded.url, track.spec.loops)
                guard fallback.prepareToPlay() else {
                    try? fileManager.removeItem(at: decoded.url)
                    markUnavailable(track, reason: "\(directReason); PCM fallback preparation failed")
                    return nil
                }
                track.temporaryURL = decoded.url; track.retainedBytes = decoded.byteCount; retainedCAFBytes += decoded.byteCount
                track.player = fallback
                return fallback
            } catch {
                try? fileManager.removeItem(at: decoded.url)
                markUnavailable(track, reason: "\(directReason); PCM fallback failed: \(error.localizedDescription)")
                return nil
            }
        } catch {
            markUnavailable(track, reason: "\(directReason); PCM decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func markUnavailable(_ track: Track, reason: String) {
        guard !track.unavailable else { return }
        track.unavailable = true
        let source = track.spec.source?.path ?? "<missing>"
        print("[SceneSoundPlayer] Sound node \(track.spec.nodeID.rawValue) track \(track.spec.trackID) unavailable (\(source)): \(reason)")
    }

    private func removeTemporaryAsset(for track: Track) {
        if let url = track.temporaryURL { try? fileManager.removeItem(at: url) }
        retainedCAFBytes = max(0, retainedCAFBytes - track.retainedBytes)
        track.temporaryURL = nil; track.retainedBytes = 0
    }

    private func reportOnce(_ nodeID: NodeID, _ runID: UInt64, _ finished: Bool) {
        if let previous = deliveredTerminal[nodeID], previous.runID == runID, previous.finished == finished { return }
        deliveredTerminal[nodeID] = (runID, finished)
        terminal.append((nodeID, runID, finished))
    }

    private static func directPlayer(_ source: URL, _ loops: Bool) throws -> any SceneSoundPlayback {
        let player = try AVAudioPlayer(contentsOf: source)
        player.numberOfLoops = loops ? -1 : 0
        return AVSoundPlayback(player)
    }

    /// Decodes only after direct preparation fails. The writer is released before
    /// the CAF is reopened, and every failed path removes its partial output.
    private static func decodeToTemporaryCAF(_ sourceURL: URL, _ perAssetLimit: Int, _ aggregateAvailable: Int) throws -> SceneSoundDecodedAsset {
        let input = try AVAudioFile(forReading: sourceURL)
        // Read into the decoder's actual processing format. The CAF itself is
        // explicitly interleaved float PCM, so file byte accounting remains
        // stable even when AVAudioFile supplies noninterleaved input buffers.
        let bufferFormat = input.processingFormat
        let channels = Int64(bufferFormat.channelCount)
        let (bytesPerFrame, frameOverflow) = channels.multipliedReportingOverflow(by: 4)
        let (estimated, overflow) = input.length.multipliedReportingOverflow(by: bytesPerFrame)
        guard !frameOverflow, !overflow, estimated > 0, estimated <= Int64(perAssetLimit), estimated <= Int64(aggregateAvailable) else {
            throw NSError(domain: "SceneSoundPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decoded sound exceeds PCM cap"])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("we-sound-\(UUID().uuidString).caf")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        do {
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: bufferFormat.sampleRate,
                AVNumberOfChannelsKey: Int(bufferFormat.channelCount),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            // The file layout and buffer processing format are independent.
            // AVAudioFile interleaves on write; matching its client format to
            // the decoder lets a single bounded buffer carry every frame.
            let output = try AVAudioFile(forWriting: url, settings: fileSettings,
                                         commonFormat: bufferFormat.commonFormat,
                                         interleaved: bufferFormat.isInterleaved)
            let capacity: AVAudioFrameCount = 16_384
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: capacity) else {
                throw NSError(domain: "SceneSoundPlayer", code: 3)
            }
            while input.framePosition < input.length {
                try input.read(into: inputBuffer, frameCount: capacity)
                if inputBuffer.frameLength == 0 { break }
                try output.write(from: inputBuffer)
            }
        } // close output before constructing AVAudioPlayer
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 0, bytes <= perAssetLimit, bytes <= aggregateAvailable else { throw NSError(domain: "SceneSoundPlayer", code: 3) }
        completed = true
        return SceneSoundDecodedAsset(url: url, byteCount: bytes)
    }

    private static func resolve(_ relativePath: String, roots: [URL]) -> URL? {
        for root in roots {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
