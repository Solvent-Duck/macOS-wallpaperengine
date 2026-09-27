import Foundation
import simd

enum ParticleCollision {
    enum Behavior: String {
        case bounce, slide, stop, delete
    }

    struct Plane {
        var origin = SIMD3<Float>.zero
        var normal = SIMD3<Float>(0, 1, 0)
        var forward = SIMD3<Float>(0, 0, 1)
        /// Nil is an infinite plane; a value restricts collision to a quad.
        var size: SIMD2<Float>? = nil
        var behavior: Behavior = .bounce
        var bounceFactor: Float = 0.5
        var stopRotation = false

        static func read(_ parameters: ParticleOperatorParameters, quad: Bool, flags: Int,
                         controlPoint: SIMD3<Float>?) -> Self {
            var normal = parameters.vector("plane", default: SIMD3(0, 1, 0))
            normal = simd_length_squared(normal) > 0.000001 ? simd_normalize(normal) : SIMD3(0, 1, 0)
            let size = parameters.vector("size", default: SIMD3(100, 100, 0))
            var origin = quad ? parameters.vector("origin") : normal * parameters.scalar("distance", default: 0)
            if flags & 1 != 0 { origin += controlPoint ?? .zero }
            return Self(origin: origin, normal: normal,
                        forward: parameters.vector("forward", default: SIMD3(0, 0, 1)),
                        size: quad ? SIMD2(abs(size.x), abs(size.y)) : nil,
                        behavior: Behavior(rawValue: parameters.string("collisionbehavior", default: "bounce")) ?? .bounce,
                        bounceFactor: max(0, parameters.scalar("bouncefactor", default: 0.5)),
                        stopRotation: flags & 2 != 0)
        }
    }

    static func apply(to particle: inout ParticleInstanceState, plane: Plane) {
        guard particle.isAlive, let previous = particle.previousPosition else { return }
        let normalLength = simd_length(plane.normal)
        guard normalLength > 0.00001 else { return }
        let normal = plane.normal / normalLength
        let startDistance = simd_dot(previous - plane.origin, normal)
        let endDistance = simd_dot(particle.position - plane.origin, normal)
        // One-sided collision. Testing the swept segment prevents fast rain
        // and sparks from tunneling through a thin collision quad.
        guard startDistance >= 0, endDistance < 0 else { return }
        let fraction = startDistance / (startDistance - endDistance)
        let displacement = particle.position - previous
        let hit = previous + displacement * fraction
        if let size = plane.size {
            var forward = plane.forward - normal * simd_dot(plane.forward, normal)
            if simd_length_squared(forward) < 0.000001 {
                let fallback = abs(normal.z) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
                forward = fallback - normal * simd_dot(fallback, normal)
            }
            forward = simd_normalize(forward)
            let right = simd_cross(normal, forward)
            let offset = hit - plane.origin
            guard abs(simd_dot(offset, right)) <= size.x * 0.5,
                  abs(simd_dot(offset, forward)) <= size.y * 0.5 else { return }
        }
        func response(_ vector: SIMD3<Float>) -> SIMD3<Float> {
            let inward = min(0, simd_dot(vector, normal))
            switch plane.behavior {
            case .bounce: return vector - normal * inward * (1 + plane.bounceFactor)
            case .slide: return vector - normal * inward
            case .stop, .delete: return .zero
            }
        }
        let correctedHit = hit + normal * 0.0001
        particle.position = correctedHit + response(displacement * (1 - fraction))
        // A later collision operator must sweep the reflected remainder,
        // not the original path through the obstacle we just hit.
        particle.previousPosition = correctedHit
        particle.velocity = response(particle.velocity)
        if plane.stopRotation { particle.angularVelocity = .zero }
        if plane.behavior == .delete { particle.lifetime = 0 }
    }
}
