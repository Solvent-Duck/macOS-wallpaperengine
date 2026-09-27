import NativeSceneCore
@testable import NativeSceneRuntime
import Testing
import simd

struct ParticleEmitterTests {
    @Test(arguments: [false, true])
    func scalarDistancesProduceACenteredPlanarDisk(asString: Bool) throws {
        let minimum: Any = asString ? "10" : 10
        let maximum: Any = asString ? "50" : 50
        let scene = try particleScene(emitters: [["name": "sphererandom", "distancemin": minimum,
                                                "distancemax": maximum, "rate": 0, "instantaneous": 2048]])
        let descriptor = try #require(scene.nodes.first?.particle?.emitters.first)
        #expect(descriptor.distanceMin == [10, 10, 10])
        #expect(descriptor.distanceMax == [50, 50, 50])
        let system = try #require(SceneRuntime(scene: scene).step(deltaTime: 0.01).particleSystems.first)
        #expect(system.instances.count == 2048)
        let points = system.instances.map { $0.position.simdValue }
        #expect(points.allSatisfy { $0.z == 0 && simd_length($0) >= 9.99 && simd_length($0) <= 50.01 })
        #expect(points.contains { $0.x < -40 })
        #expect(points.contains { $0.x > 40 })
        #expect(points.contains { $0.y < -40 })
        #expect(points.contains { $0.y > 40 })
        let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        #expect(simd_length(center) < 2)
    }

    @Test func explicitSignsRestrictSphereEmission() throws {
        let scene = try particleScene(emitters: [["name": "sphererandom", "distancemax": 50,
                                                "sign": [-1, 1, 0], "rate": 0, "instantaneous": 256]])
        let points = try #require(SceneRuntime(scene: scene).step(deltaTime: 0.01).particleSystems.first).instances.map(\.position)
        #expect(points.count == 256)
        #expect(points.allSatisfy { $0.x <= 0 && $0.y >= 0 && $0.z == 0 })
        #expect(points.contains { $0.x < -25 && $0.y > 10 })
    }

    @Test func boxEmissionCoversBothSidesOfTheAuthoredOrigin() throws {
        let scene = try particleScene(emitters: [["name": "boxrandom", "distancemax": "40 20 0",
                                                "origin": "100 200 0", "rate": 0, "instantaneous": 1024]])
        let points = try #require(SceneRuntime(scene: scene).step(deltaTime: 0.01).particleSystems.first).instances.map(\.position)
        #expect(points.allSatisfy { $0.x >= 60 && $0.x <= 140 && $0.y >= 180 && $0.y <= 220 && $0.z == 0 })
        #expect(points.contains { $0.x < 70 && $0.y < 190 })
        #expect(points.contains { $0.x > 130 && $0.y > 210 })
    }
}
