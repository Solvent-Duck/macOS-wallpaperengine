import AppKit
import CoreServices
import Foundation
import NativeSceneRuntime
import Synchronization

/// Supported public scripting interfaces. Reading never launches or controls a player.
enum MediaPlayer: String, CaseIterable, Sendable {
    case music, spotify

    var name: String { self == .music ? "Music" : "Spotify" }
    var bundleIdentifier: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
}

enum MediaArtworkPayload: Sendable {
    case unchanged, absent, embedded(Data), remote(URL)
    case music(processID: Int32, trackKey: String)
}

struct MediaPlayerSample: Sendable {
    var state: SceneMediaState
    let trackKey: String
    var artwork: MediaArtworkPayload
}

enum MediaPlayerReadResult: Sendable {
    case sample(MediaPlayerSample)
    case permissionRequired
    case permissionDenied
    case unavailable
    case failed(Int)
}

protocol MediaPlayerReading: Sendable {
    func read(player: MediaPlayer, processID: Int32, previousTrackKey: String?, refreshArtwork: Bool) async -> MediaPlayerReadResult
    func requestPermission(processID: Int32) async -> Int32
}

/// Apple events run on one dedicated queue, away from rendering and the main actor.
/// PID addressing cannot implicitly start a stopped app. Every ordinary event also
/// explicitly forbids permission prompts; only the user-facing Connect action asks.
final class AppleEventMediaPlayerReader: MediaPlayerReading, Sendable {
    private let queue = DispatchQueue(label: "com.wallpaperengine.media-player", qos: .utility)
    private static let artworkQueue = DispatchQueue(label: "com.wallpaperengine.media-artwork", qos: .utility)

