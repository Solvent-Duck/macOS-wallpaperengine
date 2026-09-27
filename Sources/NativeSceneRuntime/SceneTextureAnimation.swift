import Foundation
import NativeSceneCore

struct SceneTextureAnimation {
    let descriptor: TextureAnimation
    var time: Double = 0
    var rate: Double = 1
    var playing = true
    var joined = true

    mutating func advance(_ delta: Double, sharedTime: Double) {
        if joined { time = sharedTime; return }
        guard playing else { return }
        let next = time + delta * rate
        if next.isFinite { time = next.truncatingRemainder(dividingBy: descriptor.duration) }
    }

    mutating func apply(_ values: [String: Any], sharedTime: Double) {
        let action = values["action"] as? String
        if action == "join" { joined = true; playing = true; rate = 1; time = sharedTime; return }
        joined = false
        switch action {
        case "play": playing = true
        case "pause": playing = false
        case "stop": playing = false; time = 0
        case "setFrame":
            if let frame = values["frame"] as? Double, frame.isFinite { time = descriptor.time(atFrame: frame) }
        case "rate":
            if let rate = values["rate"] as? Double, rate.isFinite { self.rate = rate }
        default: break
        }
    }

    var snapshot: [String: Any] {
        ["time":time, "frame":descriptor.frame(at: time), "rate":rate, "playing":playing, "joined":joined]
    }
}
