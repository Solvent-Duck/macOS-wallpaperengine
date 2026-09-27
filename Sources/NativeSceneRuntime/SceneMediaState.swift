import Foundation

/// Immutable straight-alpha RGBA8 artwork stored top-row first with no row padding.
public struct SceneMediaArtwork: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgba8: Data

    public init?(width: Int, height: Int, rgba8: Data) {
        guard (1...1024).contains(width), (1...1024).contains(height) else {
            return nil
        }
        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow else {
            return nil
        }
        let (byteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteCountOverflow, rgba8.count == byteCount else {
            return nil
        }

        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }
}

/// Latest media information supplied by the platform. An unavailable source is
/// explicit, so wallpapers do not mistake a missing integration for playback.
public struct SceneMediaState: Equatable, Sendable {
    public enum Playback: Int, Sendable { case stopped = 0, playing = 1, paused = 2 }

    public struct Properties: Equatable, Sendable {
        public var title = ""
        public var artist = ""
        public var subTitle = ""
        public var albumTitle = ""
        public var albumArtist = ""
        public var genres = ""
        public var contentType = ""
        public init() {}
    }

    public struct Thumbnail: Equatable, Sendable {
        /// Changes when the artwork changes, even if its extracted colors match.
        public var identifier = ""
        public var hasThumbnail = false
        public var artwork: SceneMediaArtwork? = nil
        public var primaryColor = RuntimeVector3.zero
        public var secondaryColor = RuntimeVector3.zero
        public var tertiaryColor = RuntimeVector3.zero
        public var textColor = RuntimeVector3.one
        public var highContrastColor = RuntimeVector3.one
        public init() {}
    }

    public var enabled = false
    public var playback = Playback.stopped
    public var properties = Properties()
    public var thumbnail = Thumbnail()
    public var position: Double = 0
    public var duration: Double = 0
    public init() {}

    var scriptObject: [String: Any] {
        // Disabling integration clears stale track information for every script.
        let state = enabled ? self : SceneMediaState()
        func seconds(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        func color(_ value: RuntimeVector3) -> [String: Float] {
            func channel(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
            return ["x": channel(value.x), "y": channel(value.y), "z": channel(value.z)]
        }
        return [
            "mediaStatusChanged": ["enabled": enabled],
            "mediaPlaybackChanged": ["state": state.playback.rawValue],
            "mediaPropertiesChanged": [
                "title": state.properties.title, "artist": state.properties.artist,
                "subTitle": state.properties.subTitle, "albumTitle": state.properties.albumTitle,
                "albumArtist": state.properties.albumArtist, "genres": state.properties.genres,
                "contentType": state.properties.contentType,
            ],
            "mediaThumbnailChanged": [
                "hasThumbnail": state.thumbnail.hasThumbnail,
                "primaryColor": color(state.thumbnail.primaryColor),
                "secondaryColor": color(state.thumbnail.secondaryColor),
                "tertiaryColor": color(state.thumbnail.tertiaryColor),
                "textColor": color(state.thumbnail.textColor),
                "highContrastColor": color(state.thumbnail.highContrastColor),
            ],
            "thumbnailIdentifier": state.thumbnail.identifier,
            "mediaTimelineChanged": ["position": seconds(state.position), "duration": seconds(state.duration)],
        ]
    }
}
