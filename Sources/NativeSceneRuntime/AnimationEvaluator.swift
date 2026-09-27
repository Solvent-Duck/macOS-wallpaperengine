import Foundation
import NativeSceneCore

public struct AnimationState: Codable, Equatable, Sendable {
    public let layers: [AnimationLayerFrame]
    public let keepsNodeVisible: Bool

    public static let empty = AnimationState(layers: [], keepsNodeVisible: true)
}

public enum AnimationEvaluator {
    public static func sample(
        from start: FrameValue,
        to end: FrameValue,
        progress: Double
    ) -> FrameValue {
        let clamped = min(max(progress, 0), 1)

        switch (start, end) {
        case (.double(let lhs), .double(let rhs)):
            return .double(lhs + (rhs - lhs) * clamped)
        case (.int(let lhs), .int(let rhs)):
            return .int(Int((Double(lhs) + (Double(rhs - lhs) * clamped)).rounded()))
        case (.vec2(let lhs), .vec2(let rhs)):
            return .vec2(zip(lhs, rhs).map { $0 + (($1 - $0) * clamped) })
        case (.vec3(let lhs), .vec3(let rhs)):
            return .vec3(zip(lhs, rhs).map { $0 + (($1 - $0) * clamped) })
        case (.vec4(let lhs), .vec4(let rhs)):
            return .vec4(zip(lhs, rhs).map { $0 + (($1 - $0) * clamped) })
        default:
            return clamped < 0.5 ? start : end
        }
    }

    public static func evaluate(
        node: NodeDescriptor,
        elapsedTime: Double,
        propertyEvaluator: PropertyEvaluator
    ) -> AnimationState {
        guard let image = node.image, !image.animationLayers.isEmpty else {
            return .empty
        }

        let layers = image.animationLayers.enumerated().map { index, layer in
            let visible = propertyEvaluator.boolValue(for: layer.visible, default: true)
            let rate = propertyEvaluator.scalarDouble(for: layer.rateSetting, default: layer.rate)
            let blend = propertyEvaluator.scalarDouble(for: layer.blendSetting, default: layer.blend)
            let playback = propertyEvaluator.context.scriptHost?.skeletalAnimationFrame(nodeID: node.id, layerIndex: index)
            let phase = playback?.progress ?? normalizedPhase(elapsedTime: elapsedTime, rate: rate)
            return AnimationLayerFrame(
                id: layer.id,
                animation: layer.animation,
                progress: phase,
                rate: rate,
                blend: blend,
                visible: visible,
                sampleFrame: playback?.frame
            )
        }

        // Animation visibility controls whether a clip contributes a pose.
        // It does not hide the image carrying the puppet or model.
        return AnimationState(layers: layers, keepsNodeVisible: true)
    }

    private static func normalizedPhase(elapsedTime: Double, rate: Double) -> Double {
        guard rate != 0 else {
            return 0
        }

        let phase = elapsedTime * rate
        return phase - floor(phase)
    }
}
