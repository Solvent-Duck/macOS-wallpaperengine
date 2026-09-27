import Foundation
import simd

enum ParticleBoids {
    struct Settings {
        var neighborRadius: Float = 100
        var separationRadius: Float = 25
        var cohesion: Float = 1
        var alignment: Float = 1
        var separation: Float = 1
        var maxSpeed: Float? = 100
        var blend = ParticleOperatorBlend()

        static func read(_ parameters: ParticleOperatorParameters, flags: Int) -> Self {
            Self(neighborRadius: max(0, parameters.scalar("neighborthreshold", default: 100)),
                 separationRadius: max(0, parameters.scalar("separationthreshold", default: 25)),
                 cohesion: parameters.scalar("cohesionfactor", default: 1),
                 alignment: parameters.scalar("alignmentfactor", default: 1),
                 separation: parameters.scalar("separationfactor", default: 1),
                 maxSpeed: flags & 1 != 0 ? max(0, parameters.scalar("maxspeed", default: 100)) : nil,
                 blend: .read(parameters))
        }
    }

    static func apply(to particles: inout [ParticleInstanceState], settings: Settings, deltaTime: Float, speed: Float) {
        guard deltaTime > 0, !particles.isEmpty else { return }
        // Read an immutable snapshot so updating one bird cannot influence
        // another until the next step. Spatial buckets avoid a global N² scan.
        let positions = particles.map(\.position)
        let velocities = particles.map(\.velocity)
        let cellSize = max(settings.neighborRadius, settings.separationRadius, 0.001)
        func cell(_ position: SIMD3<Float>) -> SIMD3<Int>? {
            let scaled = position / cellSize
            guard scaled.x.isFinite, scaled.y.isFinite, scaled.z.isFinite,
                  simd_reduce_max(abs(scaled)) < Float(Int32.max - 1024) else { return nil }
            return SIMD3(Int(floor(scaled.x)), Int(floor(scaled.y)), Int(floor(scaled.z)))
        }
        var buckets: [SIMD3<Int>: [Int]] = [:]
        for index in particles.indices where particles[index].isAlive {
            if let key = cell(positions[index]) { buckets[key, default: []].append(index) }
        }
        func direction(_ value: SIMD3<Float>) -> SIMD3<Float> {
            let length = simd_length(value)
            return length > 0.00001 ? value / length : .zero
        }
        let neighborSquared = settings.neighborRadius * settings.neighborRadius
        let separationSquared = settings.separationRadius * settings.separationRadius
        for index in particles.indices where particles[index].isAlive {
            guard let key = cell(positions[index]) else { continue }
            var neighborCount: Float = 0
            var center = SIMD3<Float>.zero
            var averageVelocity = SIMD3<Float>.zero
            var separation = SIMD3<Float>.zero
            for x in -1...1 {
                for y in -1...1 {
                    for z in -1...1 {
                        for other in buckets[key &+ SIMD3(x, y, z)] ?? [] where other != index {
                            let offset = positions[index] - positions[other]
                            let distanceSquared = simd_length_squared(offset)
                            if distanceSquared < neighborSquared {
                                neighborCount += 1
                                center += positions[other]
                                averageVelocity += velocities[other]
                            }
                            if distanceSquared > 0.000001, distanceSquared < separationSquared {
                                // Close neighbors contribute more strongly.
                                separation += offset / distanceSquared
                            }
                        }
                    }
                }
            }
            var acceleration = direction(separation) * settings.separation
            if neighborCount > 0 {
                acceleration += direction(center / neighborCount - positions[index]) * settings.cohesion
                acceleration += (averageVelocity / neighborCount - velocities[index]) * settings.alignment
            }
            let weight = settings.blend.weight(at: particles[index].lifetimePosition)
            var velocity = velocities[index] + acceleration * deltaTime * speed * weight
            if let maxSpeed = settings.maxSpeed {
                let magnitude = simd_length(velocity)
                if magnitude > maxSpeed, magnitude > 0 {
                    velocity += (velocity * (maxSpeed / magnitude) - velocity) * weight
                }
            }
            particles[index].velocity = velocity
        }
    }
}
