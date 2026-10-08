import Foundation
import NativeSceneCore
import simd

enum ParticleRemap {
    static let inputs: Set<String> = ["lifetime", "age", "particlesystemtime", "timeofday", "speed", "size", "opacity", "alpha", "color", "velocity", "position", "rotation", "angularvelocity", "distancetocontrolpoint"]
    static let outputs: Set<String> = ["size", "opacity", "alpha", "color", "velocity", "speed", "position", "rotation", "angularvelocity", "lifetime"]
    static let operations: Set<String> = ["remap", "assign", "multiply", "add", "subtract"]
    static let transforms: Set<String> = ["none", "linear", "sine", "cosine", "simplexnoise", "fbmnoise"]

    struct Settings {
        var input = "lifetime"
        var output = "size"
        var operation = "multiply"
        var transform = "none"
        var inputMinimum = SIMD3<Float>.zero
        var inputMaximum = SIMD3<Float>(repeating: 1)
        var outputMinimum = SIMD3<Float>.zero
        var outputMaximum = SIMD3<Float>(repeating: 1)
        var transformScale: Float = 1
        var clampInput = true
        var clampOutput = true
        var controlPoint = 0
        var blend = ParticleOperatorBlend()

        static func read(_ parameters: ParticleOperatorParameters, flags: Int) -> Self {
            Self(input: parameters.string("input", default: "lifetime"),
                 output: parameters.string("output", default: "size"),
                 operation: parameters.string("operation", default: "multiply"),
                 transform: parameters.string("transformfunction", default: "none"),
                 inputMinimum: parameters.vector("inputrangemin"),
                 inputMaximum: parameters.vector("inputrangemax", default: SIMD3(repeating: 1)),
                 outputMinimum: parameters.vector("outputrangemin"),
                 outputMaximum: parameters.vector("outputrangemax", default: SIMD3(repeating: 1)),
                 transformScale: parameters.scalar("transforminputscale", default: 1),
                 clampInput: flags & 1 != 0, clampOutput: flags & 2 != 0,
                 controlPoint: Int(parameters.scalar("inputcontrolpoint0", default: 0)),
                 blend: .read(parameters))
        }
    }

    static func apply(to particle: inout ParticleInstanceState, settings: Settings,
                      systemTime: Float, timeOfDay: Float, controlPoints: [Int: SIMD3<Float>], initial: Bool = false) {
        func scalar(_ value: Float) -> SIMD3<Float> { SIMD3(repeating: value) }
        let input: SIMD3<Float>
        switch settings.input {
        case "lifetime": input = scalar(particle.lifetimePosition)
        case "age": input = scalar(particle.age)
        case "particlesystemtime": input = scalar(systemTime)
        case "timeofday": input = scalar(timeOfDay)
        case "speed": input = scalar(simd_length(particle.velocity))
        case "distancetocontrolpoint": input = scalar(simd_distance(particle.position, controlPoints[settings.controlPoint] ?? .zero))
        case "size": input = scalar(particle.size)
        case "opacity", "alpha": input = scalar(particle.color.w)
        case "color": input = SIMD3(particle.color.x, particle.color.y, particle.color.z)
        case "velocity": input = particle.velocity
        case "position": input = particle.position
        case "rotation": input = particle.rotation
        case "angularvelocity": input = particle.angularVelocity
        default: return
        }
        var mapped = SIMD3<Float>.zero
        for axis in 0..<3 {
            let span = settings.inputMaximum[axis] - settings.inputMinimum[axis]
            var t = abs(span) > 0.000001 ? (input[axis] - settings.inputMinimum[axis]) / span : 0
            if settings.clampInput { t = min(1, max(0, t)) }
            let phase = t * settings.transformScale
            switch settings.transform {
            case "sine": t = 0.5 + 0.5 * sin(phase)
            case "cosine": t = 0.5 + 0.5 * cos(phase)
            case "simplexnoise": t = 0.5 + 0.5 * ParticleNoise.simplex(SIMD3(phase, 0, 0))
            case "fbmnoise": t = 0.5 + 0.5 * ParticleNoise.fractal(SIMD3(phase, 0, 0))
            default: break
            }
            var value = settings.outputMinimum[axis] + (settings.outputMaximum[axis] - settings.outputMinimum[axis]) * t
            if settings.clampOutput {
                value = min(max(settings.outputMinimum[axis], settings.outputMaximum[axis]),
                            max(min(settings.outputMinimum[axis], settings.outputMaximum[axis]), value))
            }
            guard value.isFinite else { return }
            mapped[axis] = value
        }
        let weight = initial ? 1 : settings.blend.weight(at: particle.lifetimePosition)
        func result(_ current: SIMD3<Float>) -> SIMD3<Float> {
            let target: SIMD3<Float>
            switch settings.operation {
            case "remap", "assign": target = mapped
            case "multiply": target = current * mapped
            case "add": target = current + mapped
            case "subtract": target = current - mapped
            default: return current
            }
            return current + (target - current) * weight
        }
        switch settings.output {
        case "size": particle.size = max(0, result(scalar(particle.size)).x)
        case "opacity", "alpha": particle.color.w = min(1, max(0, result(scalar(particle.color.w)).x))
        case "color":
            let color = result(SIMD3(particle.color.x, particle.color.y, particle.color.z))
            particle.color = SIMD4(color.x, color.y, color.z, particle.color.w)
        case "velocity": particle.velocity = result(particle.velocity)
        case "speed":
            let magnitude = simd_length(particle.velocity)
            if magnitude > 0.000001 { particle.velocity *= result(scalar(magnitude)).x / magnitude }
        case "position": particle.position = result(particle.position)
        case "rotation": particle.rotation = result(particle.rotation)
        case "angularvelocity": particle.angularVelocity = result(particle.angularVelocity)
        case "lifetime": particle.lifetime = max(0, result(scalar(particle.lifetime)).x)
        default: break
        }
    }

    static func currentTimeOfDay() -> Float {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: SceneClock.now())
        return Float((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)) / 86400
    }
}
