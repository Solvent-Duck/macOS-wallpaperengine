import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ParticleInstanceTests {
    @Test(arguments: [0.0, 0.25, 2.0])
    func countScalesEmissionBeforeThePoolFills(factor: Double) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]], instanceOverrides: ["count": factor]))
        for _ in 0..<3 { _ = runtime.step(deltaTime: 0.25) }
        let system = try #require(runtime.step(deltaTime: 0.25).particleSystems.first)
        #expect(system.instances.count == Int(8 * factor))
        if factor == 0 { #expect(!system.emissionEnabled) }
    }

    @Test(arguments: [0.0, 0.25, 2.0])
    func countScalesInstantaneousEmission(factor: Double) throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 8]], instanceOverrides: ["count": factor]))
        #expect(runtime.step(deltaTime: 0.1).particleSystems.first?.instances.count == Int(8 * factor))
    }

    @Test func zeroCountStopsEmissionWhileExistingParticlesKeepMoving() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]], operators: [["name": "movement"]],
            initializers: [["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
            instanceOverrides: ["count": ["value": 1, "user": "density"]],
            properties: ["density": ["type": "slider", "value": 1]]))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.count == 2)
        let stopped = try #require(runtime.step(deltaTime: 0.25, propertyOverrides: ["density": .double(0)]).particleSystems.first)
        #expect(stopped.instances.count == 2)
        #expect(stopped.instances.first?.position.x == 5)
        #expect(!stopped.emissionEnabled)
        let resumed = try #require(runtime.step(deltaTime: 0.25, propertyOverrides: ["density": .double(0.5)]).particleSystems.first)
        #expect(resumed.instances.count == 3)
    }

    @Test func rateControlsSimulationAndChangesWithoutJumpingTheClock() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]], operators: [["name": "movement"]],
            initializers: [["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
            instanceOverrides: ["rate": ["value": 1, "user": "speed"]],
            properties: ["speed": ["type": "slider", "value": 2]]))
        let first = try #require(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.first)
        #expect(first.position.x == 5)
        #expect(first.lifetimePosition == 0.005)
        let frozen = try #require(runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(0)]).particleSystems.first?.instances.first)
        #expect(frozen.position == first.position && frozen.lifetimePosition == first.lifetimePosition)
        let slow = try #require(runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(0.5)]).particleSystems.first?.instances.first)
        #expect(slow.position.x == 6.25 && slow.lifetimePosition == 0.00625)
        #expect(runtime.elapsedTime == 0.75)
    }

    @Test func countAndRateComposeForEmission() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]], instanceOverrides: ["count": 0.5, "rate": 2]))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.count == 2)
    }

    @Test func retainedInstanceReferencesMutateDefaultSettingsAcrossFrames() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 8]], nodeSettings: ["name": "Particles", "origin": ["value": "0 0 0", "script": """
            const instance = thisScene.getLayer('Particles').instance;
            export function init(value) {
                if (instance.count !== 1 || instance.rate !== 1 || instance !== thisLayer.instance)
                    throw new Error('missing default instance');
                instance.count = 0.25;
                return value;
            }
            export function update(value) {
                if (instance !== thisLayer.instance) throw new Error('instance identity changed');
                instance.size = 3;
                instance.alpha = 0.5;
                instance.colorn = new Vec3(0.25, 0.5, 0.75);
                return value;
            }
            """]]))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.isEmpty == true)
        let particles = try #require(runtime.step(deltaTime: 0.25).particleSystems.first).instances
        #expect(particles.count == 1)
        #expect(particles.first?.size == 3)
        #expect(particles.first?.color == RuntimeVector4(x: 0.25, y: 0.5, z: 0.75, w: 0.5))
    }

    @Test func instanceValueScriptsUseTheInstanceAsTheirPropertyOwner() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            instanceOverrides: ["alpha": ["value": 1, "script": """
            export function update(value) {
                if (thisObject !== thisLayer.instance || thisObject === thisLayer)
                    throw new Error('wrong instance owner');
                thisObject.size = 4;
                return 0.25;
            }
            """]]))
        let particle = try #require(runtime.step(deltaTime: 0.1).particleSystems.first?.instances.first)
        #expect(particle.size == 4 && particle.color.w == 0.25)
    }

    @Test func fractionalDensityCanEmitIntoASmallPool() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 4]], count: 1, instanceOverrides: ["count": 0.25]))
        let first = try #require(runtime.step(deltaTime: 0.25).particleSystems.first)
        #expect(first.maxParticleCount == 1 && first.instances.isEmpty)
        for _ in 0..<2 { _ = runtime.step(deltaTime: 0.25) }
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.count == 1)
    }

    @Test func simulationTimeRemapsUseTheIntegratedRate() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            operators: [["name": "remapvalue", "input": "particlesystemtime", "operation": "remap", "output": "size",
                         "inputrangemin": 0, "inputrangemax": 1, "outputrangemin": 0, "outputrangemax": 10]],
            instanceOverrides: ["rate": ["value": 1, "user": "speed"]],
            properties: ["speed": ["type": "slider", "value": 2]]))
        #expect(runtime.step(deltaTime: 0.25).particleSystems.first?.instances.first?.size == 5)
        #expect(runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(0)]).particleSystems.first?.instances.first?.size == 5)
        #expect(runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(0.5)]).particleSystems.first?.instances.first?.size == 6.25)
    }

    @Test func childParticlesShareTheirParentsSimulationRate() throws {
        let runtime = SceneRuntime(scene: try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            instanceOverrides: ["rate": ["value": 1, "user": "speed"]],
            properties: ["speed": ["type": "slider", "value": 2]],
            childParticle: ["maxcount": 10, "emitter": [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
                            "initializer": [["name": "lifetimerandom", "min": 100, "max": 100],
                                            ["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]],
                            "operator": [["name": "movement"]], "renderer": [["name": "sprite"]]]))
        let first = try #require(runtime.step(deltaTime: 0.25).particleSystems.first?.childSystems.first?.instances.first)
        #expect(first.position.x == 5 && first.lifetimePosition == 0.005)
        let frozen = try #require(runtime.step(deltaTime: 0.25, propertyOverrides: ["speed": .double(0)]).particleSystems.first?.childSystems.first?.instances.first)
        #expect(frozen.position == first.position && frozen.lifetimePosition == first.lifetimePosition)
    }
}
