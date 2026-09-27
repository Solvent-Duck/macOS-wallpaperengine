import Foundation
import NativeSceneCore

enum PropertyAnimationEvaluator {
    static func evaluate(_ animation: PropertyAnimationDescriptor, base: FrameValue, elapsedTime: Double) -> FrameValue {
        let frame = playbackFrame(animation, elapsedTime: elapsedTime)
        return evaluate(animation, base: base, frame: frame)
    }

    static func evaluate(_ animation: PropertyAnimationDescriptor, base: FrameValue, frame: Double) -> FrameValue {
        func component(_ index: Int, _ original: Double) -> Double {
            guard animation.channels.indices.contains(index),
                  let value = sample(animation.channels[index], frame: frame,
                                     loopLength: animation.wrapLoop && animation.mode == .loop ? animation.length : nil)
            else { return original }
            return animation.relative ? original + value : value
        }
        func vector(_ values: [Double]) -> [Double] {
            values.enumerated().map { component($0.offset, $0.element) }
        }
        switch base {
        case .double(let value): return .double(component(0, value))
        case .int(let value): return .double(component(0, Double(value)))
        case .bool(let value): return .bool(component(0, value ? 1 : 0) >= 0.5)
        case .vec2(let values): return .vec2(vector(values))
        case .vec3(let values): return .vec3(vector(values))
        case .vec4(let values): return .vec4(vector(values))
        case .ivec2(let values): return .vec2(vector(values.map(Double.init)))
        case .ivec3(let values): return .vec3(vector(values.map(Double.init)))
        case .ivec4(let values): return .vec4(vector(values.map(Double.init)))
        case .null, .string: return base
        }
    }

    private static func playbackFrame(_ animation: PropertyAnimationDescriptor, elapsedTime: Double) -> Double {
        guard !animation.startPaused, animation.length > 0, elapsedTime.isFinite else { return 0 }
        let frame = max(0, elapsedTime) * animation.fps
        guard frame.isFinite else { return 0 }
        switch animation.mode {
        case .single: return min(frame, animation.length)
        case .loop: return frame.truncatingRemainder(dividingBy: animation.length)
        case .mirror:
            let position = frame.truncatingRemainder(dividingBy: animation.length * 2)
            return position <= animation.length ? position : animation.length * 2 - position
        }
    }

    private static func sample(_ keys: [PropertyAnimationDescriptor.Keyframe], frame: Double, loopLength: Double?) -> Double? {
        guard let first = keys.first, let last = keys.last else { return nil }
        guard keys.count > 1 else { return first.value }
        if frame < first.frame {
            if let length = loopLength, length > last.frame - first.frame {
                return interpolate(last, first, start: last.frame - length, end: first.frame, frame: frame)
            }
            return first.value
        }
        if frame >= last.frame {
            if let length = loopLength, length > last.frame - first.frame {
                return interpolate(last, first, start: last.frame, end: first.frame + length, frame: frame)
            }
            return last.value
        }
        // Curves can have thousands of keys. Find the surrounding interval
        // without scanning all earlier keys for every setting on every frame.
        var low = 0
        var high = keys.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if keys[middle].frame <= frame { low = middle } else { high = middle }
        }
        return interpolate(keys[low], keys[high], start: keys[low].frame, end: keys[high].frame, frame: frame)
    }

    private static func interpolate(
        _ left: PropertyAnimationDescriptor.Keyframe, _ right: PropertyAnimationDescriptor.Keyframe,
        start: Double, end: Double, frame: Double
    ) -> Double {
        let fraction = min(1, max(0, (frame - start) / (end - start)))
        let delta = right.value - left.value
        let front = left.front.flatMap { $0.enabled ? $0 : nil }
        let back = right.back.flatMap { $0.enabled ? $0 : nil }
        guard front != nil || back != nil else { return left.value + fraction * delta }

        // Handle X is stored relative to the interval. Solve the time axis
        // of the cubic as well as its value axis, including one-sided easing.
        let x1 = front.map { min(1, max(0, $0.x / 3)) } ?? (1.0 / 3)
        let x2 = back.map { min(1, max(0, 1 + $0.x / 3)) } ?? (2.0 / 3)
        let y1 = front.map { left.value + $0.y } ?? (left.value + delta / 3)
        let y2 = back.map { right.value + $0.y } ?? (right.value - delta / 3)
        var low = 0.0
        var high = 1.0
        for _ in 0..<30 {
            let t = (low + high) / 2
            if cubic(0, x1, x2, 1, t) < fraction { low = t } else { high = t }
        }
        return cubic(left.value, y1, y2, right.value, (low + high) / 2)
    }

    private static func cubic(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ t: Double) -> Double {
        let s = 1 - t
        return s * s * s * a + 3 * s * s * t * b + 3 * s * t * t * c + t * t * t * d
    }
}
