import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ParticleTrailTests {
    @Test
    func ropetrailKeepsPerParticleHistoryCappedAtSegments() throws {
        let scene = try particleScene(
            emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 2]],
            operators: [["name": "movement"]],
            initializers: [["name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"]],
            renderer: ["name": "ropetrail", "length": 0.4, "segments": 4]
        )
        let runtime = SceneRuntime(scene: scene)
        var system = try #require(runtime.step(deltaTime: 0.05).particleSystems.first)
        for _ in 0..<20 { system = try #require(runtime.step(deltaTime: 0.05).particleSystems.first) }

        #expect(system.instances.count == 2)
        for instance in system.instances {
            let trail = try #require(instance.trail)
            #expect(trail.count == 4)
            // Oldest first, strictly behind the head along the velocity.
            #expect(zip(trail, trail.dropFirst()).allSatisfy { $0.x < $1.x })
            #expect(trail.last!.x < instance.position.x)
        }
    }

    @Test
    func spriteRenderersCarryNoTrail() throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "rate": 0, "instantaneous": 2]],
                                      operators: [["name": "movement"]])
        let runtime = SceneRuntime(scene: scene)
        _ = runtime.step(deltaTime: 0.05)
        let system = try #require(runtime.step(deltaTime: 0.05).particleSystems.first)
        #expect(system.instances.allSatisfy { $0.trail == nil })
    }
}
