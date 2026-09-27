import Foundation
import NativeSceneCore

public struct AudioInputState: Codable, Equatable, Sendable {
    public let overall: Double
    public let bass: Double
    public let mid: Double
    public let treble: Double
    /// Full 128-band normalized spectrum (Wallpaper Engine band layout);
    /// empty when no audio capture is active.
    public let spectrum: [Float]

    public init(
        overall: Double = 0,
        bass: Double = 0,
        mid: Double = 0,
        treble: Double = 0,
        spectrum: [Float] = []
    ) {
        self.overall = overall
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.spectrum = spectrum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overall = try container.decodeIfPresent(Double.self, forKey: .overall) ?? 0
        bass = try container.decodeIfPresent(Double.self, forKey: .bass) ?? 0
        mid = try container.decodeIfPresent(Double.self, forKey: .mid) ?? 0
        treble = try container.decodeIfPresent(Double.self, forKey: .treble) ?? 0
        spectrum = try container.decodeIfPresent([Float].self, forKey: .spectrum) ?? []
    }

    public static let silent = AudioInputState()
}

public struct PropertyEvaluationContext: Sendable {
    public let elapsedTime: Double
    public let deltaTime: Double
    public let frameIndex: UInt64
    public let cursorPosition: RuntimeVector2?
    public let cursorLeftDown: Bool
    public let cursorEvents: [CursorInputSample]
    public let resetCursorEvents: Bool
    public let viewportSize: RuntimeVector2?
    public let propertyOverrides: [String: FrameValue]
    public let runtimeOverrides: [String: FrameValue]
    public let audio: AudioInputState
    public let scriptHost: ScriptHost?
    public let isPaused: Bool
    public let scriptsEnabled: Bool

    public init(
        elapsedTime: Double,
        deltaTime: Double,
        frameIndex: UInt64,
        cursorPosition: RuntimeVector2? = nil,
        cursorLeftDown: Bool = false,
        cursorEvents: [CursorInputSample] = [],
        resetCursorEvents: Bool = false,
        viewportSize: RuntimeVector2? = nil,
        propertyOverrides: [String: FrameValue] = [:],
        runtimeOverrides: [String: FrameValue] = [:],
        audio: AudioInputState = .silent,
        scriptHost: ScriptHost? = nil,
        isPaused: Bool = false,
        scriptsEnabled: Bool = true
    ) {
        self.elapsedTime = elapsedTime
        self.deltaTime = deltaTime
        self.frameIndex = frameIndex
        self.cursorPosition = cursorPosition
        self.cursorLeftDown = cursorLeftDown
        self.cursorEvents = cursorEvents
        self.resetCursorEvents = resetCursorEvents
        self.viewportSize = viewportSize
        self.propertyOverrides = propertyOverrides
        self.runtimeOverrides = runtimeOverrides
        self.audio = audio
        self.scriptHost = scriptHost
        self.isPaused = isPaused
        self.scriptsEnabled = scriptsEnabled
    }
}

