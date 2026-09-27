import Foundation
import NativeSceneCore

/// One authored layer owns its clock even when several layers use the same clip.
struct SceneSkeletalAnimation {
    let clip: PuppetAnimation?
    private(set) var phase: Double = 0
    private(set) var frame: Double = 0
    private(set) var playing = true

    /// Number of end crossings during this interval. Seeking and playback
    /// controls do not emit events; only advancing the clock does.
    @discardableResult
    mutating func advance(_ deltaTime: Double, rate: Double) -> Double {
        guard let clip, playing, deltaTime.isFinite, deltaTime > 0, rate.isFinite, rate != 0 else { return 0 }
        let next = phase + deltaTime * Double(clip.fps) * rate
        guard next.isFinite else { return 0 }
        let length = Double(clip.frameCount)
        let previous = phase
        frame = clip.frame(atPhase: next)
        switch clip.mode {
        case .single:
            phase = frame
            if rate > 0 && next >= length || rate < 0 && next <= 0 { playing = false }
        case .loop: phase = frame
        case .mirror:
            let period = length * 2
            phase = period > 0 ? next.truncatingRemainder(dividingBy: period) : 0
            if phase < 0 { phase += period }
        }
        guard length > 0 else { return 0 }
        if clip.mode == .single { return playing ? 0 : 1 }
        // Mirrored playback reaches the far endpoint halfway through each
        // out-and-back cycle. Exclude the starting boundary so an exact hit
        // cannot be reported again on the next frame.
        let period = clip.mode == .mirror ? length * 2 : length
        let offset = clip.mode == .mirror ? length : 0
        let start = (previous - offset) / period
        let end = (next - offset) / period
        return max(0, next > previous ? floor(end) - floor(start) : ceil(start) - ceil(end))
    }

    mutating func apply(action: String, frame requestedFrame: Double?, rate: Double) {
        switch action {
        case "play":
            if let clip, clip.mode == .single {
                if rate > 0 && frame >= Double(clip.frameCount) { seek(0) }
                else if rate < 0 && frame <= 0 { seek(Double(clip.frameCount)) }
            }
            playing = true
        case "pause": playing = false
        case "stop": playing = false; seek(0)
        case "setFrame": if let requestedFrame, requestedFrame.isFinite { seek(requestedFrame) }
        default: break
        }
    }

    private mutating func seek(_ value: Double) {
        frame = min(Double(clip?.frameCount ?? 0), max(0, value))
        phase = frame
    }

    var snapshot: [String: Any] { ["frame": frame, "playing": playing] }
}
