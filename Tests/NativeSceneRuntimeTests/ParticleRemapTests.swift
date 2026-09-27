@testable import NativeSceneRuntime
import Testing
import simd

struct ParticleRemapTests {
    @Test func distanceCanRemapAColorWithoutChangingOpacity() {
        var particle = testParticle(position: SIMD3(275, 0, 0))
        particle.color.w = 0.4
        let settings = ParticleRemap.Settings(input: "distancetocontrolpoint", output: "color", operation: "remap",
            inputMinimum: SIMD3(repeating: 150), inputMaximum: SIMD3(repeating: 200),
            outputMinimum: SIMD3(1, 0, 0), outputMaximum: SIMD3(0, 0, 1), controlPoint: 1)
        ParticleRemap.apply(to: &particle, settings: settings, systemTime: 0, timeOfDay: 0,
                            controlPoints: [1: SIMD3(100, 0, 0)])
        #expect(particle.color == SIMD4(0.5, 0, 0.5, 0.4))
    }

    @Test(arguments: ["remap", "multiply", "add", "subtract"])
    func arithmeticOperationsUseTheMappedValue(operation: String) {
        var particle = testParticle(age: 0.5)
        particle.size = 10
        let settings = ParticleRemap.Settings(input: "age", output: "size", operation: operation,
            outputMinimum: SIMD3(repeating: 2), outputMaximum: SIMD3(repeating: 4))
        ParticleRemap.apply(to: &particle, settings: settings, systemTime: 0, timeOfDay: 0, controlPoints: [:])
        let expected: [String: Float] = ["remap": 3, "multiply": 30, "add": 13, "subtract": 7]
        #expect(particle.size == expected[operation])
    }

    @Test func clampingAndReversedRangesAreIndependent() {
        var particle = testParticle(velocity: SIMD3(50, 0, 0))
        var settings = ParticleRemap.Settings(input: "speed", operation: "remap",
            inputMinimum: SIMD3(repeating: 100), inputMaximum: .zero,
            outputMinimum: SIMD3(repeating: 4), outputMaximum: SIMD3(repeating: 2))
        ParticleRemap.apply(to: &particle, settings: settings, systemTime: 0, timeOfDay: 0, controlPoints: [:])
        #expect(particle.size == 3)
        particle.velocity = SIMD3(200, 0, 0)
        settings.clampInput = false
        ParticleRemap.apply(to: &particle, settings: settings, systemTime: 0, timeOfDay: 0, controlPoints: [:])
        #expect(particle.size == 4)
        settings.clampOutput = false
        ParticleRemap.apply(to: &particle, settings: settings, systemTime: 0, timeOfDay: 0, controlPoints: [:])
        #expect(particle.size == 6)
    }

    @Test(arguments: ["simplexnoise", "fbmnoise"])
    func noiseRemapsAreDeterministicContinuousAndBounded(transform: String) {
        let settings = ParticleRemap.Settings(input: "particlesystemtime", operation: "remap", transform: transform,
                                              transformScale: 1, clampInput: false)
        func samples() -> [Float] {
            (0..<512).map { index in
                var particle = testParticle()
                ParticleRemap.apply(to: &particle, settings: settings, systemTime: Float(index) * 0.01,
                                    timeOfDay: 0, controlPoints: [:])
                return particle.size
            }
        }
        let values = samples()
        #expect(values == samples())
        #expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        #expect(values.max()! - values.min()! > 0.2)
        #expect(zip(values, values.dropFirst()).allSatisfy { abs($0 - $1) < 0.2 })
    }

    @Test func multiplicativeVisualRemapsComposeWithFadesWithoutAccumulating() throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            operators: [["name": "alphafade", "fadeintime": 0.5, "fadeouttime": 1],
                        ["name": "remapvalue", "output": "opacity", "outputrangemin": 0.5, "outputrangemax": 0.5],
                        ["name": "remapvalue", "output": "size", "outputrangemin": 0.5, "outputrangemax": 0.5]])
        let runtime = SceneRuntime(scene: scene)
        let first = try #require(runtime.step(deltaTime: 25).particleSystems.first?.instances.first)
        let second = try #require(runtime.step(deltaTime: 25).particleSystems.first?.instances.first)
        #expect(first.color.w == 0.25)
        #expect(second.color.w == 0.5)
        #expect(first.size == 0.5 && second.size == 0.5)
    }

    @Test func zeroSizeDoesNotKillAParticleThatCanGrowAgain() throws {
        let bound: [String: Any] = ["user": "size", "value": 0]
        let scene = try particleScene(emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            operators: [["name": "remapvalue", "output": "size", "operation": "remap", "outputrangemin": bound, "outputrangemax": bound]])
        let runtime = SceneRuntime(scene: scene)
        let hidden = try #require(runtime.step(deltaTime: 0.1, propertyOverrides: ["size": .double(0)]).particleSystems.first?.instances.first)
        let shown = try #require(runtime.step(deltaTime: 0.1, propertyOverrides: ["size": .double(1)]).particleSystems.first?.instances.first)
        #expect(hidden.size == 0)
        #expect(shown.size == 1)
    }

    @Test func initialRemappingDoesNotRepeatAfterSpawn() throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "origin": "150 0 0", "rate": 0, "instantaneous": 1]],
            operators: [["name": "movement"]],
            initializers: [["name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"],
                ["name": "remapinitialvalue", "input": "distancetocontrolpoint", "operation": "remap", "output": "color",
                 "inputrangemin": 100, "inputrangemax": 200, "outputrangemin": "1 0 0", "outputrangemax": "0 0 1"]])
        let runtime = SceneRuntime(scene: scene)
        let first = try #require(runtime.step(deltaTime: 1).particleSystems.first?.instances.first)
        let second = try #require(runtime.step(deltaTime: 1).particleSystems.first?.instances.first)
        #expect(first.position.x == 250 && second.position.x == 350)
        #expect(first.color.x == 0.5 && first.color.z == 0.5)
        #expect(first.color == second.color)
    }

    @Test func unknownRemapVariantsAreReportedAsUnsupported() throws {
        let scene = try particleScene(emitters: [], operators: [["name": "remapvalue", "input": "unimplemented-input"]])
        let particle = try #require(scene.nodes.first?.particle)
        #expect(ParticleFeatureCatalog.unsupportedFeatures(in: particle).contains("operator:remapvalue:input:unimplemented-input"))
    }
}
