import Foundation

public struct NodeID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SceneProjectType: String, Codable, Sendable {
    case scene
    case web
    case video
    case unknown
}

public enum NodeKind: String, Codable, Sendable {
    case image
    case sound
    case light
    case particle
    case text
    case group
    case unknown
}

public enum UserPropertyKind: String, Codable, Sendable {
    case slider
    case bool
    case color
    case combo
    case text
    case textinput
    case file
    case scenetexture
    case unknown
}

public enum DynamicValueKind: String, Codable, Sendable {
    case `static`
    case scripted
    case animated
}

public enum SceneValue: Equatable, Sendable {
    case null
    case float(Double)
    case int(Int)
    case bool(Bool)
    case string(String)
    case vec2([Double])
    case vec3([Double])
    case vec4([Double])
    case ivec2([Int])
    case ivec3([Int])
    case ivec4([Int])
}

public final class DynamicValueDescriptor: Codable, Equatable, @unchecked Sendable {
    public let kind: DynamicValueKind
    public let value: SceneValue
    public let scriptSource: String?
    public let baseValue: DynamicValueDescriptor?
    public let scriptProperties: [String: DynamicValueDescriptor]
    public let scriptPropertySettings: [String: UserSettingDescriptor]
    public let animation: PropertyAnimationDescriptor?

    public init(
        kind: DynamicValueKind,
        value: SceneValue,
        scriptSource: String? = nil,
        baseValue: DynamicValueDescriptor? = nil,
        scriptProperties: [String: DynamicValueDescriptor] = [:],
        animation: PropertyAnimationDescriptor? = nil,
        scriptPropertySettings: [String: UserSettingDescriptor] = [:]
    ) {
        self.kind = kind
        self.value = value
        // Sources parsed by JSONSerialization arrive as bridged NSStrings, and
        // the script host hashes and C-string-copies them every frame. Store
        // native UTF-8 so those operations take the fast path.
        self.scriptSource = scriptSource.map { source in
            var native = source
            native.makeContiguousUTF8()
            return native
        }
        self.baseValue = baseValue
        self.scriptProperties = scriptProperties
        self.animation = animation
        self.scriptPropertySettings = scriptPropertySettings
    }

