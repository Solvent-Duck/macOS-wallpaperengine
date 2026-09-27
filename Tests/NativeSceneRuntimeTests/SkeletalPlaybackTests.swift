import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct SkeletalPlaybackTests {
    @Test func animationOwnedCallbacksKeepTheirLayerAndPropertyObject() throws {
        let root = try SkeletalAttachmentTests().fixture(reference: .name("头"), mode: "single", fps: 10, frameCount: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scene.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var objects = try #require(json["objects"] as? [[String: Any]])
        var animations = try #require(objects[2]["animationlayers"] as? [[String: Any]])
        animations[0]["visible"] = ["value": true, "script": """
        const animation = thisObject;
        export function init(value) {
            animation.addEndedCallback(() => {
                if (thisObject !== animation || thisLayer.name !== 'Puppet') throw new Error('wrong animation owner');
                thisObject.blend = 0.25;
                thisLayer.alpha = 0.5;
            });
            return value;
        }
        """]
        objects[2]["animationlayers"] = animations
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene, puppetModels: PuppetModelLibrary(assetRoots: [root]))
        _ = runtime.step(deltaTime: 0)
        let puppet = try #require(runtime.step(deltaTime: 2).nodes.first { $0.nodeID.rawValue == 9 })
        #expect(puppet.opacity == 0.5)
        #expect(puppet.animationLayers[0].blend == 0.25)
    }

    @Test func earlyAnimationInitCanUseALaterTopLevelModuleHelper() throws {
        let root = try SkeletalAttachmentTests().fixture(reference: .name("头"), mode: "single", fps: 10, frameCount: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scene.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var objects = try #require(json["objects"] as? [[String: Any]])
        var animations = try #require(objects[2]["animationlayers"] as? [[String: Any]])
        animations[0]["visible"] = ["value": true, "script": """
        export function init(value) {
            if (shared.providerInitRan !== undefined) throw new Error('provider init ran before consumer');
            const sentinel = shared.offsetedStartAni(thisObject, 0.25);
            if (!thisObject.isPlaying() || thisObject.getFrame() !== 5) throw new Error('animation helper failed');
            thisObject.blend = sentinel;
            return value;
        }
        """]
        objects[2]["animationlayers"] = animations
        objects.append(["id": 90, "visible": ["value": false, "script": """
        shared.offsetedStartAni = function(animation, percentage) {
            animation.play();
            animation.setFrame(animation.frameCount * percentage);
            return 0.625;
        };
        export function init(value) { shared.providerInitRan = true; return value; }
        """]])
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene, puppetModels: PuppetModelLibrary(assetRoots: [root]))
        let puppet = try #require(runtime.step(deltaTime: 0).nodes.first { $0.nodeID.rawValue == 9 })
        #expect(puppet.animationLayers[0].sampleFrame == 5)
        #expect(puppet.animationLayers[0].blend == 0.625)
    }

    @Test func shutdownRemovesOldRegistrationsAndPendingCallbackBacklogs() throws {
        let script = """
        export function init() {
            shared.count ||= 0;
            thisScene.getLayer('Puppet').getAnimationLayer(0).addEndedCallback(() => shared.count++);
        }
        export function update() { return new Vec3(shared.count, 0, 0); }
        """
        try withRuntime(mode: "loop", controller: script) { runtime, _, _ in
            _ = runtime.step(deltaTime: 0)
            #expect(runtime.step(deltaTime: 4100).nodes.last?.worldPosition.x == 1024)
            runtime.shutdown()
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition.x == 1024)
            #expect(runtime.step(deltaTime: 2).nodes.last?.worldPosition.x == 1025)
        }
    }

    @Test func largeEventBacklogsStayBoundedAndSurviveUntilTheNextFrame() throws {
        let script = """
        let ended = 0;
        export function init() {
            thisScene.getLayer('Puppet').getAnimationLayer(0).addEndedCallback(() => ended++);
        }
        export function update() { return new Vec3(ended, 0, 0); }
        """
        try withRuntime(mode: "loop", controller: script) { runtime, scene, library in
            _ = runtime.step(deltaTime: 0)
            #expect(runtime.step(deltaTime: 4100).nodes.last?.worldPosition.x == 1024)
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition.x == 2048)
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition.x == 2050)
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition.x == 2050)
            let independent = SceneRuntime(scene: scene, puppetModels: library)
            #expect(independent.step(deltaTime: 0).nodes.last?.worldPosition.x == 0)
        }
    }

    @Test func endedCallbacksRunForTheirRegisteringScriptAndCanRestartPlayback() throws {
        let script = """
        const animation = thisScene.getLayer('Puppet').getAnimationLayer(0);
        const owner = thisObject;
        let ended = 0;
        export function init() {
            animation.addEndedCallback(() => {
                if (thisObject !== owner || thisLayer !== owner || engine.frametime !== 2 ||
                    animation.isPlaying() || animation.getFrame() !== 20) throw new Error('wrong callback context or pose');
                ended++;
                if (ended === 1) animation.play();
            });
        }
        export function update() { return new Vec3(ended, animation.getFrame(), animation.isPlaying() ? 1 : 0); }
        """;
        try withRuntime(mode: "single", controller: script) { runtime, _, _ in
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition == RuntimeVector3(x: 0, y: 0, z: 1))
            #expect(runtime.step(deltaTime: 2).nodes.last?.worldPosition == RuntimeVector3(x: 1, y: 0, z: 1))
            #expect(runtime.step(deltaTime: 2).nodes.last?.worldPosition == RuntimeVector3(x: 2, y: 20, z: 0))
            #expect(runtime.step(deltaTime: 2).nodes.last?.worldPosition == RuntimeVector3(x: 2, y: 20, z: 0))
        }
    }

    @Test(arguments: ["loop", "mirror"])
    func repeatedEndsCountCrossingsIncludingLargeAndReverseSteps(mode: String) throws {
        let script = """
        const animation = thisScene.getLayer('Puppet').getAnimationLayer(0);
        let ended = 0;
        export function init() { animation.addEndedCallback(() => ended++); }
        export function update() { return new Vec3(ended, animation.getFrame(), 0); }
        """
        try withRuntime(mode: mode, controller: script) { runtime, _, _ in
            _ = runtime.step(deltaTime: 0)
            #expect(runtime.step(deltaTime: 2).nodes.last?.worldPosition.x == 1)
            // A mirror reaches its far endpoint once per out-and-back cycle.
            #expect(runtime.step(deltaTime: 8).nodes.last?.worldPosition.x == (mode == "loop" ? 5 : 3))
            #expect(runtime.step(deltaTime: 8, propertyOverrides: ["speed": .double(-1)]).nodes.last?.worldPosition.x == (mode == "loop" ? 9 : 5))
        }
    }

    @Test func seeksStopsAndPausesDoNotEmitEndedCallbacks() throws {
        let script = """
        const animation = thisScene.getLayer('Puppet').getAnimationLayer(0);
        let ended = 0;
        export function init() { animation.addEndedCallback(() => ended++); }
        export function update() {
            switch (engine.userProperties.command) {
            case 'end': animation.setFrame(20); animation.pause(); break;
            case 'stop': animation.stop(); break;
            case 'play': animation.play(); break;
            }
            return new Vec3(ended, animation.getFrame(), 0);
        }
        """
        try withRuntime(mode: "single", controller: script) { runtime, _, _ in
            _ = runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("end")])
            #expect(runtime.step(deltaTime: 10).nodes.last?.worldPosition.x == 0)
            _ = runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("stop")])
            #expect(runtime.step(deltaTime: 10).nodes.last?.worldPosition.x == 0)
            _ = runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("play")])
            runtime.setPaused(true)
            #expect(runtime.step(deltaTime: 10).nodes.last?.worldPosition.x == 0)
            runtime.setPaused(false)
            #expect(runtime.step(deltaTime: 2).nodes.last?.worldPosition.x == 1)
        }
    }

    @Test func callbackErrorsAndNewRegistrationsDoNotLoseOrRepeatQueuedEvents() throws {
        let script = """
        const animation = thisScene.getLayer('Puppet').getAnimationLayer(0);
        let first = 0, second = 0, late = 0;
        export function init() {
            animation.addEndedCallback(() => { first++; throw new Error('authored callback'); });
            animation.addEndedCallback(() => {
                second++;
                if (second === 1) animation.addEndedCallback(() => late++);
            });
        }
        export function update() { return new Vec3(first, second, late); }
        """
        try withRuntime(mode: "loop", controller: script) { runtime, _, _ in
            _ = runtime.step(deltaTime: 0)
            _ = runtime.step(deltaTime: 2)
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition == RuntimeVector3(x: 1, y: 1, z: 0))
            _ = runtime.step(deltaTime: 4)
            #expect(runtime.step(deltaTime: 0).nodes.last?.worldPosition == RuntimeVector3(x: 3, y: 3, z: 2))
        }
    }

    private let controller = """
    const animation = thisScene.getLayer('Puppet').getAnimationLayer('Move');
    export function init() {
        if (animation.fps !== 10 || animation.frameCount !== 20 || animation.duration !== 2 ||
            animation !== thisScene.getLayer('Puppet').getAnimationLayer(0)) throw new Error('wrong clip metadata');
    }
    export function update() {
        switch (engine.userProperties.command) {
        case 'pause': animation.pause(); break;
        case 'play': animation.play(); break;
        case 'stop': animation.stop(); break;
        case 'seek': animation.setFrame(15); break;
        case 'end': animation.setFrame(20); break;
        case 'double': animation.rate = 2; animation.play(); break;
        case 'reverse': animation.rate = -1; animation.play(); break;
        }
        return new Vec3(animation.getFrame(), animation.isPlaying() ? 1 : 0, animation.rate);
    }
    """

    @Test func singleShotControlsPreserveFrameAndDriveAttachments() throws {
        try withRuntime(mode: "single", controller: controller) { runtime, _, _ in
            func step(_ delta: Double, _ command: String = "") -> FramePacket {
                runtime.step(deltaTime: delta, propertyOverrides: ["command": .string(command)])
            }
            expect(step(0.5), frame: 5, playing: true)
            expect(step(0.5, "pause"), frame: 10, playing: false)
            expect(step(100), frame: 10, playing: false)
            expect(step(0, "seek"), frame: 15, playing: false)
            expect(step(0, "double"), frame: 15, playing: true)
            expect(step(0.25), frame: 20, playing: false)
            expect(step(10), frame: 20, playing: false)
            expect(step(0, "play"), frame: 0, playing: true)
            expect(step(0.25), frame: 5, playing: true)
            expect(step(0, "stop"), frame: 0, playing: false)
            expect(step(0, "reverse"), frame: 20, playing: true)
            expect(step(0.5), frame: 15, playing: true)
            expect(step(2), frame: 0, playing: false)
        }
    }

    @Test(arguments: ["loop", "mirror"])
    func wrappingReverseAndExactEndpointSeeking(mode: String) throws {
        try withRuntime(mode: mode, controller: controller) { runtime, _, _ in
            expect(runtime.step(deltaTime: 1.5), frame: 15, playing: true)
            expect(runtime.step(deltaTime: 1), frame: mode == "loop" ? 5 : 15, playing: true)
            expect(runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("reverse")]),
                   frame: mode == "loop" ? 5 : 15, playing: true)
            expect(runtime.step(deltaTime: 1), frame: 15, playing: true)
            expect(runtime.step(deltaTime: 0, propertyOverrides: ["command": .string("end")]), frame: 20, playing: true)
            expect(runtime.step(deltaTime: 0), frame: 20, playing: true)
            expect(runtime.step(deltaTime: 0.5), frame: 15, playing: true)
        }
    }

    @Test func userRateChangesAndGlobalPauseDoNotRescalePriorElapsedTime() throws {
        try withRuntime(mode: "loop", controller: controller) { runtime, _, _ in
            expect(runtime.step(deltaTime: 0.5), frame: 5, playing: true)
            expect(runtime.step(deltaTime: 0, propertyOverrides: ["speed": .double(2)]), frame: 5, playing: true)
            expect(runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(2)]), frame: 10, playing: true)
            runtime.setPaused(true)
            let paused = runtime.step(deltaTime: 100, propertyOverrides: ["speed": .double(-1)])
            #expect(sample(paused) == 10)
            runtime.setPaused(false)
            expect(runtime.step(deltaTime: 0.5, propertyOverrides: ["speed": .double(-1)]), frame: 5, playing: true)
            expect(runtime.step(deltaTime: 2, propertyOverrides: ["speed": .double(0)]), frame: 5, playing: true)
        }
    }

    @Test func layerAndSceneClocksRemainIndependentAndHiddenClipsKeepPlaying() throws {
        let script = """
        const first = thisScene.getLayer('Puppet').getAnimationLayer(0);
        const other = thisScene.getLayer('Puppet').getAnimationLayer(1);
        export function update() {
            if (engine.userProperties.command === 'pause') first.pause();
            return new Vec3(first.getFrame(), other.getFrame(), other.isPlaying() ? 1 : 0);
        }
        """
        try withRuntime(mode: "loop", controller: script, secondLayer: true) { first, scene, library in
            let second = SceneRuntime(scene: scene, puppetModels: library)
            let packet = first.step(deltaTime: 0.25, propertyOverrides: ["command": .string("pause")])
            #expect(packet.nodes.last?.worldPosition == RuntimeVector3(x: 2.5, y: 5, z: 1))
            let next = first.step(deltaTime: 0.25)
            #expect(next.nodes.last?.worldPosition == RuntimeVector3(x: 2.5, y: 10, z: 1))
            #expect(sample(second.step(deltaTime: 0.5)) == 5)
            let layers = next.nodes.first { $0.nodeID.rawValue == 9 }!.animationLayers
            #expect(layers[1].sampleFrame == 10)
            #expect(!layers[1].visible)
        }
    }

    @Test func decodedModesAndExplicitFramesAlsoControlSkinning() throws {
        try withRuntime(mode: "single") { _, _, library in
            let model = try #require(library.model(for: "puppet.mdl"))
            let clip = try #require(model.animations.first)
            #expect(clip.mode == .single)
            #expect(clip.frameCount == 20)
            #expect(clip.duration == 2)
            #expect(clip.poses(at: 10, rate: 1)[0].x == 9)
            #expect(clip.poses(atFrame: 15)[0].x == 8)
            let bones = model.boneTransforms(at: 100, animationID: 10, rate: 10, frame: 15)
            let skin = try #require(model.skinTransforms(at: 100, animationID: 10, rate: 10, frame: 15))
            #expect(bones[0].columns.3.x == 8)
            #expect(skin[0].columns.3.x == 3)
            #expect(model.deformedPositions(skins: skin)[0].x == 3)
        }
    }

    @Test func invalidSeeksAreIgnoredAndFiniteSeeksClamp() throws {
        let script = """
        const animation = thisScene.getLayer('Puppet').getAnimationLayer(0);
        export function update() {
            animation.pause(); animation.setFrame(15);
            animation.setFrame(NaN); animation.setFrame(Infinity); animation.setFrame('2');
            const held = animation.getFrame(); animation.setFrame(100); const end = animation.getFrame();
            animation.setFrame(-100); return new Vec3(held, end, animation.getFrame());
        }
        """
        try withRuntime(mode: "loop", controller: script) { runtime, _, _ in
            let frame = runtime.step(deltaTime: 0)
            #expect(frame.nodes.last?.worldPosition == RuntimeVector3(x: 15, y: 20, z: 0))
            #expect(sample(frame) == 0)
            let restored = try JSONDecoder().decode(FramePacket.self, from: JSONEncoder().encode(frame))
            #expect(restored == frame)
        }
    }

    private func sample(_ packet: FramePacket) -> Double? {
        packet.nodes.first { $0.nodeID.rawValue == 9 }?.animationLayers.first?.sampleFrame
    }

    private func expect(_ packet: FramePacket, frame: Double, playing: Bool) {
        #expect(sample(packet) == frame)
        #expect(packet.nodes.last?.worldPosition.x == Float(frame))
        #expect(packet.nodes.last?.worldPosition.y == (playing ? 1 : 0))
        #expect(abs(packet.nodes[0].worldPosition.y - Float(40 + frame * 0.4)) < 0.0001)
    }

    private func withRuntime(mode: String, controller: String? = nil, secondLayer: Bool = false,
                             _ body: (SceneRuntime, SceneDescription, PuppetModelLibrary) throws -> Void) throws {
        let root = try SkeletalAttachmentTests().fixture(reference: .name("头"), mode: mode, fps: 10, frameCount: 20,
                                                        controller: controller, secondLayer: secondLayer)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let library = PuppetModelLibrary(assetRoots: [root])
        try body(SceneRuntime(scene: scene, puppetModels: library), scene, library)
    }
}
