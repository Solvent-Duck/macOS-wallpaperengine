import Foundation
import NativeSceneCore

public struct AudioInputState: Codable, Equatable, Sendable {
    public let overall: Double
    public let bass: Double
    public let mid: Double
    public let treble: Double

    public init(overall: Double = 0, bass: Double = 0, mid: Double = 0, treble: Double = 0) {
        self.overall = overall
        self.bass = bass
        self.mid = mid
        self.treble = treble
    }

    public static let silent = AudioInputState()
}

public struct PropertyEvaluationContext: Sendable {
    public let elapsedTime: Double
    public let deltaTime: Double
    public let frameIndex: UInt64
    public let cursorPosition: RuntimeVector2?
    public let propertyOverrides: [String: FrameValue]
    public let audio: AudioInputState

    public init(
        elapsedTime: Double,
        deltaTime: Double,
        frameIndex: UInt64,
        cursorPosition: RuntimeVector2? = nil,
        propertyOverrides: [String: FrameValue] = [:],
        audio: AudioInputState = .silent
    ) {
        self.elapsedTime = elapsedTime
        self.deltaTime = deltaTime
        self.frameIndex = frameIndex
        self.cursorPosition = cursorPosition
        self.propertyOverrides = propertyOverrides
        self.audio = audio
    }
}

public enum RuntimeValueSource: String, Codable, Sendable {
    case propertyOverride
    case defaultProperty
    case literal
    case scripted
    case condition
}

public struct EvaluatedSetting: Codable, Equatable, Sendable {
    public let value: FrameValue
    public let source: RuntimeValueSource
    public let conditionSatisfied: Bool
}

public struct PropertyEvaluator: Sendable {
    public let scene: SceneDescription
    public let context: PropertyEvaluationContext

    private let defaultProperties: [String: DynamicValueDescriptor]

    public init(scene: SceneDescription, context: PropertyEvaluationContext) {
        self.scene = scene
        self.context = context
        self.defaultProperties = Dictionary(
            uniqueKeysWithValues: scene.userProperties.compactMap { property in
                guard let defaultValue = property.defaultValue else {
                    return nil
                }
                return (property.key, defaultValue)
            }
        )
    }

    public func resolvedUserProperties() -> [String: FrameValue] {
        var resolved: [String: FrameValue] = [:]
        for property in scene.userProperties.sorted(by: { $0.order < $1.order }) {
            if let override = context.propertyOverrides[property.key] {
                resolved[property.key] = override
            } else if let descriptor = property.defaultValue {
                resolved[property.key] = evaluate(dynamicValue: descriptor)
            }
        }
        return resolved
    }

    public func evaluate(_ setting: UserSettingDescriptor?) -> EvaluatedSetting? {
        guard let setting else {
            return nil
        }

        let conditionSatisfied = setting.condition.map(evaluate(condition:)) ?? true
        let resolved = resolveSettingValue(setting)

        guard let value = resolved?.value ?? setting.condition.map({ _ in FrameValue.bool(conditionSatisfied) }) else {
            return nil
        }

        if case .bool(let boolValue) = value {
            return EvaluatedSetting(
                value: .bool(boolValue && conditionSatisfied),
                source: resolved?.source ?? .condition,
                conditionSatisfied: conditionSatisfied
            )
        }

        return EvaluatedSetting(
            value: value,
            source: resolved?.source ?? .literal,
            conditionSatisfied: conditionSatisfied
        )
    }

    public func boolValue(for setting: UserSettingDescriptor?, default defaultValue: Bool) -> Bool {
        evaluate(setting)?.value.boolValue ?? defaultValue
    }

    public func scalarDouble(for setting: UserSettingDescriptor?, default defaultValue: Double) -> Double {
        evaluate(setting)?.value.doubleValue ?? defaultValue
    }

    public func vector3Value(for setting: UserSettingDescriptor?, default defaultValue: RuntimeVector3) -> RuntimeVector3 {
        evaluate(setting)?.value.vector3Value ?? defaultValue
    }

    public func vector2Value(for setting: UserSettingDescriptor?, default defaultValue: RuntimeVector2) -> RuntimeVector2 {
        evaluate(setting)?.value.vector2Value ?? defaultValue
    }