    public static func == (lhs: DynamicValueDescriptor, rhs: DynamicValueDescriptor) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.value == rhs.value &&
        lhs.scriptSource == rhs.scriptSource &&
        lhs.baseValue == rhs.baseValue &&
        lhs.scriptProperties == rhs.scriptProperties &&
        lhs.scriptPropertySettings == rhs.scriptPropertySettings &&
        lhs.animation == rhs.animation
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case valueType
        case value
        case scriptSource
        case baseValue
        case scriptProperties
        case scriptPropertySettings
        case animation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DynamicValueKind.self, forKey: .kind)
        animation = try container.decodeIfPresent(PropertyAnimationDescriptor.self, forKey: .animation)
        scriptPropertySettings = try container.decodeIfPresent([String: UserSettingDescriptor].self, forKey: .scriptPropertySettings) ?? [:]
        let valueType = try container.decode(String.self, forKey: .valueType)

        if try container.decodeNil(forKey: .value) {
            value = .null
            scriptSource = try container.decodeIfPresent(String.self, forKey: .scriptSource)
            baseValue = try container.decodeIfPresent(DynamicValueDescriptor.self, forKey: .baseValue)
            scriptProperties = try container.decodeIfPresent([String: DynamicValueDescriptor].self, forKey: .scriptProperties) ?? [:]
            return
        }

        switch valueType {
        case "null":
            value = .null
        case "float":
            value = .float(try container.decode(Double.self, forKey: .value))
        case "int":
            value = .int(try container.decode(Int.self, forKey: .value))
        case "bool":
            value = .bool(try container.decode(Bool.self, forKey: .value))
        case "string":
            value = .string(try container.decode(String.self, forKey: .value))
        case "vec2":
            value = .vec2(try container.decode([Double].self, forKey: .value))
        case "vec3":
            value = .vec3(try container.decode([Double].self, forKey: .value))
        case "vec4":
            value = .vec4(try container.decode([Double].self, forKey: .value))
        case "ivec2":
            value = .ivec2(try container.decode([Int].self, forKey: .value))
        case "ivec3":
            value = .ivec3(try container.decode([Int].self, forKey: .value))
        case "ivec4":
            value = .ivec4(try container.decode([Int].self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .valueType,
                in: container,
                debugDescription: "Unsupported dynamic value type: \(valueType)"
            )
        }

        scriptSource = try container.decodeIfPresent(String.self, forKey: .scriptSource)
        baseValue = try container.decodeIfPresent(DynamicValueDescriptor.self, forKey: .baseValue)
        scriptProperties = try container.decodeIfPresent([String: DynamicValueDescriptor].self, forKey: .scriptProperties) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !scriptPropertySettings.isEmpty { try container.encode(scriptPropertySettings, forKey: .scriptPropertySettings) }
        try container.encode(kind, forKey: .kind)
        switch value {
        case .null:
            try container.encode("null", forKey: .valueType)
            try container.encodeNil(forKey: .value)
        case .float(let scalar):
            try container.encode("float", forKey: .valueType)
            try container.encode(scalar, forKey: .value)
        case .int(let scalar):
            try container.encode("int", forKey: .valueType)
            try container.encode(scalar, forKey: .value)
        case .bool(let scalar):
            try container.encode("bool", forKey: .valueType)
            try container.encode(scalar, forKey: .value)
        case .string(let scalar):
            try container.encode("string", forKey: .valueType)
            try container.encode(scalar, forKey: .value)
        case .vec2(let values):
            try container.encode("vec2", forKey: .valueType)
            try container.encode(values, forKey: .value)
        case .vec3(let values):
            try container.encode("vec3", forKey: .valueType)
            try container.encode(values, forKey: .value)
        case .vec4(let values):
            try container.encode("vec4", forKey: .valueType)
            try container.encode(values, forKey: .value)
        case .ivec2(let values):
            try container.encode("ivec2", forKey: .valueType)
            try container.encode(values, forKey: .value)
        case .ivec3(let values):
            try container.encode("ivec3", forKey: .valueType)
            try container.encode(values, forKey: .value)
        case .ivec4(let values):
            try container.encode("ivec4", forKey: .valueType)
            try container.encode(values, forKey: .value)
        }
        try container.encodeIfPresent(scriptSource, forKey: .scriptSource)
        try container.encodeIfPresent(baseValue, forKey: .baseValue)
        try container.encodeIfPresent(animation, forKey: .animation)
        if !scriptProperties.isEmpty {
            try container.encode(scriptProperties, forKey: .scriptProperties)
        }
    }
}

public struct ConditionDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let expression: String
}

public struct UserSettingDescriptor: Codable, Equatable, Sendable {
    public let value: DynamicValueDescriptor?
    public let propertyName: String
    public let condition: ConditionDescriptor?
    public let runtimeKey: String?

    public init(value: DynamicValueDescriptor?, propertyName: String = "", condition: ConditionDescriptor? = nil, runtimeKey: String? = nil) {
        self.value = value
        self.propertyName = propertyName
        self.condition = condition
        self.runtimeKey = runtimeKey
    }

    public var propertyBinding: String? {
        propertyName.isEmpty ? nil : propertyName
    }
}

public struct IntSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }
}

public struct SceneMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let projectType: SceneProjectType
    public let workshopId: String
    public let supportsAudioProcessing: Bool
    public let schemaVersion: Int
    public let wallpaperFile: String
    public let defaultResolution: IntSize?
}

public struct UserPropertyOption: Codable, Equatable, Sendable {
    public let value: String
    public let label: String
}

public struct UserProperty: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let order: Int
    public let type: UserPropertyKind
    public let defaultValue: DynamicValueDescriptor?
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let precision: Int?
    public let options: [UserPropertyOption]

    private enum CodingKeys: String, CodingKey {
        case key
        case label
        case order
        case type
        case defaultValue
        case minimum
        case maximum
        case step
        case precision
        case options
    }

    public init(
        key: String,
        label: String,
        order: Int,
        type: UserPropertyKind,
        defaultValue: DynamicValueDescriptor?,
        minimum: Double?,
        maximum: Double?,
        step: Double?,
        precision: Int?,
        options: [UserPropertyOption]
    ) {
        self.key = key
        self.label = label
        self.order = order
        self.type = type
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.precision = precision
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decode(String.self, forKey: .label)
        order = try container.decode(Int.self, forKey: .order)
        type = try container.decode(UserPropertyKind.self, forKey: .type)
        defaultValue = try container.decodeIfPresent(DynamicValueDescriptor.self, forKey: .defaultValue)
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        step = try container.decodeIfPresent(Double.self, forKey: .step)
        precision = try container.decodeIfPresent(Int.self, forKey: .precision)
        options = try container.decodeIfPresent([UserPropertyOption].self, forKey: .options) ?? []
    }
}

