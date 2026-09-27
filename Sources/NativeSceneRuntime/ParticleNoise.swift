import Foundation
import simd

/// Perlin/curl noise matching the reference implementation used by the
/// turbulence family of particle initializers/operators.
enum ParticleNoise {
    private static let simplexGradients: [SIMD3<Float>] = [
        SIMD3(1, 1, 0), SIMD3(-1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, -1, 0),
        SIMD3(1, 0, 1), SIMD3(-1, 0, 1), SIMD3(1, 0, -1), SIMD3(-1, 0, -1),
        SIMD3(0, 1, 1), SIMD3(0, -1, 1), SIMD3(0, 1, -1), SIMD3(0, -1, -1)
    ]

    private static let permutation: [Int] = {
        let base: [Int] = [
            151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37,
            240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177,
            33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146,
            158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25,
            63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100,
            109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206,
            59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153,
            101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246,
            97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192,
            214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114,
            67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
        ]
        return base + base
    }()

    private static func grad(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
        switch hash & 0xF {
        case 0x0: return x + y
        case 0x1: return -x + y
        case 0x2: return x - y
        case 0x3: return -x - y
        case 0x4: return x + z
        case 0x5: return -x + z
        case 0x6: return x - z
        case 0x7: return -x - z
        case 0x8: return y + z
        case 0x9: return -y + z
        case 0xA: return y - z
        case 0xB: return -y - z
        case 0xC: return y + x
        case 0xD: return -y + z
        case 0xE: return y - x
        default: return -y - z
        }
    }

    private static func ease(_ t: Double) -> Double {
        t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }

    static func perlin(_ px: Double, _ py: Double, _ pz: Double) -> Double {
        let xi = Int(floor(px)) & 255
        let yi = Int(floor(py)) & 255
        let zi = Int(floor(pz)) & 255

        let x = px - floor(px)
        let y = py - floor(py)
        let z = pz - floor(pz)

        let u = ease(x)
        let v = ease(y)
        let w = ease(z)

        let a = permutation[xi] + yi
        let aa = permutation[a] + zi
        let ab = permutation[a + 1] + zi
        let b = permutation[xi + 1] + yi
        let ba = permutation[b] + zi
        let bb = permutation[b + 1] + zi

        func lerp(_ t: Double, _ lhs: Double, _ rhs: Double) -> Double {
            lhs + t * (rhs - lhs)
        }

        return lerp(
            w,
            lerp(
                v,
                lerp(u, grad(permutation[aa], x, y, z), grad(permutation[ba], x - 1, y, z)),
                lerp(u, grad(permutation[ab], x, y - 1, z), grad(permutation[bb], x - 1, y - 1, z))
            ),
            lerp(
                v,
                lerp(u, grad(permutation[aa + 1], x, y, z - 1), grad(permutation[ba + 1], x - 1, y, z - 1)),
                lerp(u, grad(permutation[ab + 1], x, y - 1, z - 1), grad(permutation[bb + 1], x - 1, y - 1, z - 1))
            )
        )
    }

    static func perlinVector(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(perlin(Double(p.x), Double(p.y), Double(p.z))),
            Float(perlin(Double(p.x) + 89.2, Double(p.y) + 33.1, Double(p.z) + 57.3)),
            Float(perlin(Double(p.x) + 100.3, Double(p.y) + 120.1, Double(p.z) + 142.2))
        )
    }

    /// Tetrahedral simplex noise using the same deterministic permutation as
    /// the existing Perlin sampler. Particle remaps also use fractal sums of it.
    static func simplex(_ point: SIMD3<Float>) -> Float {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              simd_reduce_max(abs(point)) < 1e9 else { return 0 }
        let skew = (point.x + point.y + point.z) / 3
        let cell = SIMD3<Float>(floor(point.x + skew), floor(point.y + skew), floor(point.z + skew))
        let unskew = (cell.x + cell.y + cell.z) / 6
        let local = point - cell + SIMD3(repeating: unskew)
        let first: SIMD3<Float>
        let second: SIMD3<Float>
        if local.x >= local.y {
            if local.y >= local.z { first = SIMD3(1, 0, 0); second = SIMD3(1, 1, 0) }
            else if local.x >= local.z { first = SIMD3(1, 0, 0); second = SIMD3(1, 0, 1) }
            else { first = SIMD3(0, 0, 1); second = SIMD3(1, 0, 1) }
        } else {
            if local.y < local.z { first = SIMD3(0, 0, 1); second = SIMD3(0, 1, 1) }
            else if local.x < local.z { first = SIMD3(0, 1, 0); second = SIMD3(0, 1, 1) }
            else { first = SIMD3(0, 1, 0); second = SIMD3(1, 1, 0) }
        }
        let i = Int(cell.x) & 255
        let j = Int(cell.y) & 255
        let k = Int(cell.z) & 255
        func corner(_ offset: SIMD3<Float>, _ position: SIMD3<Float>) -> Float {
            let weight = max(0, 0.6 - simd_length_squared(position))
            let hash = permutation[i + Int(offset.x) + permutation[j + Int(offset.y) + permutation[k + Int(offset.z)]]]
            return weight * weight * weight * weight * simd_dot(simplexGradients[hash % 12], position)
        }
        return 32 * (corner(.zero, local)
                     + corner(first, local - first + SIMD3(repeating: 1.0 / 6))
                     + corner(second, local - second + SIMD3(repeating: 1.0 / 3))
                     + corner(SIMD3(repeating: 1), local - SIMD3(repeating: 0.5)))
    }

    static func fractal(_ point: SIMD3<Float>) -> Float {
        var result: Float = 0
        var amplitude: Float = 0.5
        var weight: Float = 0
        var sample = point
        for _ in 0..<5 {
            result += amplitude * simplex(sample)
            weight += amplitude
            sample = sample * 2 + SIMD3<Float>(17, 31, 47)
            amplitude *= 0.5
        }
        return result / weight
    }

    static func curl(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let e: Float = 1e-4
        let dx = SIMD3<Float>(e, 0, 0)
        let dy = SIMD3<Float>(0, e, 0)
        let dz = SIMD3<Float>(0, 0, e)

        let x0 = perlinVector(p - dx)
        let x1 = perlinVector(p + dx)
        let y0 = perlinVector(p - dy)
        let y1 = perlinVector(p + dy)
        let z0 = perlinVector(p - dz)
        let z1 = perlinVector(p + dz)

        let x = (y1.z - y0.z) - (z1.y - z0.y)
        let y = (z1.x - z0.x) - (x1.z - x0.z)
        let z = (x1.y - x0.y) - (y1.x - y0.x)

        return SIMD3<Float>(x, y, z) / (2 * e)
    }
}
