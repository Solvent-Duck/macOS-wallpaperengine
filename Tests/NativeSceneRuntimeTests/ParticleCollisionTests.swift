@testable import NativeSceneRuntime
import Testing
import simd

struct ParticleCollisionTests {
    @Test(arguments: ["bounce", "slide", "stop", "delete"])
    func sweptQuadCollisionHandlesEveryResponse(behavior: String) throws {
        var particle = testParticle(position: SIMD3(2, -10, 0), velocity: SIMD3(2, -20, 0))
        particle.previousPosition = SIMD3(0, 10, 0)
        particle.angularVelocity = SIMD3(0, 0, 5)
        let response = try #require(ParticleCollision.Behavior(rawValue: behavior))
        ParticleCollision.apply(to: &particle, plane: .init(size: SIMD2(10, 10), behavior: response,
                                                           bounceFactor: 0.5, stopRotation: true))
        #expect(particle.position.y >= 0)
        #expect(particle.angularVelocity == .zero)
        switch response {
        case .bounce:
            #expect(particle.velocity == SIMD3(2, 10, 0))
            #expect(abs(particle.position.y - 5) < 0.001)
        case .slide:
            #expect(particle.velocity == SIMD3(2, 0, 0))
            #expect(abs(particle.position.x - 2) < 0.001)
        case .stop:
            #expect(particle.velocity == .zero)
            #expect(abs(particle.position.x - 1) < 0.001)
        case .delete:
            #expect(!particle.isAlive)
            #expect(abs(particle.position.x - 1) < 0.001)
        }
    }

    @Test func quadIgnoresTheBackSideAndOutOfBoundsCrossings() {
        var backSide = testParticle(position: SIMD3(0, 10, 0), velocity: SIMD3(0, 20, 0))
        backSide.previousPosition = SIMD3(0, -10, 0)
        ParticleCollision.apply(to: &backSide, plane: .init(size: SIMD2(10, 10)))
        #expect(backSide.velocity.y == 20)
        var outside = testParticle(position: SIMD3(20, -10, 0), velocity: SIMD3(0, -20, 0))
        outside.previousPosition = SIMD3(20, 10, 0)
        ParticleCollision.apply(to: &outside, plane: .init(size: SIMD2(10, 10)))
        #expect(outside.velocity.y == -20)
        #expect(outside.position.y == -10)
    }

    @Test func orientedQuadUsesItsNormalAndForwardAxes() {
        var particle = testParticle(position: SIMD3(-10, 2, 3), velocity: SIMD3(-20, 0, 0))
        particle.previousPosition = SIMD3(10, 2, 3)
        ParticleCollision.apply(to: &particle, plane: .init(normal: SIMD3(1, 0, 0), forward: SIMD3(0, 1, 0),
                                                           size: SIMD2(10, 10), bounceFactor: 1))
        #expect(particle.velocity.x == 20)
        #expect(particle.position.x > 9.99)
        #expect(particle.position.y == 2 && particle.position.z == 3)
    }

    @Test func successiveCollisionsSweepFromThePreviousContact() {
        var particle = testParticle(position: SIMD3(-10, -10, 0), velocity: SIMD3(-20, -20, 0))
        particle.previousPosition = SIMD3(10, 10, 0)
        ParticleCollision.apply(to: &particle, plane: .init(bounceFactor: 0.5))
        // The reflected segment meets this short wall beside the floor.
        // Sweeping from the original position would miss its finite bounds.
        ParticleCollision.apply(to: &particle, plane: .init(normal: SIMD3(1, 0, 0),
                                                           size: SIMD2(2, 2), bounceFactor: 0.5))
        #expect(simd_distance(particle.position, SIMD3(5, 5, 0)) < 0.001)
        #expect(particle.velocity == SIMD3(10, 10, 0))
    }

    @Test func collisionDeletionAndControlPointOffsetRunThroughTheRuntime() throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "origin": "100 15 0", "rate": 0, "instantaneous": 1]],
            operators: [["name": "movement"], ["name": "collisionquad", "origin": "0 10 0", "size": "20 20",
                                              "flags": 1, "controlpoint": 1, "collisionbehavior": "delete"]],
            initializers: [["name": "velocityrandom", "min": "0 -100 0", "max": "0 -100 0"]],
            controlPoints: [["id": 1, "offset": "100 0 0"]])
        let runtime = SceneRuntime(scene: scene)
        let first = try #require(runtime.step(deltaTime: 0.01).particleSystems.first)
        #expect(first.instances.count == 1)
        let second = try #require(runtime.step(deltaTime: 0.1).particleSystems.first)
        #expect(second.instances.isEmpty)
    }
}
