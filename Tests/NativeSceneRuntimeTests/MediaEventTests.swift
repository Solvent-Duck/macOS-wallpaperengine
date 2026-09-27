import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct MediaEventTests {
    @Test func playbackConstantsAreAvailableDuringModuleInitialization() throws {
        let host = ScriptHost()
        let source = """
        const stopped = MediaPlaybackEvent.PLAYBACK_STOPPED;
        const playing = MediaPlaybackEvent.PLAYBACK_PLAYING;
        const paused = MediaPlaybackEvent.PLAYBACK_PAUSED;
        export function update() { return new Vec3(stopped, playing, paused); }
        """
        #expect(try host.evaluate(source: source, baseValue: .vec3([9, 9, 9]), properties: [:]) == .vec3([0, 1, 2]))
    }

    @Test func unavailableMediaDeliversInitialEventsAfterInitializationOnlyOnce() throws {
        let host = ScriptHost()
        let source = """
        let events = [];
        export function init() { events.push('init'); }
        export function applyUserProperties() { events.push('properties'); }
        export function mediaStatusChanged(event) { events.push('status:' + event.enabled); }
        export function mediaPlaybackChanged(event) { events.push('playback:' + event.state); }
        export function update() { return events.join(','); }
        """
        for _ in 0..<2 {
            #expect(try host.evaluate(source: source, baseValue: .string(""), properties: [:], userProperties: ["mode": .int(0)]) == .string("init,properties,status:false,playback:0"))
        }
    }

    @Test func trackPlaybackAndTimelineChangesDoNotRepeatUnchangedEvents() throws {
        let host = ScriptHost()
        var state = SceneMediaState()
        state.enabled = true
        state.playback = .playing
        state.properties.title = "A song"
        state.position = 3
        state.duration = 180
        let source = """
        let counts = [0, 0, 0, 0, 0], title, playback, position;
        export function mediaStatusChanged(e) { counts[0]++; }
        export function mediaPlaybackChanged(e) { counts[1]++; playback = e.state; }
        export function mediaPropertiesChanged(e) { counts[2]++; title = e.title; }
        export function mediaThumbnailChanged(e) { counts[3]++; }
        export function mediaTimelineChanged(e) { counts[4]++; position = e.position; }
        export function update() { return counts.join(',') + ':' + title + ':' + playback + ':' + position; }
        """
        func read() throws -> FrameValue {
            host.updateMediaState(state)
            return try host.evaluate(source: source, baseValue: .string(""), properties: [:])
        }
        #expect(try read() == .string("1,1,1,1,1:A song:1:3"))
        #expect(try read() == .string("1,1,1,1,1:A song:1:3"))
        state.position = 4
        #expect(try read() == .string("1,1,1,1,2:A song:1:4"))
        state.playback = .paused
        #expect(try read() == .string("1,2,1,1,2:A song:2:4"))
        state.properties.title = "Another song"
        #expect(try read() == .string("1,2,2,1,2:Another song:2:4"))
        state.thumbnail.identifier = "new artwork with the same palette"
        #expect(try read() == .string("1,2,2,2,2:Another song:2:4"))
    }

    @Test func disablingIntegrationClearsPreviousTrackAndThumbnailData() throws {
        let host = ScriptHost()
        var state = SceneMediaState()
        state.enabled = true
        state.playback = .playing
        state.properties.title = "Old title"
        state.thumbnail.hasThumbnail = true
        state.position = 42
        let source = """
        let enabled, playback, title, thumbnail, position;
        export function mediaStatusChanged(e) { enabled = e.enabled; }
        export function mediaPlaybackChanged(e) { playback = e.state; }
        export function mediaPropertiesChanged(e) { title = e.title; }
        export function mediaThumbnailChanged(e) { thumbnail = e.hasThumbnail; }
        export function mediaTimelineChanged(e) { position = e.position; }
        export function update() { return [enabled, playback, title, thumbnail, position].join('|'); }
        """
        host.updateMediaState(state)
        #expect(try host.evaluate(source: source, baseValue: .string(""), properties: [:]) == .string("true|1|Old title|true|42"))
        state.enabled = false
        host.updateMediaState(state)
        #expect(try host.evaluate(source: source, baseValue: .string(""), properties: [:]) == .string("false|0||false|0"))
    }

    @Test func thumbnailColorsAreVectorsAndMutableEventsCannotPoisonOtherModules() throws {
        let host = ScriptHost()
        var state = SceneMediaState()
        state.enabled = true
        state.properties.title = "Untouched"
        state.thumbnail.hasThumbnail = true
        state.thumbnail.primaryColor = RuntimeVector3(x: 0.25, y: 0.5, z: 0.75)
        host.updateMediaState(state)
        _ = try host.evaluate(source: """
        export function mediaPropertiesChanged(e) { e.title = 'poisoned'; }
        export function mediaThumbnailChanged(e) { e.primaryColor.x = 99; e.textColor.y = 99; }
        """, baseValue: .int(0), properties: [:], instanceID: "mutator")
        let source = """
        let color, title;
        export function mediaPropertiesChanged(e) { title = e.title; }
        export function mediaThumbnailChanged(e) {
            if (!(e instanceof MediaThumbnailEvent) || !(e.primaryColor instanceof Vec3) || !(e.textColor instanceof Vec3)) throw new Error('event types');
            color = e.primaryColor.copy().add(e.textColor).subtract(new Vec3(1));
        }
        export function update() { return title === 'Untouched' ? color : new Vec3(-1); }
        """
        #expect(try host.evaluate(source: source, baseValue: .vec3([0, 0, 0]), properties: [:], instanceID: "late-reader") == .vec3([0.25, 0.5, 0.75]))
    }

    @Test func mediaCallbacksUseTheirOwnLayersAndWorkWhileTheSceneIsPaused() throws {
        let runtime = SceneRuntime(scene: try fixture([
            ["id": 1, "name": "Title", "text": ["value": "placeholder", "script": """
            export function mediaPropertiesChanged(e) { thisLayer.text = e.title; }
            """]],
            ["id": 2, "name": "Visibility", "image": "missing.json", "visible": ["value": true, "script": """
            export function mediaPlaybackChanged(e) { thisLayer.visible = e.state !== MediaPlaybackEvent.PLAYBACK_STOPPED; }
            """]],
        ]))
        let initial = runtime.step(deltaTime: 0)
        #expect(initial.texts.first?.content == "")
        #expect(initial.nodes[1].visible == false)
        runtime.setPaused(true)
        var state = SceneMediaState()
        state.enabled = true
        state.playback = .playing
        state.properties.title = "Live title"
        runtime.updateMediaState(state)
        let changed = runtime.step(deltaTime: 10)
        #expect(changed.texts.first?.content == "Live title")
        #expect(changed.nodes[1].visible == true)
        #expect(runtime.elapsedTime == 0)
        state.playback = .paused
        runtime.updateMediaState(state)
        #expect(runtime.step(deltaTime: 10).nodes[1].visible == true)
        state.playback = .stopped
        runtime.updateMediaState(state)
        #expect(runtime.step(deltaTime: 10).nodes[1].visible == false)
    }

    @Test func mediaChangesInvalidateRepeatedFrameReadsWithoutUpdatingTwice() throws {
        let host = ScriptHost()
        var state = SceneMediaState()
        let source = """
        let updates = 0;
        export function mediaPlaybackChanged(e) { shared.latestPlayback = e.state; }
        export function update() { return ++updates; }
        """
        let engine = SceneScriptEngineState(runtime: 0, screenResolution: .zero, frameIndex: 0)
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine) == .int(1))
        state.enabled = true
        state.playback = .playing
        host.updateMediaState(state)
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine) == .int(1))
        #expect(try host.evaluate(source: "export function update() { return shared.latestPlayback; }", baseValue: .int(-1), properties: [:]) == .int(1))
    }

    @Test func standaloneCallbackModulesReceiveMediaEventsAndPreserveLifecycleOrder() throws {
        let host = ScriptHost()
        let source = """
        let ready = false;
        export function init() { ready = true; }
        export function mediaPlaybackChanged(e) {
            if (!ready || !(e instanceof MediaPlaybackEvent)) throw new Error('invalid initialization');
            thisObject.alpha = e.state;
        }
        """
        let engine = SceneScriptEngineState(runtime: 0, screenResolution: .zero)
        func call(_ callback: SceneScriptCallback) throws -> [String: FrameValue] {
            try host.executeSceneCallback(source: source, callback: callback,
                thisObject: ["alpha": .double(-1)], changedUserProperties: [:], engine: engine,
                input: SceneScriptInputState(cursorPosition: nil))
        }
        #expect(try call(.initialize)["alpha"] == .int(0))
        var state = SceneMediaState()
        state.enabled = true
        state.playback = .paused
        host.updateMediaState(state)
        #expect(try call(.applyUserProperties)["alpha"] == .int(2))
    }

    @Test func invalidPlatformNumbersCannotBreakScriptSerialization() throws {
        let host = ScriptHost()
        var state = SceneMediaState()
        state.enabled = true
        state.position = .nan
        state.duration = -.infinity
        state.thumbnail.primaryColor = RuntimeVector3(x: .nan, y: -1, z: 2)
        host.updateMediaState(state)
        let source = """
        let value;
        export function mediaTimelineChanged(e) { shared.time = e.position + e.duration; }
        export function mediaThumbnailChanged(e) { value = e.primaryColor; }
        export function update() { return value.add(new Vec3(shared.time)); }
        """
        #expect(try host.evaluate(source: source, baseValue: .vec3([9, 9, 9]), properties: [:]) == .vec3([0, 0, 1]))
    }

    @Test func failingMediaListenerDoesNotStarveLaterEventsOrUpdates() throws {
        let host = ScriptHost()
        let source = """
        let statusCalls = 0, playbackCalls = 0;
        export function mediaStatusChanged(e) { statusCalls++; throw new Error('authored listener failure'); }
        export function mediaPlaybackChanged(e) { playbackCalls++; }
        export function update() { return statusCalls * 10 + playbackCalls; }
        """
        #expect(throws: ScriptHostError.self) { try host.evaluate(source: source, baseValue: .int(0), properties: [:]) }
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(11))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(11))
    }

    private func fixture(_ nodes: [[String: Any]]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEMediaEvents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json"]).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": nodes]).write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }

}