public enum RuntimeValueSource: String, Codable, Sendable {
    case propertyOverride
    case defaultProperty
    case literal
    case scripted
    case animated
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
    private let staticUserProperties: SceneScriptUserProperties?

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
        // Project properties normally contain literal editor values. Resolve
        // those once for this immutable context, rather than for every script.
        // Dynamic defaults retain the normal evaluation path below.
        if scene.userProperties.allSatisfy({ context.propertyOverrides[$0.key] != nil || $0.defaultValue?.kind != .scripted && $0.defaultValue?.kind != .animated }) {
            self.staticUserProperties = SceneScriptUserProperties(scene.userProperties.reduce(into: [:]) { result, property in
                result[property.key] = context.propertyOverrides[property.key]
                    ?? property.defaultValue.map { FrameValue(sceneValue: $0.value) }
            })
        } else {
            self.staticUserProperties = nil
        }
    }

    public func resolvedUserProperties() -> [String: FrameValue] {
        if let staticUserProperties { return staticUserProperties.values }
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
            // A combo association computes a boolean from the selected option;
            // its saved false value is only the editor's last selection.
            // An explicit layer write is already the final property value.
            // Reapplying the association would hide script-selected layers
            // whenever an automatic controller differs from the manual option.
            let hasExplicitWrite = setting.condition != nil && context.scriptHost?.sceneOverride(for: setting) != nil
            let effective = FrameValue.bool(hasExplicitWrite ? boolValue
                : setting.condition != nil && resolved?.source != .scripted ? conditionSatisfied
                : boolValue && conditionSatisfied)
            if context.scriptsEnabled { context.scriptHost?.publishSceneValue(effective, for: setting) }
            return EvaluatedSetting(
                value: effective,
                source: resolved?.source ?? .condition,
                conditionSatisfied: conditionSatisfied
            )
        }

        if context.scriptsEnabled { context.scriptHost?.publishSceneValue(value, for: setting) }
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
        case .animated:
            let base = FrameValue(sceneValue: descriptor.value)
            guard let animation = descriptor.animation else { return base }
            if let value = context.scriptHost?.animationValue(for: descriptor, base: base) { return value }
            return PropertyAnimationEvaluator.evaluate(animation, base: base, elapsedTime: context.elapsedTime)
        case .scripted:
            return evaluateScriptedValue(descriptor)
        }
    }

    private func evaluateScriptedValue(_ descriptor: DynamicValueDescriptor, baseOverride: FrameValue? = nil) -> FrameValue {
        let base = baseOverride ?? descriptor.baseValue.map(evaluate(dynamicValue:)) ?? FrameValue(sceneValue: descriptor.value)
        guard context.scriptsEnabled else { return base }
        var props = descriptor.scriptProperties.mapValues(evaluate(dynamicValue:))
        for (key, setting) in descriptor.scriptPropertySettings { props[key] = evaluate(setting)?.value }
        return evaluateScript(source: descriptor.scriptSource, baseValue: base, properties: props,
                              instanceID: String(describing: ObjectIdentifier(descriptor)), descriptor: descriptor)
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

    var screenSize: RuntimeVector2 {
        if let size = context.viewportSize, size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0 { return size }
        let projection = scene.scene?.camera.projection
        let width = projection?.width ?? 0, height = projection?.height ?? 0
        return RuntimeVector2(x: Float(width > 0 ? width : 1920), y: Float(height > 0 ? height : 1080))
    }

    var canvasSize: RuntimeVector2 {
        let size = SceneCameraGeometry.resolvedProjectionSize(scene: scene,
            viewportSize: CGSize(width: CGFloat(screenSize.x), height: CGFloat(screenSize.y)))
        return RuntimeVector2(x: Float(size.width), y: Float(size.height))
    }

    func cursorWorldPosition(_ normalized: RuntimeVector2) -> RuntimeVector2? {
        // Read the last published camera value without executing a zoom script
        // recursively while building that script's own input object.
        let zoom = scene.scene?.camera.zoom
        let published = zoom.flatMap { context.scriptHost?.publishedSceneValue(for: $0) }?.doubleValue
        func fallbackZoom() -> Double {
            let staticEvaluator = PropertyEvaluator(scene: scene, context: PropertyEvaluationContext(
                elapsedTime: context.elapsedTime, deltaTime: context.deltaTime, frameIndex: context.frameIndex,
                propertyOverrides: context.propertyOverrides, runtimeOverrides: context.runtimeOverrides,
                scriptHost: context.scriptHost, scriptsEnabled: false))
            return staticEvaluator.scalarDouble(for: zoom, default: 1)
        }
        return SceneCameraGeometry.worldPosition(normalized: normalized, scene: scene,
            viewportSize: CGSize(width: CGFloat(screenSize.x), height: CGFloat(screenSize.y)),
            cameraZoom: Float(published ?? fallbackZoom()))
    }

    var scriptInput: SceneScriptInputState {
        SceneScriptInputState(cursorPosition: context.cursorPosition,
            cursorWorldPosition: context.cursorPosition.flatMap(cursorWorldPosition),
            cursorScreenPosition: context.cursorPosition.map {
                RuntimeVector2(x: $0.x * screenSize.x, y: (1 - $0.y) * screenSize.y)
            }, cursorLeftDown: context.cursorLeftDown,
            cursorEvents: context.cursorEvents.map { sample in
                SceneScriptCursorEvent(position: sample.position,
                    worldPosition: cursorWorldPosition(sample.position) ?? .zero,
                    screenPosition: RuntimeVector2(x: sample.position.x * screenSize.x, y: (1 - sample.position.y) * screenSize.y),
                    leftDown: sample.leftDown)
            }, resetCursorEvents: context.resetCursorEvents)
    }

    private func evaluateScript(source: String?, baseValue: FrameValue, properties: [String: FrameValue], instanceID: String, descriptor: DynamicValueDescriptor) -> FrameValue {
        guard let source else {
            return baseValue
        }

        do {
            return try (context.scriptHost ?? ScriptHost.shared).evaluate(
                source: source,
                baseValue: baseValue,
                properties: properties,
                engine: SceneScriptEngineState(
                    runtime: context.elapsedTime,
                    screenResolution: screenSize,
                    canvasSize: canvasSize,
                    frametime: context.deltaTime,
                    frameIndex: context.frameIndex,
                    isPaused: context.isPaused
                ),
                input: scriptInput,
                audioSpectrum: context.audio.spectrum,
                instanceID: instanceID,
                userProperties: staticUserProperties ?? SceneScriptUserProperties(resolvedUserProperties()),
                descriptor: descriptor
            )
        } catch {
            let host = context.scriptHost ?? ScriptHost.shared
            host.reportFailure(error, instanceID: host.label(for: descriptor))
            return baseValue
        }
    }

    private func resolveSettingValue(_ setting: UserSettingDescriptor) -> (value: FrameValue, source: RuntimeValueSource)? {
        // Value scripts run once per frame even when another property script
        // has written their layer. Apply any writes after that evaluation.
        if context.scriptsEnabled, let descriptor = setting.value, descriptor.kind == .scripted {
            // A user binding supplies the script's input, rather than skipping
            // its module and lifecycle. Hidden user-controlled layers can
            // carry shared libraries needed by the rest of the scene.
            let value = evaluateScriptedValue(descriptor, baseOverride: boundUserValue(for: setting)?.value)
            return (context.scriptHost?.sceneOverride(for: setting) ?? value, .scripted)
        }
        if let override = context.scriptHost?.sceneOverride(for: setting) {
            return (override, .scripted)
        }
        if let runtimeKey = setting.runtimeKey,
           let override = context.runtimeOverrides[runtimeKey] {
            return (override, .scripted)
        }

        // A directly bound setting stores a snapshot in `value`; the user's
        // current property is authoritative. Conditional bindings instead
        // use the property only as a gate around the setting's own value.
        if let bound = boundUserValue(for: setting) { return bound }

        if let descriptor = setting.value {
            return (
                evaluate(dynamicValue: descriptor),
                descriptor.kind == .scripted ? .scripted : (descriptor.kind == .animated ? .animated : .literal)
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

    private func boundUserValue(for setting: UserSettingDescriptor) -> (value: FrameValue, source: RuntimeValueSource)? {
        guard setting.condition == nil, let name = setting.propertyBinding else { return nil }
        if let value = context.propertyOverrides[name] { return (value, .propertyOverride) }
        return defaultProperties[name].map { (evaluate(dynamicValue: $0), .defaultProperty) }
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