public struct ShaderReference: Codable, Equatable, Sendable {
    public let path: String
}

public struct TextureReference: Codable, Equatable, Sendable {
    public let slot: Int
    public let path: String
    /// Named user/system binding category; absent for literal asset paths.
    public var sourceType: String? = nil
}

public struct PassDescriptor: Codable, Equatable, Sendable {
    public let blending: Int
    public let culling: Int
    public let depthTest: Int
    public let depthWrite: Int
    public let shader: ShaderReference
    public let textures: [TextureReference]
    public let userTextures: [TextureReference]
    public let combos: [String: Int]
    public let constants: [String: UserSettingDescriptor]
}

public struct MaterialDescriptor: Codable, Equatable, Sendable {
    public let filename: String
    public let passes: [PassDescriptor]
}

public struct FBODescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let format: String
    public let scale: Double
    public let unique: Bool
}

public struct EffectPassDescriptor: Codable, Equatable, Sendable {
    public let material: MaterialDescriptor?
    public let binds: [TextureReference]
    public let command: Int
    public let source: String?
    public let target: String?
}

public struct EffectDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let group: String
    public let preview: String
    public let dependencies: [String]
    public let passes: [EffectPassDescriptor]
    public let fbos: [FBODescriptor]
}

public struct EffectOverridePassDescriptor: Codable, Equatable, Sendable {
    public let id: Int
    public let combos: [String: Int]
    public let constants: [String: UserSettingDescriptor]
    public let textures: [TextureReference]
    public let userTextures: [TextureReference]
    public let shaderOverride: String?

    init(id: Int, combos: [String: Int], constants: [String: UserSettingDescriptor],
         textures: [TextureReference], userTextures: [TextureReference] = [], shaderOverride: String?) {
        self.id = id
        self.combos = combos
        self.constants = constants
        self.textures = textures
        self.userTextures = userTextures
        self.shaderOverride = shaderOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, combos, constants, textures, userTextures, shaderOverride
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        combos = try values.decode([String: Int].self, forKey: .combos)
        constants = try values.decode([String: UserSettingDescriptor].self, forKey: .constants)
        textures = try values.decode([TextureReference].self, forKey: .textures)
        userTextures = try values.decodeIfPresent([TextureReference].self, forKey: .userTextures) ?? []
        shaderOverride = try values.decodeIfPresent(String.self, forKey: .shaderOverride)
    }
}

public struct ImageEffectDescriptor: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let visible: UserSettingDescriptor?
    public let passOverrides: [EffectOverridePassDescriptor]
    public let effect: EffectDescriptor?
}

public struct AnimationLayerDescriptor: Codable, Equatable, Sendable {
    public let id: Int
    public let rate: Double
    public let visible: UserSettingDescriptor?
    public let blend: Double
    public let animation: Int
    public let name: String?
    public let rateSetting: UserSettingDescriptor
    public let blendSetting: UserSettingDescriptor

    private enum CodingKeys: String, CodingKey {
        case id, rate, visible, blend, animation, name, rateSetting, blendSetting
    }
}

extension AnimationLayerDescriptor {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        rate = try values.decode(Double.self, forKey: .rate)
        visible = try values.decodeIfPresent(UserSettingDescriptor.self, forKey: .visible)
        blend = try values.decode(Double.self, forKey: .blend)
        animation = try values.decode(Int.self, forKey: .animation)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        rateSetting = try values.decodeIfPresent(UserSettingDescriptor.self, forKey: .rateSetting)
            ?? UserSettingDescriptor(value: DynamicValueDescriptor(kind: .static, value: .float(rate)),
                                     propertyName: "", condition: nil, runtimeKey: nil)
        blendSetting = try values.decodeIfPresent(UserSettingDescriptor.self, forKey: .blendSetting)
            ?? UserSettingDescriptor(value: DynamicValueDescriptor(kind: .static, value: .float(blend)),
                                     propertyName: "", condition: nil, runtimeKey: nil)
    }
}

