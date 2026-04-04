import Foundation
import NativeSceneCore
import simd

struct ParticleSystemState {
    var emitters: [ParticleEmitterState]
    var particles: [ParticleInstanceState] = []
    var rng: ParticleRandomGenerator

    init(nodeID: NodeID, emitters: [ParticleEmitterDescriptor]) {
        self.emitters = emitters.map(ParticleEmitterState.init)
        self.rng = ParticleRandomGenerator(seed: UInt64(truncatingIfNeeded: nodeID.rawValue) &+ 0x9E3779B97F4A7C15)
    }
}

struct ParticleEmitterState {
    var emissionTimer: Double = 0
    var delayTimer: Double
    var durationTimer: Double = 0
    var periodicTimer: Double = 0
    var periodicDuration: Double = 0
    var periodicDelay: Double = 0
    var emitting = false
    var instantaneousEmitted = false

    init(descriptor: ParticleEmitterDescriptor) {
        self.delayTimer = max(descriptor.delay, 0)
    }
}

struct ParticleInstanceState {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var rotation: SIMD3<Float>
    var angularVelocity: SIMD3<Float>
    var color: SIMD4<Float>
    var size: Float
    var lifetime: Float
    var age: Float
    var initial: ParticleInitialState
    var oscillateAlpha = ParticleScalarOscillatorState()
    var oscillatePosition = ParticleVectorOscillatorState()

    var isAlive: Bool {
        lifetime > 0.0001 && age < lifetime && size > 0.0001
    }

    var lifetimePosition: Float {
        guard lifetime > 0.0001 else {
            return 1
        }
        return min(max(age / lifetime, 0), 1)
    }
}

struct ParticleInitialState {
    var color: SIMD4<Float>
    var size: Float
    var lifetime: Float
}

struct ParticleScalarOscillatorState {
    var initialized = false
    var frequency: Float = 0
    var phase: Float = 0
    var base: Float = 1
}

struct ParticleVectorOscillatorState {
    var initialized = false
    var frequency = SIMD3<Float>(repeating: 0)
    var phase = SIMD3<Float>(repeating: 0)
    var scale = SIMD3<Float>(repeating: 0)
}

struct ParticleResolvedInstanceOverrides {
    let alpha: Float
    let size: Float
    let lifetime: Float
    let rate: Float
    let speed: Float
    let count: Float
    let color: SIMD4<Float>
    let colorN: SIMD3<Float>
}

struct ParticleRandomGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xA4093822299F31D0 : seed
    }

    mutating func nextUnitFloat() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let bits = UInt32(truncatingIfNeeded: state >> 40)
        return Float(bits) / Float(UInt32.max)
    }

    mutating func nextFloat(min: Float, max: Float) -> Float {
        guard max.isFinite, min.isFinite else {
            return min
        }
        if abs(max - min) < 0.0001 {
            return min
        }
        return min + (max - min) * nextUnitFloat()
    }

    mutating func nextInt(max: Int) -> Int {
        guard max > 0 else {
            return 0
        }
        return Int(nextFloat(min: 0, max: Float(max)))
    }

    mutating func nextBool() -> Bool {
        nextUnitFloat() < 0.5
    }
}
