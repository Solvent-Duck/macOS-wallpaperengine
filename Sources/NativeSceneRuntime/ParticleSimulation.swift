import Foundation
import NativeSceneCore
import simd

/// Transport controls emission; a paused system can still contain live particles.
struct ParticleTransportState {
    enum Mode { case playing, paused, stopped }
    var mode: Mode = .playing
    var resetID: UInt64 = 0
    var hasLiveParticles = false
    var hasPendingEmission: Bool
    let initialPendingEmission: Bool

    init(particle: ParticleDescriptor, nodeID: NodeID) {
        initialPendingEmission = ParticleFeatureCatalog.isSupported(particle)
            && ParticleSystemState(nodeID: nodeID, emitters: particle.emitters).hasPendingEmission(for: particle)
        hasPendingEmission = initialPendingEmission
    }

    var isPlaying: Bool {
        mode != .stopped && (hasLiveParticles || (mode == .playing && hasPendingEmission))
    }

    mutating func reset() {
        resetID &+= 1
        hasLiveParticles = false
        hasPendingEmission = initialPendingEmission
    }
}

struct ParticleSystemState {
    var transportResetID: UInt64 = 0
    /// Root start delay advances only while emission is playing, without instance rate scaling.
    var emissionTime: Double = 0
    /// Integrates the instance simulation rate, including changes during playback.
    var simulationTime: Double = 0
    var emitters: [ParticleEmitterState]
    var particles: [ParticleInstanceState] = []
    var rng: ParticleRandomGenerator
    /// Once-per-operator random values (phase, speed) for turbulence-style operators.
    var operatorRandoms: [Int: SIMD2<Float>] = [:]
    /// Shared circular sequence counter for mapsequencearoundcontrolpoint.
    var sequenceCounter: Int = 0
    /// Simulation state for child systems, keyed by child index.
    var childStates: [Int: ParticleSystemState] = [:]
    /// Positions of particles spawned this frame (feeds eventspawn children).
    var spawnedThisFrame: [SIMD3<Float>] = []
    /// Positions of particles that died this frame (feeds eventdeath children).
    var diedThisFrame: [SIMD3<Float>] = []

    init(nodeID: NodeID, emitters: [ParticleEmitterDescriptor]) {
        self.emitters = emitters.map(ParticleEmitterState.init)
        self.rng = ParticleRandomGenerator(seed: UInt64(truncatingIfNeeded: nodeID.rawValue) &+ 0x9E3779B97F4A7C15)
    }

    init(seed: UInt64, emitters: [ParticleEmitterDescriptor]) {
        self.emitters = emitters.map(ParticleEmitterState.init)
        self.rng = ParticleRandomGenerator(seed: seed)
    }

    var hasLiveParticles: Bool {
        !particles.isEmpty || childStates.values.contains { $0.hasLiveParticles }
    }

    /// Pending schedules remain active through delays, periodic gaps, full pools,
    /// and temporary visibility/instance gates. Those gates do not exhaust a run.
    func hasPendingEmission(for particle: ParticleDescriptor, ownEmission: Bool? = nil, depth: Int = 0) -> Bool {
        let pending = ownEmission ?? particle.emitters.enumerated().contains { index, descriptor in
            let emitter = emitters.indices.contains(index) ? emitters[index] : ParticleEmitterState(descriptor: descriptor)
            return emitter.hasPendingEmission(for: descriptor)
        }
        if pending { return true }
        guard depth < 3 else { return false }
        return particle.children.enumerated().contains { index, child in
            guard let descriptor = child.particle.first,
                  !descriptor.emitters.isEmpty || !descriptor.initializers.isEmpty else { return false }
            let childState = childStates[index] ?? ParticleSystemState(seed: 0, emitters: descriptor.emitters)
            let childEmission: Bool?
            switch child.type.lowercased() {
            case "eventspawn": childEmission = false // No pending parent emission remains.
            case "eventdeath": childEmission = !particles.isEmpty && child.probability > 0 && !descriptor.emitters.isEmpty
            case "eventfollow": childEmission = !particles.isEmpty && descriptor.emitters.contains { $0.rate > 0 }
            default: childEmission = nil
            }
            return childState.hasPendingEmission(for: descriptor, ownEmission: childEmission, depth: depth + 1)
        }
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

    func hasPendingEmission(for descriptor: ParticleEmitterDescriptor) -> Bool {
        if descriptor.duration > 0, durationTimer >= descriptor.duration { return false }
        return descriptor.rate > 0 || (descriptor.instantaneous > 0 && !instantaneousEmitted)
    }
}

struct ParticleInstanceState {
    var position: SIMD3<Float>
    var previousPosition: SIMD3<Float>? = nil
    var velocity: SIMD3<Float>
    var rotation: SIMD3<Float>
    var angularVelocity: SIMD3<Float>
    var color: SIMD4<Float>
    var size: Float
    var lifetime: Float
    var age: Float
    var initial: ParticleInitialState
    var oscillateAlpha = ParticleScalarOscillatorState()
    var oscillateSize = ParticleScalarOscillatorState()
    var oscillatePosition = ParticleVectorOscillatorState()
    var animationRandom: Float = 0
    /// ropetrail position history, oldest first, excluding the live position.
    var trail: [SIMD3<Float>] = []
    var trailTimer: Float = 0

    var isAlive: Bool {
        lifetime > 0.0001 && age < lifetime
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
        // We retained 24 bits, matching Float's significand. Divide by 2^24
        // to cover [0, 1) without ever rounding the upper endpoint to 1.
        return Float(bits) / 16_777_216
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
