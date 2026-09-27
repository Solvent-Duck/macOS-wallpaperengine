@testable import NativeSceneRuntime
import Testing
import simd

struct ParticleBoidsTests {
    @Test func cohesionAndSeparationSteerInOppositeDirections() {
        let pair = [testParticle(position: SIMD3(-1, 0, 0)), testParticle(position: SIMD3(1, 0, 0))]
        var flock = pair
        ParticleBoids.apply(to: &flock, settings: .init(neighborRadius: 10, separationRadius: 5, cohesion: 1,
                                                       alignment: 0, separation: 0, maxSpeed: nil), deltaTime: 1, speed: 1)
        #expect(flock[0].velocity.x > 0 && flock[1].velocity.x < 0)
        flock = pair
        ParticleBoids.apply(to: &flock, settings: .init(neighborRadius: 10, separationRadius: 5, cohesion: 0,
                                                       alignment: 0, separation: 1, maxSpeed: nil), deltaTime: 1, speed: 1)
        #expect(flock[0].velocity.x < 0 && flock[1].velocity.x > 0)
    }

    @Test func alignmentUsesOnlyLiveNeighborsAndAnImmutableVelocitySnapshot() {
        var flock = [testParticle(), testParticle(position: SIMD3(1, 0, 0), velocity: SIMD3(10, 0, 0)),
                     testParticle(position: SIMD3(100, 0, 0), velocity: SIMD3(1000, 0, 0)),
                     testParticle(position: SIMD3(1, 0, 0), velocity: SIMD3(1000, 0, 0), age: 11)]
        ParticleBoids.apply(to: &flock, settings: .init(neighborRadius: 10, separationRadius: 0, cohesion: 0,
                                                       alignment: 1, separation: 0, maxSpeed: nil), deltaTime: 0.1, speed: 1)
        #expect(abs(flock[0].velocity.x - 1) < 0.00001)
        #expect(abs(flock[1].velocity.x - 9) < 0.00001)
        #expect(flock[2].velocity.x == 1000)
        #expect(flock[3].velocity.x == 1000)
    }

    @Test func spatialBucketsRespectNeighborsAcrossCellBoundaries() {
        var flock = [testParticle(position: SIMD3(-0.1, 0, 0)), testParticle(position: SIMD3(0.1, 0, 0))]
        ParticleBoids.apply(to: &flock, settings: .init(neighborRadius: 1, separationRadius: 0, cohesion: 1,
                                                       alignment: 0, separation: 0, maxSpeed: nil), deltaTime: 1, speed: 1)
        #expect(flock[0].velocity.x > 0 && flock[1].velocity.x < 0)
    }

    @Test func speedCapAndLifetimeBlendAreApplied() {
        var flock = [testParticle(velocity: SIMD3(30, 40, 0), age: 1)]
        let settings = ParticleBoids.Settings(maxSpeed: 10, blend: .init(inStart: 0.2, inEnd: 0.4))
        ParticleBoids.apply(to: &flock, settings: settings, deltaTime: 0.1, speed: 1)
        #expect(simd_length(flock[0].velocity) == 50)
        flock[0].age = 5
        ParticleBoids.apply(to: &flock, settings: settings, deltaTime: 0.1, speed: 1)
        #expect(abs(simd_length(flock[0].velocity) - 10) < 0.00001)
    }

    @Test func authoredBoidsOperatorRunsThroughTheSceneRuntime() throws {
        let scene = try particleScene(emitters: [
            ["name": "boxrandom", "origin": "-1 0 0", "rate": 0, "instantaneous": 1],
            ["name": "boxrandom", "origin": "1 0 0", "rate": 0, "instantaneous": 1]
        ], operators: [["name": "boids", "flags": 0, "neighborthreshold": 10,
                        "cohesionfactor": 10, "alignmentfactor": 0, "separationfactor": 0]])
        let system = try #require(SceneRuntime(scene: scene).step(deltaTime: 0.1).particleSystems.first)
        #expect(system.instances.count == 2)
        #expect(system.instances[0].velocity.x > 0)
        #expect(system.instances[1].velocity.x < 0)
    }
}
