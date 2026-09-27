@testable import NativeSceneRuntime
import Testing
import simd

struct ParticleVelocityTests {
    @Test func velocityLimitBlendsInAndOutOverParticleLifetime() throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            operators: [["name": "remapvalue", "output": "velocity", "operation": "remap",
                         "outputrangemin": "30 40 0", "outputrangemax": "30 40 0"],
                        ["name": "capvelocity", "maxspeed": 10, "blendinstart": 0.2, "blendinend": 0.4,
                         "blendoutstart": 0.6, "blendoutend": 0.8]])
        let runtime = SceneRuntime(scene: scene)
        for expectedSpeed: Float in [40, 10, 40] {
            let particle = try #require(runtime.step(deltaTime: 25).particleSystems.first?.instances.first)
            let velocity = SIMD3(particle.velocity.x, particle.velocity.y, particle.velocity.z)
            #expect(abs(simd_length(velocity) - expectedSpeed) < 0.001)
            #expect(abs(particle.velocity.x / particle.velocity.y - 0.75) < 0.001)
        }
    }

    @Test(arguments: ["0 0 0", "3 4 0", "-30 -40 0"])
    func velocityLimitPreservesSlowParticlesAndDirection(velocity: String) throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            operators: [["name": "capvelocity", "maxspeed": 5]],
            initializers: [["name": "velocityrandom", "min": velocity, "max": velocity]])
        let particle = try #require(SceneRuntime(scene: scene).step(deltaTime: 0.1).particleSystems.first?.instances.first)
        let expected: SIMD3<Float> = velocity == "0 0 0" ? .zero : velocity == "3 4 0" ? SIMD3(3, 4, 0) : SIMD3(-3, -4, 0)
        #expect(simd_distance(SIMD3(particle.velocity.x, particle.velocity.y, particle.velocity.z), expected) < 0.001)
    }
}
