import NativeSceneCore
import simd

struct ParticleOperatorParameters {
    let values: [String: UserSettingDescriptor]
    let evaluator: PropertyEvaluator

    func scalar(_ name: String, default fallback: Float) -> Float {
        let value = Float(evaluator.scalarDouble(for: values[name], default: Double(fallback)))
        return value.isFinite ? value : fallback
    }

    func vector(_ name: String, default fallback: SIMD3<Float> = .zero) -> SIMD3<Float> {
        let value = evaluator.vector3Value(for: values[name], default: RuntimeVector3(x: fallback.x, y: fallback.y, z: fallback.z)).simdValue
        return value.x.isFinite && value.y.isFinite && value.z.isFinite ? value : fallback
    }

    func string(_ name: String, default fallback: String) -> String {
        evaluator.evaluate(values[name])?.value.stringValue.lowercased() ?? fallback
    }
}

struct ParticleOperatorBlend {
    var inStart: Float = 0
    var inEnd: Float = 0
    var outStart: Float = 1
    var outEnd: Float = 1

    static func read(_ parameters: ParticleOperatorParameters) -> Self {
        Self(inStart: parameters.scalar("blendinstart", default: 0),
             inEnd: parameters.scalar("blendinend", default: 0),
             outStart: parameters.scalar("blendoutstart", default: 1),
             outEnd: parameters.scalar("blendoutend", default: 1))
    }

    func weight(at life: Float) -> Float {
        func ramp(_ value: Float, from: Float, to: Float) -> Float {
            guard to > from else { return value >= to ? 1 : 0 }
            return min(1, max(0, (value - from) / (to - from)))
        }
        return ramp(life, from: inStart, to: inEnd) * (1 - ramp(life, from: outStart, to: outEnd))
    }
}