public struct ModelDescriptor: Codable, Equatable, Sendable {
    public let filename: String
    public let material: MaterialDescriptor?
    public let solidLayer: Bool
    public let fullscreen: Bool
    public let passthrough: Bool
    public let autoSize: Bool
    public let noPadding: Bool
    public let width: Int?
    public let height: Int?
    public let puppet: String?
    public var meshMaterials: [MaterialDescriptor?]? = nil
}

public struct ImageDescriptor: Codable, Equatable, Sendable {
    public let scale: UserSettingDescriptor?
    public let angles: UserSettingDescriptor?
    public let visible: UserSettingDescriptor?
    public let alpha: UserSettingDescriptor?
    public let color: UserSettingDescriptor?
    public let alignment: String
    public let size: [Double]
    public let parallaxDepth: UserSettingDescriptor?
    public let colorBlendMode: Int
    public let brightness: Double
    public let model: ModelDescriptor?
    public let effects: [ImageEffectDescriptor]
    public let animationLayers: [AnimationLayerDescriptor]
    public var perspective: Bool? = nil
}

public struct SoundDescriptor: Codable, Equatable, Sendable {
    public let playbackMode: String?
    public let sounds: [String]
    /// Scalar retained for Codable compatibility; `volumeSetting` preserves authored bindings.
    public let volume: Double
    public let volumeSetting: UserSettingDescriptor?
    public let startSilent: Bool
    public let minTime: Double
    public let maxTime: Double

    public init(
        playbackMode: String?,
        sounds: [String],
        volume: Double = 1,
        volumeSetting: UserSettingDescriptor? = nil,
        startSilent: Bool = false,
        minTime: Double = 0,
        maxTime: Double = 0
    ) {
        self.playbackMode = playbackMode
        self.sounds = sounds
        self.volume = volume
        self.volumeSetting = volumeSetting
        self.startSilent = startSilent
        self.minTime = minTime
        self.maxTime = maxTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playbackMode = try container.decodeIfPresent(String.self, forKey: .playbackMode)
        sounds = try container.decodeIfPresent([String].self, forKey: .sounds) ?? []
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        volumeSetting = try container.decodeIfPresent(UserSettingDescriptor.self, forKey: .volumeSetting)
        startSilent = try container.decodeIfPresent(Bool.self, forKey: .startSilent) ?? false
        minTime = try container.decodeIfPresent(Double.self, forKey: .minTime) ?? 0
        maxTime = try container.decodeIfPresent(Double.self, forKey: .maxTime) ?? 0
    }
}

public struct LightDescriptor: Codable, Equatable, Sendable {
    public let lightType: Int
    public let visible: UserSettingDescriptor?
    public let angles: UserSettingDescriptor?
    public let scale: UserSettingDescriptor?
    public let color: UserSettingDescriptor?
    public let intensity: UserSettingDescriptor?
    public let radius: UserSettingDescriptor?
    public let length: UserSettingDescriptor?
    /// Tube endpoint in the light's local coordinate system.
    public let controlPoint: UserSettingDescriptor?
    public let innerCone: UserSettingDescriptor?
    public let outerCone: UserSettingDescriptor?
    public let castsShadow: Bool
    public var exponent: UserSettingDescriptor? = nil
}

public struct ParticleEmitterDescriptor: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let directions: [Double]
    public let distanceMin: [Double]
    public let distanceMax: [Double]
    public let origin: [Double]
    public let sign: [Int]
    public let instantaneous: UInt32
    public let speedMin: Double
    public let speedMax: Double
    public let rate: Double
    public let controlPoint: Int
    public let flags: UInt32
    public let cone: Double
    public let delay: Double
    public let duration: Double
    public let audioProcessingBounds: [Double]
    public let audioProcessingExponent: Int
    public let audioProcessingFrequencyStart: Int
    public let audioProcessingFrequencyEnd: Int
    public let audioProcessingMode: Int
    public let minPeriodicDelay: Double
    public let maxPeriodicDelay: Double
    public let minPeriodicDuration: Double
    public let maxPeriodicDuration: Double
}

public struct ParticleInitializerDescriptor: Codable, Equatable, Sendable {
    public let kind: String
    public let parameters: [String: UserSettingDescriptor]
}

public struct ParticleOperatorDescriptor: Codable, Equatable, Sendable {
    public let kind: String
    public let controlPoint: Int?
    public let flags: Int?
    public let parameters: [String: UserSettingDescriptor]
}

