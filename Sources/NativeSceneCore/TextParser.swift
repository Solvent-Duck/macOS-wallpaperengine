import Foundation

public struct TextDescriptor: Codable, Equatable, Sendable {
    public let scale: UserSettingDescriptor?
    public let angles: UserSettingDescriptor?
    public let visible: UserSettingDescriptor?
    public let alpha: UserSettingDescriptor?
    public let color: UserSettingDescriptor?
    public let content: UserSettingDescriptor?
    public let backgroundColor: UserSettingDescriptor?
    public let parallaxDepth: UserSettingDescriptor?
    public let anchor: String
    public let backgroundBrightness: Double
    public let blockAlign: Bool
    public let castShadow: Bool
    public let depthTest: String
    public let fontPath: String
    public let horizontalAlign: String
    public let limitRows: Bool
    public let limitUseEllipsis: Bool
    public let limitWidth: Bool
    public let lockTransforms: Bool
    public let maxRows: Int
    public let maxWidth: Double
    public let opaqueBackground: Bool
    public let padding: Int
    public let pointSize: UserSettingDescriptor?
    public let size: [Double]
    public let verticalAlign: String
    public let effects: [ImageEffectDescriptor]
    /// Live style bindings. Optional for descriptions serialized before these
    /// properties participated in SceneScript and user-property evaluation.
    public let styleSettings: [String: UserSettingDescriptor]?

    public func resolvedStyleSettings(ownerID: String) -> [String: UserSettingDescriptor] {
        let defaults: [String: SceneValue] = [
            "font": .string(fontPath), "padding": .int(padding),
            "horizontalalign": .string(horizontalAlign), "verticalalign": .string(verticalAlign),
            "limitwidth": .bool(limitWidth), "maxwidth": .float(maxWidth),
            "limitrows": .bool(limitRows), "maxrows": .int(maxRows),
            "limituseellipsis": .bool(limitUseEllipsis), "blockalign": .bool(blockAlign),
            "castshadow": .bool(castShadow), "opaquebackground": .bool(opaqueBackground),
        ]
        return defaults.reduce(into: [:]) { result, entry in
            result[entry.key] = styleSettings?[entry.key] ?? UserSettingDescriptor(
                value: DynamicValueDescriptor(kind: .static, value: entry.value),
                propertyName: "", condition: nil, runtimeKey: "\(ownerID).\(entry.key)")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case scale
        case angles
        case visible
        case alpha
        case color
        case content
        case backgroundColor
        case parallaxDepth
        case anchor
        case backgroundBrightness
        case blockAlign
        case castShadow
        case depthTest
        case fontPath = "font"
        case horizontalAlign
        case limitRows
        case limitUseEllipsis
        case limitWidth
        case lockTransforms
        case maxRows
        case maxWidth
        case opaqueBackground
        case padding
        case pointSize
        case size
        case verticalAlign
        case effects
        case styleSettings
    }
}
