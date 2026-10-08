import Foundation

/// How a video fills the screen.
enum VideoScaling: String, Codable, CaseIterable, Sendable {
    case fill, fit, stretch

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        }
    }
}

/// Per-wallpaper playback controls, separate from the wallpaper's own authored
/// properties (Wallpaper Engine's "general" settings).
struct PlaybackSettings: Codable, Equatable, Sendable {
    static let rates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    /// Output gain, 0–1. Mute is separate and global.
    var volume: Double = 1
    /// Video playback speed.
    var rate: Double = 1
    var scaling: VideoScaling = .fill

    /// Which controls a wallpaper type honours. Scene scaling waits on the
    /// scene aspect policy; controls are only shown where they do something.
    struct Capabilities: Equatable {
        var volume: Bool
        var rate: Bool
        var scaling: Bool

        init(volume: Bool, rate: Bool, scaling: Bool) {
            self.volume = volume
            self.rate = rate
            self.scaling = scaling
        }

        init(type: WallpaperType) {
            volume = type == .video || type == .web || type == .scene
            rate = type == .video
            scaling = type == .video
        }

        var isEmpty: Bool { !volume && !rate && !scaling }
    }

    // MARK: Persistence

    /// Keyed like saved properties: by wallpaper folder name.
    static func storageKey(for project: WallpaperProject) -> String {
        "WallpaperPlayback.\(project.directoryURL?.lastPathComponent ?? project.title)"
    }

    static func load(for project: WallpaperProject, defaults: UserDefaults = .standard) -> PlaybackSettings {
        guard let data = defaults.data(forKey: storageKey(for: project)),
              let settings = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else { return PlaybackSettings() }
        return settings.clamped
    }

    func save(for project: WallpaperProject, defaults: UserDefaults = .standard) {
        if self == PlaybackSettings() {
            defaults.removeObject(forKey: Self.storageKey(for: project))
        } else if let data = try? JSONEncoder().encode(clamped) {
            defaults.set(data, forKey: Self.storageKey(for: project))
        }
    }

    var clamped: PlaybackSettings {
        var copy = self
        copy.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        copy.rate = min(max(rate.isFinite && rate > 0 ? rate : 1, 0.25), 2)
        return copy
    }
}
