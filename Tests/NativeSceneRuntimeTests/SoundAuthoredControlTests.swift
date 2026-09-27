import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

/// Opt-in authored-control evidence, separate from synthetic transport and audio.
struct SoundAuthoredControlTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_SOUND_CORPUS_ROOT"] != nil))
    func authoredDayNightAndRainControlsSwitchSoundLayersAndLiveGain() throws {
        let corpus = try #require(ProcessInfo.processInfo.environment["WE_SOUND_CORPUS_ROOT"])
        let root = URL(fileURLWithPath: corpus).appendingPathComponent("3560755188")
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene)
        defer { runtime.shutdown() }
        let controlled = [1963, 1969, 712, 758, 713]
        let defaultGains: [Int: Float] = [1963: 0.5, 1969: 0.35, 1970: 0.3, 712: 0.5, 758: 0.2, 713: 0.1, 801: 0.433]
        let initial = runtime.step(deltaTime: 1.0 / 30)
        #expect(initial.soundTransports.count == 7)
        for (id, gain) in defaultGains {
            let sound = try #require(initial.soundTransports.first { $0.nodeID.rawValue == id })
            #expect(abs(sound.gain - gain) < 0.00001)
        }
        for id in controlled {
            let sound = try #require(initial.soundTransports.first { $0.nodeID.rawValue == id })
            #expect((sound.state == .playing) == [758, 713].contains(id))
        }
        let gains: [(Int, String, Double)] = [
            (1963, "newproperty", 0.23), (1969, "rain", 0.17), (1970, "shinrinyoku", 0.19),
            (712, "cricketssounds", 0.31), (758, "cricketssoundsday", 0.29),
            (713, "birdssounds", 0.13), (801, "emptyroomambientnoise", 0.11),
        ]
        for (mode, active) in [(1, [712]), (3, [1963, 1969]), (0, [758, 713])] {
            var overrides = Dictionary(uniqueKeysWithValues: gains.map { ($0.1, FrameValue.double($0.2)) })
            overrides["daynight"] = .int(mode)
            let packet = runtime.step(deltaTime: 1.0 / 30, propertyOverrides: overrides)
            for id in controlled {
                let sound = try #require(packet.soundTransports.first { $0.nodeID.rawValue == id })
                #expect((sound.state == .playing) == active.contains(id))
            }
            for (id, _, gain) in gains {
                let sound = try #require(packet.soundTransports.first { $0.nodeID.rawValue == id })
                #expect(abs(sound.gain - Float(gain)) < 0.00001)
            }
        }
        print("[SoundAuthoredControlProbe] 3560755188: default Day, Night, Rain, Day and seven live gain bindings checked; logical runtime only")
    }
}
