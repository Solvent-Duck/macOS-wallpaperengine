import Foundation
import NativeSceneCore

/// Playback state for a property timeline; skeletal clips use a separate path.
struct ScenePropertyAnimation {
    let descriptor: PropertyAnimationDescriptor
    var phase: Double = 0
    var rate: Double = 1
    var playing: Bool

    init(_ descriptor: PropertyAnimationDescriptor) {
        self.descriptor = descriptor
        self.playing = !descriptor.startPaused
    }

    var frame: Double {
        let length = descriptor.length
        guard length > 0 else { return 0 }
        switch descriptor.mode {
        case .single: return min(length, max(0, phase))
        case .loop: return positiveRemainder(phase, length)
        case .mirror:
            let position = positiveRemainder(phase, length * 2)
            return position <= length ? position : length * 2 - position
        }
    }

    mutating func advance(_ deltaTime: Double) {
        guard playing, deltaTime.isFinite, deltaTime > 0 else { return }
        let next = phase + deltaTime * descriptor.fps * rate
        guard next.isFinite else { return }
        phase = next
        if descriptor.mode == .single {
            phase = min(descriptor.length, max(0, phase))
            if rate > 0 && phase == descriptor.length || rate < 0 && phase == 0 { playing = false }
        }
    }

    var snapshot: [String: Any] {
        ["phase": phase, "frame": frame, "rate": rate, "playing": playing]
    }

    mutating func apply(_ values: [String: Any]) {
        if let phase = values["phase"] as? Double, phase.isFinite { self.phase = phase }
        if let rate = values["rate"] as? Double, rate.isFinite { self.rate = rate }
        if let playing = values["playing"] as? Bool { self.playing = playing }
    }

    private func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: divisor)
        return result < 0 ? result + divisor : result
    }
}