public struct ParticleRendererDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let length: Double
    public let maxLength: Double
    public let minLength: Double
    public let subdivision: Double
    public let segments: Double
    public let uvScale: Double
    public let uvScrolling: Bool
    public let uvSmoothing: Bool
    public let fadeAlpha: Bool
    public let fadeSize: Bool
}

public struct ParticleControlPointDescriptor: Codable, Equatable, Sendable {
    public let id: Int
    public let flags: UInt32
    public let offset: [Double]
    public let lockToPointer: Bool
    public let offsetSetting: UserSettingDescriptor?

    /// Older serialized descriptions retain their literal offset and acquire
    /// the same writable runtime binding as newly loaded scene files.
    public func offsetProperty(runtimeKey: String) -> UserSettingDescriptor {
        offsetSetting ?? UserSettingDescriptor(
            value: DynamicValueDescriptor(kind: .static, value: .vec3(offset)),
            propertyName: "", condition: nil, runtimeKey: runtimeKey)
    }
}

public struct ParticleChildDescriptor: Codable, Equatable, Sendable {
    public let type: String
    public let name: String
    public let maxCount: Int
    public let controlPointStartIndex: Int
    public let probability: Double
    public let angles: [Double]
    public let origin: [Double]
    public let scale: [Double]
    public let particleFile: String
    /// Resolved definition of the child system (0 or 1 elements; array-boxed
    /// because Swift forbids direct recursive struct storage through Optional).
    public let particle: [ParticleDescriptor]
}

public struct ParticleInstanceOverrideDescriptor: Codable, Equatable, Sendable {
    public let enabled: UserSettingDescriptor?
    public let alpha: UserSettingDescriptor?
    public let size: UserSettingDescriptor?
    public let lifetime: UserSettingDescriptor?
    public let rate: UserSettingDescriptor?
    public let speed: UserSettingDescriptor?
    public let count: UserSettingDescriptor?
    public let color: UserSettingDescriptor?
    public let colorn: UserSettingDescriptor?
}

public struct ParticleDescriptor: Codable, Equatable, Sendable {
    public let scale: UserSettingDescriptor?
    public let angles: UserSettingDescriptor?
    public let visible: UserSettingDescriptor?
    public let parallaxDepth: UserSettingDescriptor?
    public let particleFile: String
    public let animationMode: String
    public let sequenceMultiplier: Double
    public let maxCount: UInt32
    public let startTime: UInt32
    public let flags: UInt32
    public let material: ModelDescriptor?
    public let emitters: [ParticleEmitterDescriptor]
    public let initializers: [ParticleInitializerDescriptor]
    public let operators: [ParticleOperatorDescriptor]
    public let renderers: [ParticleRendererDescriptor]
    public let controlPoints: [ParticleControlPointDescriptor]
    public let children: [ParticleChildDescriptor]
    public let instanceOverride: ParticleInstanceOverrideDescriptor

    /// Every system exposes eight control points, even when the asset omits
    /// their default editor records. Ignore invalid IDs and keep the first
    /// authored record for a duplicate ID, matching runtime resolution.
    public var instanceControlPoints: [ParticleControlPointDescriptor] {
        if controlPoints.count == 8 && controlPoints.enumerated().allSatisfy({ $0.offset == $0.element.id }) {
            return controlPoints
        }
        return (0..<8).map { id in
            controlPoints.first { $0.id == id } ?? ParticleControlPointDescriptor(
                id: id, flags: 0, offset: [0, 0, 0], lockToPointer: false, offsetSetting: nil)
        }
    }
}

public struct GroupDescriptor: Codable, Equatable, Sendable {
    public let scale: UserSettingDescriptor?
    public let angles: UserSettingDescriptor?
    public let visible: UserSettingDescriptor?
}

public enum AttachmentReference: Codable, Equatable, Sendable {
    case name(String)
    case index(Int)
}

public struct NodeDescriptor: Codable, Equatable, Sendable {
    public let id: NodeID
    public let name: String
    public let parentId: NodeID?
    public let attachment: AttachmentReference?
    public let dependencyIds: [NodeID]
    public let origin: UserSettingDescriptor?
    public let kind: NodeKind
    public let image: ImageDescriptor?
    public let sound: SoundDescriptor?
    public let light: LightDescriptor?
    public let particle: ParticleDescriptor?
    public let text: TextDescriptor?
    public let group: GroupDescriptor?
    /// Authored cursor interaction flag, distinct from a solid-color model.
    public var solid: Bool? = nil
}

