import Foundation
import Testing
@testable import WallpaperEngine

struct PlaybackSettingsTests {
    @Test func capabilitiesMatchWhatEachRendererHonours() {
        #expect(PlaybackSettings.Capabilities(type: .video) == .init(volume: true, rate: true, scaling: true))
        #expect(PlaybackSettings.Capabilities(type: .web) == .init(volume: true, rate: false, scaling: false))
        #expect(PlaybackSettings.Capabilities(type: .scene) == .init(volume: true, rate: false, scaling: false))
        #expect(PlaybackSettings.Capabilities(type: .application).isEmpty)
    }

    @Test func valuesAreClampedAndDefaultsAreNotStored() throws {
        let suite = "PlaybackSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var project = WallpaperProject(title: "T", type: .video, file: "a.mp4", preview: nil, description: nil, tags: nil)
        project.directoryURL = URL(fileURLWithPath: "/tmp/library/123")

        #expect(PlaybackSettings(volume: 3, rate: 0, scaling: .fit).clamped == PlaybackSettings(volume: 1, rate: 1, scaling: .fit))
        #expect(PlaybackSettings(volume: -1, rate: 9).clamped == PlaybackSettings(volume: 0, rate: 2))

        PlaybackSettings(volume: 0.3, rate: 1.5, scaling: .stretch).save(for: project, defaults: defaults)
        project.directoryURL = URL(fileURLWithPath: "/elsewhere/123") // copies share settings
        #expect(PlaybackSettings.load(for: project, defaults: defaults) == PlaybackSettings(volume: 0.3, rate: 1.5, scaling: .stretch))

        PlaybackSettings().save(for: project, defaults: defaults)
        #expect(defaults.object(forKey: PlaybackSettings.storageKey(for: project)) == nil)
        #expect(PlaybackSettings.load(for: project, defaults: defaults) == PlaybackSettings())
    }
}
