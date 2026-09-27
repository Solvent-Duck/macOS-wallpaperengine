import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ParticleTransportTests {
    private let commands = """
    export function update() {
        const command = engine.userProperties.command;
        if (command === 1) thisLayer.pause();
        if (command === 2) thisLayer.play();
        if (command === 3) thisLayer.stop();
        if (command === 4) { thisLayer.stop(); thisLayer.play(); }
        if (command === 5) { thisLayer.play(); thisLayer.play(); }
        return new Vec3(thisLayer.isPlaying() ? 1 : 0, 0, 0);
    }
    """
    private var commandProperty: [String: Any] { ["command": ["type": "slider", "value": 0]] }
    private var commandOrigin: [String: Any] { ["value": "0 0 0", "script": commands] }
    private var velocity: [[String: Any]] { [["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]] }
    private var child: [String: Any] {
        ["maxcount": 100, "emitter": [["name": "boxrandom", "rate": 8, "instantaneous": 1]],
         "initializer": [["name": "lifetimerandom", "min": 2, "max": 2]] + velocity,
         "operator": [["name": "movement"]], "renderer": [["name": "sprite"]]]
    }
    private func step(_ runtime: SceneRuntime, _ delta: Double, command: Int = 0) -> FramePacket {
        runtime.step(deltaTime: delta, propertyOverrides: ["command": .double(Double(command))])
    }
    private func playing(_ packet: FramePacket, nodeID: Int = 1) -> Float? {
        packet.nodes.first { $0.nodeID == NodeID(rawValue: nodeID) }?.worldPosition.x
    }

    @Test func initPausePreventsEmissionAndReportsAnIdleEmptySystem() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]],
            nodeSettings: ["origin": ["value": "0 0 0", "script": """
            export function init() { thisLayer.pause(); }
            export function update() { return new Vec3(thisLayer.isPlaying() ? -1 : 9, 0, 0); }
            """]]))
        let packet = runtime.step(deltaTime: 0.25)
        let system = try #require(packet.particleSystems.first)
        #expect(system.instances.isEmpty)
        #expect(!system.emissionEnabled)
        #expect(packet.nodes.first?.worldPosition.x == 9)
    }

    @Test func pauseAgesExistingParticlesAndBecomesIdleAfterTheyDie() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]], operators: [["name": "movement"]],
            initializers: velocity + [["name": "lifetimerandom", "min": 1, "max": 1]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        #expect(step(runtime, 0.25).particleSystems.first?.instances.count == 2)
        let paused = step(runtime, 0.25, command: 1)
        let system = try #require(paused.particleSystems.first)
        #expect(system.instances.count == 2 && !system.emissionEnabled)
        #expect(system.instances.first?.position.x == 5)
        #expect(playing(paused) == 1)
        #expect(step(runtime, 0.5).particleSystems.first?.instances.isEmpty == true)
        #expect(playing(step(runtime, 0)) == 0)
    }

    @Test func resumeAndRepeatedPlayPreserveParticlesAndEmissionRemainder() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 6]], operators: [["name": "movement"]],
            initializers: velocity, nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        #expect(step(runtime, 0.25).particleSystems.first?.instances.count == 1)
        #expect(step(runtime, 0.25, command: 1).particleSystems.first?.instances.count == 1)
        let resumed = try #require(step(runtime, 0.25, command: 2).particleSystems.first)
        #expect(resumed.instances.count == 3 && resumed.emissionEnabled)
        #expect(resumed.instances.first?.position.x == 7.5)
        let repeated = try #require(step(runtime, 0.25, command: 5).particleSystems.first)
        #expect(repeated.instances.count == 4)
        #expect(repeated.instances.first?.position.x == 10)
    }

    @Test(arguments: ["eventspawn", "eventfollow", "static"])
    func pauseRetainsAndAgesChildrenWhileStopClearsTheDefinitionTree(childType: String) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty,
            childParticle: child, childType: childType, grandchildParticle: child))
        let initial = try #require(step(runtime, 0.25).particleSystems.first?.childSystems.first)
        #expect(!initial.instances.isEmpty)
        #expect(initial.childSystems.first?.instances.isEmpty == false)
        let paused = try #require(step(runtime, 0.25, command: 1).particleSystems.first?.childSystems.first)
        #expect(paused.instances.count == initial.instances.count && !paused.emissionEnabled)
        #expect(paused.instances.first?.position.x == 5)
        #expect(paused.childSystems.first?.instances.count == initial.childSystems.first?.instances.count)
        #expect(paused.childSystems.first?.instances.first?.lifetimePosition == 0.25)
        let stopped = step(runtime, 0, command: 3)
        #expect(stopped.particleSystems.first?.instances.isEmpty == true)
        #expect(stopped.particleSystems.first?.childSystems.isEmpty == true)
        #expect(playing(stopped) == 0)
        #expect(step(runtime, 1).particleSystems.first?.childSystems.isEmpty == true)
    }

    @Test func pausedParentDeathsDoNotCreateNewChildParticles() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            initializers: [["name": "lifetimerandom", "min": 0.5, "max": 0.5]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty,
            childParticle: child, childType: "eventdeath"))
        #expect(step(runtime, 0.25).particleSystems.first?.instances.count == 1)
        let packet = step(runtime, 0.25, command: 1)
        #expect(packet.particleSystems.first?.instances.isEmpty == true)
        #expect(packet.particleSystems.first?.childSystems.isEmpty == true)
        #expect(playing(step(runtime, 0)) == 0)
    }

    @Test func visibilityStillAllowsExistingParentDeathEvents() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            initializers: [["name": "lifetimerandom", "min": 0.5, "max": 0.5]],
            nodeSettings: ["visible": ["value": true, "user": "show"]],
            properties: ["show": ["type": "bool", "value": true]],
            childParticle: child, childType: "eventdeath"))
        _ = runtime.step(deltaTime: 0.25)
        let packet = runtime.step(deltaTime: 0.25, propertyOverrides: ["show": .bool(false)])
        #expect(packet.particleSystems.first?.instances.isEmpty == true)
        #expect(packet.particleSystems.first?.childSystems.first?.instances.count == 1)
    }

    @Test func childOnlyLivenessEndsWhenTheLastRetainedChildDies() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            initializers: [["name": "lifetimerandom", "min": 0.5, "max": 0.5]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty, childParticle: child))
        _ = step(runtime, 0.25)
        let paused = step(runtime, 0.25, command: 1)
        #expect(paused.particleSystems.first?.instances.isEmpty == true)
        #expect(paused.particleSystems.first?.childSystems.first?.instances.count == 1)
        #expect(playing(step(runtime, 0)) == 1)
        #expect(step(runtime, 1.5).particleSystems.first?.childSystems.isEmpty == true)
        #expect(playing(step(runtime, 0)) == 0)
    }

    @Test(arguments: [false, true])
    func stopAndRestartProduceAFreshDeterministicRun(inOneCallback: Bool) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8, "distancemax": "10 20 0"]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty, childParticle: child))
        let first = try #require(step(runtime, 0.25).particleSystems.first)
        _ = step(runtime, 0.25)
        if !inOneCallback {
            #expect(playing(step(runtime, 0, command: 3)) == 0)
            _ = step(runtime, 1)
            #expect(playing(step(runtime, 0, command: 1)) == 0)
        }
        let restarted = try #require(step(runtime, 0.25, command: inOneCallback ? 4 : 2).particleSystems.first)
        #expect(restarted.instances == first.instances)
        #expect(restarted.childSystems == first.childSystems)
    }

    @Test(arguments: [false, true])
    func exhaustedEmissionCanRestartWhileLiveParticlesRemain(finiteDuration: Bool) throws {
        let emitter: [String: Any] = finiteDuration
            ? ["name": "boxrandom", "rate": 8, "duration": 0.5]
            : ["name": "boxrandom", "rate": 0, "instantaneous": 2]
        let runtime = SceneRuntime(scene: try particleScene(emitters: [emitter],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        let first = try #require(step(runtime, 0.25).particleSystems.first)
        #expect(first.instances.count == 2)
        let exhausted = step(runtime, 0.25)
        #expect(exhausted.particleSystems.first?.instances.count == 2)
        #expect(playing(step(runtime, 0)) == 1)
        let restarted = try #require(step(runtime, 0.25, command: 5).particleSystems.first)
        #expect(restarted.instances == first.instances)
        _ = step(runtime, 101)
        #expect(playing(step(runtime, 0)) == 0)
        #expect(step(runtime, 0.25, command: 2).particleSystems.first?.instances == first.instances)
    }

    @Test func delayedAndPeriodicEmittersRemainActiveBetweenEmissions() throws {
        let delayed = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8, "delay": 0.5]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        for _ in 0..<2 {
            let packet = step(delayed, 0.25)
            #expect(packet.particleSystems.first?.instances.isEmpty == true)
            #expect(playing(packet) == 1)
        }
        #expect(step(delayed, 1, command: 1).particleSystems.first?.instances.isEmpty == true)
        #expect(playing(step(delayed, 0)) == 0)
        #expect(step(delayed, 0.25, command: 2).particleSystems.first?.instances.count == 2)

        let periodic = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8, "flags": 4, "minperiodicduration": 0.25,
                        "maxperiodicduration": 0.25, "minperiodicdelay": 1, "maxperiodicdelay": 1]],
            initializers: [["name": "lifetimerandom", "min": 0.5, "max": 0.5]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        #expect(step(periodic, 0.25).particleSystems.first?.instances.count == 2)
        #expect(step(periodic, 0.25).particleSystems.first?.instances.isEmpty == true)
        let gap = step(periodic, 0.25, command: 2)
        #expect(playing(gap) == 1 && gap.particleSystems.first?.instances.isEmpty == true)
    }

    @Test func startDelayPausesWithEmissionAndRestartsAfterStop() throws {
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 8]], startTime: 500,
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        #expect(step(runtime, 0.25).particleSystems.first?.instances.isEmpty == true)
        #expect(step(runtime, 2, command: 1).particleSystems.first?.instances.isEmpty == true)
        #expect(step(runtime, 0.25, command: 2).particleSystems.first?.instances.count == 2)
        #expect(step(runtime, 0.25, command: 4).particleSystems.first?.instances.isEmpty == true)
        #expect(step(runtime, 0.25).particleSystems.first?.instances.count == 2)
    }

    @Test func separateSceneParentingDoesNotShareParticleTransport() throws {
        let parent: [String: Any] = ["id": 2, "name": "Parent", "particle": child,
            "origin": ["value": "0 0 0", "script": "export function init() { thisLayer.stop(); }"]]
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 8]],
            nodeSettings: ["parent": 2, "origin": ["value": "0 0 0", "script": """
            export function init() { thisLayer.pause(); }
            export function update() {
                thisLayer.play();
                const parent = thisLayer.getParent();
                return new Vec3(thisLayer.isPlaying() && !parent.isPlaying() ? 1 : -1, 0, 0);
            }
            """]], additionalNodes: [parent]))
        let packet = runtime.step(deltaTime: 0.25)
        #expect(packet.particleSystems.first { $0.nodeID == NodeID(rawValue: 2) }?.instances.isEmpty == true)
        #expect(packet.particleSystems.first { $0.nodeID == NodeID(rawValue: 1) }?.instances.count == 2)
        #expect(playing(packet) == 1)
    }

    @Test func transportIsIsolatedFromInstanceGenericLayersAndSound() throws {
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 8]],
            nodeSettings: ["origin": ["value": "0 0 0", "script": """
            export function update() {
                const methods = ['play', 'pause', 'stop', 'isPlaying'];
                const sound = thisScene.getLayer('Sound');
                sound.play(); sound.pause();
                const isolated = [thisLayer.instance, thisScene.getLayer('Image'), thisScene.getLayer('Group')]
                    .every(object => methods.every(method => typeof object[method] === 'undefined'));
                return new Vec3(isolated && !sound.isPlaying() && thisLayer.isPlaying() &&
                    typeof thisLayer.getParticleSystem === 'undefined' ? 1 : -1, 0, 0);
            }
            """]], additionalNodes: [
                ["id": 2, "name": "Image", "image": "missing.json", "size": "10 10"],
                ["id": 3, "name": "Group"],
                ["id": 4, "name": "Sound", "sound": ["sound.ogg"], "startsilent": true]
            ]))
        let packet = runtime.step(deltaTime: 0.25)
        #expect(playing(packet) == 1)
        #expect(packet.soundTransports.first?.state == .paused)
        #expect(packet.soundTransports.first?.runID == 1)
        #expect(packet.particleSystems.first?.instances.count == 2)
    }

    @Test(arguments: [false, true])
    func globalPauseStillFreezesBothRetainedAndEmittingSystems(emissionPaused: Bool) throws {
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 8]],
            operators: [["name": "movement"]], initializers: velocity,
            nodeSettings: ["origin": commandOrigin], properties: commandProperty, childParticle: child))
        _ = step(runtime, 0.25)
        let first = try #require(step(runtime, 0, command: emissionPaused ? 1 : 0).particleSystems.first)
        runtime.setPaused(true)
        let frozen = try #require(step(runtime, 10).particleSystems.first)
        #expect(frozen.instances == first.instances && frozen.childSystems == first.childSystems)
        // Global pause suppresses script updates as well as simulation time.
        let skippedCommand = try #require(step(runtime, 10, command: 3).particleSystems.first)
        #expect(skippedCommand.instances == first.instances && skippedCommand.emissionEnabled == first.emissionEnabled)
        runtime.setPaused(false)
        let aged = try #require(step(runtime, 0.25).particleSystems.first)
        #expect(aged.instances.count == (emissionPaused ? 2 : 4))
        #expect(aged.instances.first?.position.x == 5)
        #expect(runtime.elapsedTime == 0.5)
    }

    @Test func transportQueriesSeeCommandsImmediatelyAcrossRetainedReferences() throws {
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 8]],
            nodeSettings: ["name": "Particles", "origin": ["value": "0 0 0", "script": """
            const retained = thisScene.getLayer('Particles');
            export function update() {
                retained.stop();
                if (thisLayer.isPlaying()) return new Vec3(-1, 0, 0);
                retained.pause();
                if (thisLayer.isPlaying()) return new Vec3(-2, 0, 0);
                thisLayer.play();
                if (!retained.isPlaying()) return new Vec3(-3, 0, 0);
                retained.pause();
                return new Vec3(thisLayer.isPlaying() ? -4 : 9, 0, 0);
            }
            """]]))
        let packet = runtime.step(deltaTime: 0.25)
        #expect(playing(packet) == 9)
        #expect(packet.particleSystems.first?.instances.isEmpty == true)
    }

    @Test func emptyEmitterSchedulesAreIdleButStaticChildrenCanRemainActive() throws {
        let empty = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 0]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        #expect(playing(step(empty, 0.25)) == 0)
        #expect(playing(step(empty, 0.25, command: 2)) == 0)
        let nested = SceneRuntime(scene: try particleScene(emitters: [],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty,
            childParticle: child, childType: "static"))
        let packet = step(nested, 0.25)
        #expect(playing(packet) == 1)
        #expect(packet.particleSystems.first?.instances.isEmpty == true)
        #expect(packet.particleSystems.first?.childSystems.first?.instances.count == 3)
    }

    @Test func temporaryInstanceGatesDoNotExhaustOrRestartTheEmitter() throws {
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "boxrandom", "rate": 6]],
            instanceOverrides: ["count": ["value": 1, "user": "density"]],
            nodeSettings: ["origin": ["value": "0 0 0", "script": """
            export function update() { thisLayer.play(); return new Vec3(thisLayer.isPlaying() ? 1 : 0, 0, 0); }
            """]], properties: ["density": ["type": "slider", "value": 1]]))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.count == 1)
        let gated = runtime.step(deltaTime: 0.25, propertyOverrides: ["density": .double(0)])
        #expect(playing(gated) == 1 && gated.particleSystems.first?.instances.count == 1)
        let resumed = runtime.step(deltaTime: 0.25, propertyOverrides: ["density": .double(1)])
        #expect(playing(resumed) == 1 && resumed.particleSystems.first?.instances.count == 3)
    }

    @Test func unsupportedSimulationDoesNotReportInventedLiveness() throws {
        let runtime = SceneRuntime(scene: try particleScene(emitters: [["name": "unsupported-emitter", "rate": 8]],
            nodeSettings: ["origin": commandOrigin], properties: commandProperty))
        let packet = step(runtime, 0.25, command: 2)
        #expect(playing(packet) == 0 && packet.particleSystems.isEmpty)
    }
}
