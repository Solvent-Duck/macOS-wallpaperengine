@testable import NativeSceneRuntime
import Testing

struct ParticleRandomTests {
    @Test func samplesCoverTheUnitInterval() {
        var random = ParticleRandomGenerator(seed: 431960)
        let samples = (0..<4096).map { _ in random.nextUnitFloat() }
        #expect(samples.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(samples.min()! < 0.01)
        #expect(samples.max()! > 0.99)
        let mean = samples.reduce(0, +) / Float(samples.count)
        #expect(mean > 0.48 && mean < 0.52)
        // Exercise both sides of each emitter and the full authored color,
        // size, lifetime and velocity ranges rather than clustering at min.
        let buckets = samples.reduce(into: [Int](repeating: 0, count: 8)) { $0[Int($1 * 8)] += 1 }
        #expect(buckets.allSatisfy { $0 > 400 && $0 < 625 })
    }

    @Test func aSeedReproducesTheSimulation() {
        var first = ParticleRandomGenerator(seed: 100)
        var second = ParticleRandomGenerator(seed: 100)
        for _ in 0..<64 {
            #expect(first.nextFloat(min: -10, max: 10) == second.nextFloat(min: -10, max: 10))
        }
    }
}
