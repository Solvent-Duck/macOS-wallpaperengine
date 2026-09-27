import Foundation

/// A timeline attached to a property, distinct from skeletal animation layers.
public struct PropertyAnimationDescriptor: Codable, Equatable, Sendable {
    public enum PlaybackMode: String, Codable, Sendable {
        case loop, mirror, single
    }

    public struct Handle: Codable, Equatable, Sendable {
        public let enabled: Bool
        public let x: Double
        public let y: Double
    }

    public struct Keyframe: Codable, Equatable, Sendable {
        public let frame: Double
        public let value: Double
        public let front: Handle?
        public let back: Handle?
    }

    public let channels: [[Keyframe]]
    public let fps: Double
    public let length: Double
    public let mode: PlaybackMode
    public let relative: Bool
    public let wrapLoop: Bool
    public let startPaused: Bool
    public let name: String?

    /// Authored scene JSON is separate from the normalized Codable scene model.
    static func parse(_ object: [String: Any]) -> Self? {
        func number(_ value: Any?) -> Double? {
            let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return result.flatMap { $0.isFinite ? $0 : nil }
        }
        func handle(_ value: Any?) -> Handle? {
            guard let value = value as? [String: Any] else { return nil }
            return Handle(enabled: value["enabled"] as? Bool ?? false,
                          x: number(value["x"]) ?? 0, y: number(value["y"]) ?? 0)
        }
        let channels = (0..<4).map { index -> [Keyframe] in
            // Last authored value wins when malformed exports repeat a frame.
            var keys: [Double: Keyframe] = [:]
            for value in object["c\(index)"] as? [[String: Any]] ?? [] {
                guard let frame = number(value["frame"]), frame >= 0,
                      let scalar = number(value["value"]) else { continue }
                keys[frame] = Keyframe(frame: frame, value: scalar,
                                       front: handle(value["front"]), back: handle(value["back"]))
            }
            return keys.values.sorted { $0.frame < $1.frame }
        }
        guard channels.contains(where: { !$0.isEmpty }) else { return nil }
        let options = object["options"] as? [String: Any] ?? [:]
        let fps = number(options["fps"]) ?? 30
        let lastFrame = channels.compactMap { $0.last?.frame }.max() ?? 0
        return Self(channels: channels, fps: fps > 0 ? fps : 30,
                    length: max(0, number(options["length"]) ?? lastFrame),
                    mode: PlaybackMode(rawValue: options["mode"] as? String ?? "loop") ?? .loop,
                    relative: object["relative"] as? Bool ?? false,
                    wrapLoop: options["wraploop"] as? Bool ?? false,
                    startPaused: options["startpaused"] as? Bool ?? false,
                    name: options["name"] as? String)
    }
}