    func read(player: MediaPlayer, processID: Int32, previousTrackKey: String?, refreshArtwork: Bool) async -> MediaPlayerReadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.readNow(player: player, processID: processID,
                    previousTrackKey: previousTrackKey, refreshArtwork: refreshArtwork))
            }
        }
    }

    func requestPermission(processID: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(processIdentifier: processID)
                guard let descriptor = target.aeDesc else {
                    continuation.resume(returning: Int32(paramErr)); return
                }
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(
                    descriptor, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true))
            }
        }
    }

    private static func readNow(player: MediaPlayer, processID: Int32, previousTrackKey: String?, refreshArtwork: Bool) -> MediaPlayerReadResult {
        let target = NSAppleEventDescriptor(processIdentifier: processID)
        guard let descriptor = target.aeDesc else { return .unavailable }
        let permission = AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), false)
        if permission == errAEEventWouldRequireUserConsent { return .permissionRequired }
        if permission == errAEEventNotPermitted { return .permissionDenied }
        guard permission == noErr else { return permission == procNotFound ? .unavailable : .failed(Int(permission)) }

        do {
            guard let sample = try readSample(player: player, processID: processID,
                previousTrackKey: previousTrackKey, refreshArtwork: refreshArtwork,
                fetch: { try get($0, from: target) }) else { return .unavailable }
            return .sample(sample)
        } catch {
            let number = (error as NSError).code
            if number == Int(errAEEventNotPermitted) { return .permissionDenied }
            if number == Int(errAEEventWouldRequireUserConsent) { return .permissionRequired }
            return .failed(number)
        }
    }

    /// Synchronous descriptor parsing is shared by the queue and deterministic
    /// transport tests. Artwork bytes are requested only after source selection.
    static func readSample(player: MediaPlayer, processID: Int32, previousTrackKey: String?, refreshArtwork: Bool,
                           fetch: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor) throws -> MediaPlayerSample? {
        let playback = try fetch(property("pPlS")).enumCodeValue
        var state = SceneMediaState()
        state.enabled = true
        switch playback {
        case code("kPSP"), code("kPSF"), code("kPSR"): state.playback = .playing
        case code("kPSp"): state.playback = .paused
        default: state.playback = .stopped
        }
        guard state.playback != .stopped else {
            return MediaPlayerSample(state: state, trackKey: "", artwork: .absent)
        }
        let track = property("pTrk")
        let properties = try fetch(property("pALL", container: track))
        state.properties.title = string(properties, "pnam")
        state.properties.artist = string(properties, "pArt")
        state.properties.albumTitle = string(properties, "pAlb")
        state.properties.albumArtist = string(properties, "pAlA")
        state.properties.genres = string(properties, "pGen")
        state.properties.contentType = "music"
        let duration = properties.forKeyword(code("pDur"))?.doubleValue ?? 0
        // Spotify's scripting dictionary says seconds but its implementation
        // returns milliseconds; player position is in seconds for both apps.
        state.duration = finiteSeconds(player == .spotify ? duration / 1_000 : duration)
        state.position = finiteSeconds(try fetch(property("pPos")).doubleValue)
        if state.duration > 0 { state.position = min(state.position, state.duration) }
        let trackKey = key(for: properties, player: player)
        var artwork = MediaArtworkPayload.unchanged
        if refreshArtwork || trackKey != previousTrackKey {
            if player == .spotify {
                let url = string(properties, "aUrl")
                if let remote = URL(string: url), MediaArtworkURLPolicy.allows(remote) {
                    artwork = .remote(remote)
                } else { artwork = .absent }
            } else {
                // The inactive player is polled for metadata only. The chosen
                // source's larger artwork read uses a separate utility queue.
                artwork = .music(processID: processID, trackKey: trackKey)
            }
        }
        // A track can change between the individual get events. Discard a
        // mixed snapshot instead of publishing artwork for the wrong title.
        let current = try fetch(property("pALL", container: track))
        guard key(for: current, player: player) == trackKey else { return nil }
        return MediaPlayerSample(state: state, trackKey: trackKey, artwork: artwork)
    }

    static func musicArtwork(processID: Int32, trackKey: String) async -> Data? {
        await performArtworkRead(on: artworkQueue) { isCancelled in
            // A process may exit while its artwork is queued. Never send a
            // reused PID's events to a different application.
            guard NSRunningApplication(processIdentifier: processID)?.bundleIdentifier == MediaPlayer.music.bundleIdentifier else { return nil }
            let target = NSAppleEventDescriptor(processIdentifier: processID)
            return try? readMusicArtwork(trackKey: trackKey, isCancelled: isCancelled,
                fetch: { try get($0, from: target) })
        }
    }

    /// Cancelled queued requests are discarded before sending events. An event
    /// already in flight retains its two-second timeout; cancellation is checked
    /// again before the next event or descriptor copy.
    static func performArtworkRead(on queue: DispatchQueue,
        read: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) -> Data?) async -> Data? {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancelled.withLock({ $0 }) else { continuation.resume(returning: nil); return }
                    let result = read { cancelled.withLock { $0 } }
                    continuation.resume(returning: cancelled.withLock { $0 } ? nil : result)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    static func readMusicArtwork(trackKey: String,
                                 isCancelled: () -> Bool = { false },
                                 fetch: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor) throws -> Data? {
        let track = property("pTrk")
        guard !isCancelled(),
              key(for: try fetch(property("pALL", container: track)), player: .music) == trackKey,
              !isCancelled() else { return nil }
        let artwork = try fetch(property("pRaw", container: element("cArt", index: 1, container: track)))
        // Apple Events already owns the reply buffer. Bound the additional Data
        // copy and ImageIO input before materializing descriptor.data.
        guard !isCancelled(), let descriptor = artwork.aeDesc else { return nil }
        let size = AEGetDescDataSize(descriptor)
        guard size > 0, size <= MediaArtworkDecoder.maximumInputBytes,
              key(for: try fetch(property("pALL", container: track)), player: .music) == trackKey,
              !isCancelled() else { return nil }
        return artwork.data
    }

    private static func key(for properties: NSAppleEventDescriptor, player: MediaPlayer) -> String {
        player.rawValue + ":" + [string(properties, player == .music ? "pPIS" : "ID  "),
            string(properties, "pnam"), string(properties, "pArt"), string(properties, "pAlb")].joined(separator: "\u{1f}")
    }

    // The four-character property codes are from the installed Music/Spotify sdefs.
    static func code(_ string: String) -> OSType {
        precondition(string.utf8.count == 4)
        return string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    static func property(_ name: String, container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(desiredClass: code("prop"), form: code("prop"), key: NSAppleEventDescriptor(typeCode: code(name)), container: container)
    }

    private static func element(_ name: String, index: Int32, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(desiredClass: code(name), form: code("indx"), key: NSAppleEventDescriptor(int32: index), container: container)
    }

    private static func specifier(desiredClass: OSType, form: OSType, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: desiredClass), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    private static func get(_ object: NSAppleEventDescriptor, from target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        let noPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, noPrompt], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let value = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAEDescNotFound))
        }
        return value
    }

    private static func string(_ record: NSAppleEventDescriptor, _ name: String) -> String {
        String((record.forKeyword(code(name))?.stringValue ?? "").prefix(4_096))
    }

    private static func finiteSeconds(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}