    public func vector4Value(for setting: UserSettingDescriptor?, default defaultValue: RuntimeVector4) -> RuntimeVector4 {
        guard let value = evaluate(setting)?.value else {
            return defaultValue
        }

        switch value {
        case .vec4(let values):
            return RuntimeVector4(values, default: defaultValue)
        case .vec3(let values):
            let expanded = [values[safe: 0] ?? 0, values[safe: 1] ?? 0, values[safe: 2] ?? 0, Double(defaultValue.w)]
            return RuntimeVector4(expanded, default: defaultValue)
        case .ivec4(let values):
            return RuntimeVector4(values.map(Double.init), default: defaultValue)
        case .ivec3(let values):
            let expanded = [
                Double(values[safe: 0] ?? 0),
                Double(values[safe: 1] ?? 0),
                Double(values[safe: 2] ?? 0),
                Double(defaultValue.w),
            ]
            return RuntimeVector4(expanded, default: defaultValue)
        default:
            let scalar = value.doubleValue ?? 0
            return RuntimeVector4(x: Float(scalar), y: Float(scalar), z: Float(scalar), w: Float(scalar))
        }
    }

    public func evaluate(dynamicValue descriptor: DynamicValueDescriptor) -> FrameValue {
        switch descriptor.kind {
        case .static:
            return FrameValue(sceneValue: descriptor.value)
        case .scripted:
            let baseValue = descriptor.baseValue.map(evaluate(dynamicValue:)) ?? FrameValue(sceneValue: descriptor.value)
            let props = descriptor.scriptProperties.mapValues(evaluate(dynamicValue:))
            return evaluateScript(source: descriptor.scriptSource, baseValue: baseValue, properties: props)
        }
    }

    public func evaluate(condition: ConditionDescriptor) -> Bool {
        let actual = resolveIdentifier(condition.name, baseValue: nil, properties: [:])?.stringValue ?? ""
        let expected = condition.expression.trimmingCharacters(in: .whitespacesAndNewlines)

        if let expectedBool = parseBool(expected), let actualBool = parseBool(actual) {
            return actualBool == expectedBool
        }

        if let expectedDouble = Double(expected), let actualDouble = Double(actual) {
            return abs(actualDouble - expectedDouble) < 0.0001
        }

        return actual == expected
    }

    private func evaluateScript(source: String?, baseValue: FrameValue, properties: [String: FrameValue]) -> FrameValue {
        guard let source else {
            return baseValue
        }

        do {
            return try ScriptHost.shared.evaluate(source: source, baseValue: baseValue, properties: properties)
        } catch {
            print("[NativeSceneRuntime] Script evaluation failed: \(error.localizedDescription)")
            return baseValue
        }
    }

    private func resolveSettingValue(_ setting: UserSettingDescriptor) -> (value: FrameValue, source: RuntimeValueSource)? {
        if let descriptor = setting.value {
            return (
                evaluate(dynamicValue: descriptor),
                descriptor.kind == .scripted ? .scripted : .literal
            )
        }

        guard let propertyBinding = setting.propertyBinding else {
            return nil
        }

        if let override = context.propertyOverrides[propertyBinding] {
            return (override, .propertyOverride)
        }

        if let descriptor = defaultProperties[propertyBinding] {
            return (evaluate(dynamicValue: descriptor), .defaultProperty)
        }

        return nil
    }

    private func resolveIdentifier(_ token: String, baseValue: FrameValue?, properties: [String: FrameValue]) -> FrameValue? {
        switch token {
        case "value":
            return baseValue
        case "time", "elapsedTime":
            return .double(context.elapsedTime)
        case "deltaTime":
            return .double(context.deltaTime)
        case "frame":
            return .int(Int(context.frameIndex))
        case "cursorX", "mouseX":
            return .double(Double(context.cursorPosition?.x ?? 0))
        case "cursorY", "mouseY":
            return .double(Double(context.cursorPosition?.y ?? 0))
        case "cursor", "mouse":
            guard let cursorPosition = context.cursorPosition else {
                return nil
            }
            return .vec2([Double(cursorPosition.x), Double(cursorPosition.y)])
        case "audioPeak":
            return .double(context.audio.overall)
        case "audioBass":
            return .double(context.audio.bass)
        case "audioMid":
            return .double(context.audio.mid)
        case "audioTreble":
            return .double(context.audio.treble)
        default:
            if let property = properties[token] {
                return property
            }
            if let override = context.propertyOverrides[token] {
                return override
            }
            if let descriptor = defaultProperties[token] {
                return evaluate(dynamicValue: descriptor)
            }
            return nil
        }
    }

    private func parseBool(_ token: String) -> Bool? {
        switch token.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