public struct CameraBloomDescriptor: Codable, Equatable, Sendable {
    public let enabled: UserSettingDescriptor?
    public let strength: UserSettingDescriptor?
    public let threshold: UserSettingDescriptor?
}

public struct CameraParallaxDescriptor: Codable, Equatable, Sendable {
    public let enabled: UserSettingDescriptor?
    public let amount: UserSettingDescriptor?
    public let delay: UserSettingDescriptor?
    public let mouseInfluence: UserSettingDescriptor?
}

public struct CameraShakeDescriptor: Codable, Equatable, Sendable {
    public let enabled: UserSettingDescriptor?
    public let amplitude: UserSettingDescriptor?
    public let roughness: UserSettingDescriptor?
    public let speed: UserSettingDescriptor?
}

public struct CameraConfigurationDescriptor: Codable, Equatable, Sendable {
    public let center: [Double]
    public let eye: [Double]
    public let up: [Double]
}

public struct CameraProjectionDescriptor: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isAuto: Bool
    public let nearZ: Double
    public let farZ: Double
    public let fov: Double
    public var isPerspective: Bool? = nil
    public var perspectiveOverrideFOV: Double? = nil
}

public struct CameraDescriptor: Codable, Equatable, Sendable {
    public let fade: Bool
    public let preview: Bool
    public let bloom: CameraBloomDescriptor
    public let parallax: CameraParallaxDescriptor
    public let shake: CameraShakeDescriptor
    public let configuration: CameraConfigurationDescriptor
    public let projection: CameraProjectionDescriptor
    /// Relative magnification of the 2D camera; absent in older serialized scenes.
    public var zoom: UserSettingDescriptor? = nil
}

public struct SceneGraph: Codable, Equatable, Sendable {
    public let ambientColor: [Double]
    public let skylightColor: [Double]
    public let clearColor: UserSettingDescriptor?
    public let camera: CameraDescriptor
    public let nodes: [NodeDescriptor]
}

public struct SceneDescription: Equatable, Sendable {
    public let metadata: SceneMetadata
    public let userProperties: [UserProperty]
    public let scene: SceneGraph?
    public let extractedRoots: [URL]
    private var packageLease: ScenePackageLease?

    public init(
        metadata: SceneMetadata,
        userProperties: [UserProperty],
        scene: SceneGraph?,
        extractedRoots: [URL] = []
    ) {
        self.metadata = metadata
        self.userProperties = userProperties
        self.scene = scene
        self.extractedRoots = extractedRoots
        self.packageLease = nil
    }

    public var nodes: [NodeDescriptor] {
        scene?.nodes ?? []
    }

    /// A runtime graph shares its original camera, properties and package lease.
    public func replacingNodes(_ nodes: [NodeDescriptor]) -> SceneDescription {
        guard let scene else { return self }
        var result = SceneDescription(metadata: metadata, userProperties: userProperties,
            scene: SceneGraph(ambientColor: scene.ambientColor, skylightColor: scene.skylightColor,
                clearColor: scene.clearColor, camera: scene.camera, nodes: nodes), extractedRoots: extractedRoots)
        result.packageLease = packageLease
        return result
    }

    func retainingPackages(_ lease: ScenePackageLease) -> SceneDescription {
        var result = self
        result.packageLease = lease
        return result
    }

    public static func == (lhs: SceneDescription, rhs: SceneDescription) -> Bool {
        lhs.metadata == rhs.metadata && lhs.userProperties == rhs.userProperties &&
        lhs.scene == rhs.scene && lhs.extractedRoots == rhs.extractedRoots
    }
}

extension SceneDescription: Codable {
    private enum CodingKeys: String, CodingKey {
        case metadata
        case userProperties
        case scene
        case extractedRoots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(SceneMetadata.self, forKey: .metadata)
        userProperties = try container.decode([UserProperty].self, forKey: .userProperties)
        scene = try container.decodeIfPresent(SceneGraph.self, forKey: .scene)
        extractedRoots = try container.decodeIfPresent([URL].self, forKey: .extractedRoots) ?? []
        packageLease = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(userProperties, forKey: .userProperties)
        try container.encodeIfPresent(scene, forKey: .scene)
        if !extractedRoots.isEmpty {
            try container.encode(extractedRoots, forKey: .extractedRoots)
        }
    }
}
