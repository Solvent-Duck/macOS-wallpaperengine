import Foundation
import NativeSceneCore
import simd

public struct RuntimeVector2: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public init(_ values: [Double], default defaultValue: RuntimeVector2 = .zero) {
        self.x = Float(values[safe: 0] ?? Double(defaultValue.x))
        self.y = Float(values[safe: 1] ?? Double(defaultValue.y))
    }

    public static let zero = RuntimeVector2(x: 0, y: 0)
    public var estimatedByteSize: Int { MemoryLayout<Self>.stride }
}

public struct RuntimeVector3: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ values: [Double], default defaultValue: RuntimeVector3 = .zero) {
        self.x = Float(values[safe: 0] ?? Double(defaultValue.x))
        self.y = Float(values[safe: 1] ?? Double(defaultValue.y))
        self.z = Float(values[safe: 2] ?? Double(defaultValue.z))
    }

    public static let zero = RuntimeVector3(x: 0, y: 0, z: 0)
    public static let one = RuntimeVector3(x: 1, y: 1, z: 1)
    public var simdValue: SIMD3<Float> { SIMD3(x, y, z) }
    public var estimatedByteSize: Int { MemoryLayout<Self>.stride }
}

public struct RuntimeVector4: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(_ values: [Double], default defaultValue: RuntimeVector4 = .zero) {
        self.x = Float(values[safe: 0] ?? Double(defaultValue.x))
        self.y = Float(values[safe: 1] ?? Double(defaultValue.y))
        self.z = Float(values[safe: 2] ?? Double(defaultValue.z))
        self.w = Float(values[safe: 3] ?? Double(defaultValue.w))
    }

    public static let zero = RuntimeVector4(x: 0, y: 0, z: 0, w: 0)
    public var estimatedByteSize: Int { MemoryLayout<Self>.stride }
}

public struct Matrix4x4f: Codable, Equatable, Sendable {
    public let m11: Float
    public let m12: Float
    public let m13: Float
    public let m14: Float
    public let m21: Float
    public let m22: Float
    public let m23: Float
    public let m24: Float
    public let m31: Float
    public let m32: Float
    public let m33: Float
    public let m34: Float
    public let m41: Float
    public let m42: Float
    public let m43: Float
    public let m44: Float

    public init(
        m11: Float, m12: Float, m13: Float, m14: Float,
        m21: Float, m22: Float, m23: Float, m24: Float,
        m31: Float, m32: Float, m33: Float, m34: Float,
        m41: Float, m42: Float, m43: Float, m44: Float
    ) {
        self.m11 = m11
        self.m12 = m12
        self.m13 = m13
        self.m14 = m14
        self.m21 = m21
        self.m22 = m22
        self.m23 = m23
        self.m24 = m24
        self.m31 = m31
        self.m32 = m32
        self.m33 = m33
        self.m34 = m34
        self.m41 = m41
        self.m42 = m42
        self.m43 = m43
        self.m44 = m44
    }

    public init(_ matrix: simd_float4x4) {
        self.init(
            m11: matrix.columns.0.x, m12: matrix.columns.0.y, m13: matrix.columns.0.z, m14: matrix.columns.0.w,
            m21: matrix.columns.1.x, m22: matrix.columns.1.y, m23: matrix.columns.1.z, m24: matrix.columns.1.w,
            m31: matrix.columns.2.x, m32: matrix.columns.2.y, m33: matrix.columns.2.z, m34: matrix.columns.2.w,
            m41: matrix.columns.3.x, m42: matrix.columns.3.y, m43: matrix.columns.3.z, m44: matrix.columns.3.w
        )
    }

    public static let identity = Matrix4x4f(matrix_identity_float4x4)

    public var simdValue: simd_float4x4 {
        simd_float4x4(
            SIMD4(m11, m12, m13, m14),
            SIMD4(m21, m22, m23, m24),
            SIMD4(m31, m32, m33, m34),
            SIMD4(m41, m42, m43, m44)
        )
    }

    public var translation: RuntimeVector3 {
        RuntimeVector3(x: m41, y: m42, z: m43)
    }

    public var estimatedByteSize: Int { MemoryLayout<Float>.stride * 16 }
}

public enum FrameValue: Equatable, Sendable {
    case null
    case double(Double)
    case int(Int)
    case bool(Bool)
    case string(String)
    case vec2([Double])
    case vec3([Double])
    case vec4([Double])
    case ivec2([Int])
    case ivec3([Int])
    case ivec4([Int])

    public init(sceneValue: SceneValue) {
        switch sceneValue {
        case .null:
            self = .null
        case .float(let value):
            self = .double(value)
        case .int(let value):
            self = .int(value)
        case .bool(let value):
            self = .bool(value)
        case .string(let value):
            self = .string(value)
        case .vec2(let value):
            self = .vec2(value)
        case .vec3(let value):
            self = .vec3(value)
        case .vec4(let value):
            self = .vec4(value)
        case .ivec2(let value):
            self = .ivec2(value)
        case .ivec3(let value):
            self = .ivec3(value)
        case .ivec4(let value):
            self = .ivec4(value)
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .bool(let value):
            return value ? 1 : 0
        case .vec2(let value), .vec3(let value), .vec4(let value):
            return value.first
        case .ivec2(let value), .ivec3(let value), .ivec4(let value):
            return value.first.map(Double.init)
        case .null, .string:
            return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .double(let value):
            return value != 0
        case .int(let value):
            return value != 0
        case .string(let value):
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        case .vec2(let value), .vec3(let value), .vec4(let value):
            return (value.first ?? 0) != 0
        case .ivec2(let value), .ivec3(let value), .ivec4(let value):
            return (value.first ?? 0) != 0
        case .null:
            return nil
        }
    }

    public var stringValue: String {
        switch self {
        case .null:
            return ""
        case .double(let value):
            return String(value)
        case .int(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .string(let value):
            return value
        case .vec2(let value):
            return value.map { String($0) }.joined(separator: " ")
        case .vec3(let value):
            return value.map { String($0) }.joined(separator: " ")
        case .vec4(let value):
            return value.map { String($0) }.joined(separator: " ")
        case .ivec2(let value):
            return value.map { String($0) }.joined(separator: " ")
        case .ivec3(let value):
            return value.map { String($0) }.joined(separator: " ")
        case .ivec4(let value):
            return value.map { String($0) }.joined(separator: " ")
        }
    }

    public var vector3Value: RuntimeVector3? {
        switch self {
        case .vec3(let values):
            return RuntimeVector3(values)
        case .vec4(let values):
            return RuntimeVector3(Array(values.prefix(3)))
        case .vec2(let values):
            return RuntimeVector3([values[safe: 0] ?? 0, values[safe: 1] ?? 0, 0])
        case .ivec3(let values):
            return RuntimeVector3(values.map(Double.init))
        case .ivec4(let values):
            return RuntimeVector3(Array(values.prefix(3)).map(Double.init))
        case .ivec2(let values):
            return RuntimeVector3([Double(values[safe: 0] ?? 0), Double(values[safe: 1] ?? 0), 0])
        case .double(let value):
            return RuntimeVector3(x: Float(value), y: Float(value), z: Float(value))
        case .int(let value):
            return RuntimeVector3(x: Float(value), y: Float(value), z: Float(value))
        case .bool(let value):
            let scalar: Float = value ? 1 : 0
            return RuntimeVector3(x: scalar, y: scalar, z: scalar)
        case .null, .string:
            return nil
        }
    }

    public var vector2Value: RuntimeVector2? {
        switch self {
        case .vec2(let values):
            return RuntimeVector2(values)
        case .vec3(let values):
            return RuntimeVector2([values[safe: 0] ?? 0, values[safe: 1] ?? 0])
        case .vec4(let values):
            return RuntimeVector2([values[safe: 0] ?? 0, values[safe: 1] ?? 0])
        case .ivec2(let values):
            return RuntimeVector2(values.map(Double.init))
        case .ivec3(let values):
            return RuntimeVector2([Double(values[safe: 0] ?? 0), Double(values[safe: 1] ?? 0)])
        case .ivec4(let values):
            return RuntimeVector2([Double(values[safe: 0] ?? 0), Double(values[safe: 1] ?? 0)])
        case .double(let value):
            let scalar = Float(value)
            return RuntimeVector2(x: scalar, y: scalar)
        case .int(let value):
            let scalar = Float(value)
            return RuntimeVector2(x: scalar, y: scalar)
        case .bool(let value):
            let scalar: Float = value ? 1 : 0
            return RuntimeVector2(x: scalar, y: scalar)
        case .null, .string:
            return nil
        }
    }

    public var estimatedByteSize: Int {
        switch self {
        case .null:
            return 0
        case .double:
            return MemoryLayout<Double>.stride
        case .int:
            return MemoryLayout<Int>.stride
        case .bool:
            return MemoryLayout<Bool>.stride
        case .string(let value):
            return value.utf8.count
        case .vec2(let value), .vec3(let value), .vec4(let value):
            return value.count * MemoryLayout<Double>.stride
        case .ivec2(let value), .ivec3(let value), .ivec4(let value):
            return value.count * MemoryLayout<Int>.stride
        }
    }
}

extension FrameValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "null":
            self = .null
        case "double":
            self = .double(try container.decode(Double.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "vec2":
            self = .vec2(try container.decode([Double].self, forKey: .value))
        case "vec3":
            self = .vec3(try container.decode([Double].self, forKey: .value))
        case "vec4":
            self = .vec4(try container.decode([Double].self, forKey: .value))
        case "ivec2":
            self = .ivec2(try container.decode([Int].self, forKey: .value))
        case "ivec3":
            self = .ivec3(try container.decode([Int].self, forKey: .value))
        case "ivec4":
            self = .ivec4(try container.decode([Int].self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown frame value type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
            try container.encodeNil(forKey: .value)
        case .double(let value):
            try container.encode("double", forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode("int", forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode("bool", forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .value)
        case .vec2(let value):
            try container.encode("vec2", forKey: .type)
            try container.encode(value, forKey: .value)
        case .vec3(let value):
            try container.encode("vec3", forKey: .type)
            try container.encode(value, forKey: .value)
        case .vec4(let value):
            try container.encode("vec4", forKey: .type)
            try container.encode(value, forKey: .value)
        case .ivec2(let value):
            try container.encode("ivec2", forKey: .type)
            try container.encode(value, forKey: .value)
        case .ivec3(let value):
            try container.encode("ivec3", forKey: .type)
            try container.encode(value, forKey: .value)
        case .ivec4(let value):
            try container.encode("ivec4", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct RuntimeClock: Codable, Equatable, Sendable {
    public let frameIndex: UInt64
    public let deltaTime: Double
    public let elapsedTime: Double
    public let isPaused: Bool

    public var estimatedByteSize: Int { MemoryLayout<Self>.stride }
}

public struct RuntimeCursorState: Codable, Equatable, Sendable {
    public let normalized: RuntimeVector2
    public let parallaxDisplacement: RuntimeVector2
    public let previousNormalized: RuntimeVector2
    public let leftDown: Bool

    public init(normalized: RuntimeVector2, parallaxDisplacement: RuntimeVector2,
                previousNormalized: RuntimeVector2? = nil, leftDown: Bool = false) {
        self.normalized = normalized
        self.parallaxDisplacement = parallaxDisplacement
        self.previousNormalized = previousNormalized ?? normalized
        self.leftDown = leftDown
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        normalized = try values.decode(RuntimeVector2.self, forKey: .normalized)
        parallaxDisplacement = try values.decode(RuntimeVector2.self, forKey: .parallaxDisplacement)
        previousNormalized = try values.decodeIfPresent(RuntimeVector2.self, forKey: .previousNormalized) ?? normalized
        leftDown = try values.decodeIfPresent(Bool.self, forKey: .leftDown) ?? false
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + normalized.estimatedByteSize
        + parallaxDisplacement.estimatedByteSize
    }
}

public struct AnimationLayerFrame: Codable, Equatable, Sendable {
    public let id: Int
    public let animation: Int
    public let progress: Double
    public let rate: Double
    public let blend: Double
    public let visible: Bool

    /// Explicit clip frame after per-layer playback, seeking and rate changes.
    /// Older frame packets omit it and retain elapsed-time sampling.
    public var sampleFrame: Double? = nil

    public var estimatedByteSize: Int { MemoryLayout<Self>.stride }
}

public struct FrameNode: Codable, Equatable, Sendable {
    public let nodeID: NodeID
    public let name: String
    public let kind: NodeKind
    public let parentID: NodeID?
    public let dependencyIDs: [NodeID]
    public let localTransform: Matrix4x4f
    public let worldTransform: Matrix4x4f
    public let worldPosition: RuntimeVector3
    public let visible: Bool
    public let opacity: Double?
    public let renderItemReferences: [String]
    public let imageEffects: [FrameImageEffect]
    public let animationLayers: [AnimationLayerFrame]
    public let color: RuntimeVector3?
    public let textureAnimationTime: Double?
    /// Script-controlled albedo movie time. Nil preserves shared playback for
    /// uncontrolled layers and frame packets created by older versions.
    public let videoTextureTime: Double?
    public let imageAlignment: String?

    public init(
        nodeID: NodeID,
        name: String,
        kind: NodeKind,
        parentID: NodeID?,
        dependencyIDs: [NodeID],
        localTransform: Matrix4x4f,
        worldTransform: Matrix4x4f,
        worldPosition: RuntimeVector3,
        visible: Bool,
        opacity: Double?,
        renderItemReferences: [String],
        imageEffects: [FrameImageEffect],
        animationLayers: [AnimationLayerFrame],
        color: RuntimeVector3? = nil,
        textureAnimationTime: Double? = nil,
        videoTextureTime: Double? = nil,
        imageAlignment: String? = nil
    ) {
        self.nodeID = nodeID
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.dependencyIDs = dependencyIDs
        self.localTransform = localTransform
        self.worldTransform = worldTransform
        self.worldPosition = worldPosition
        self.visible = visible
        self.opacity = opacity
        self.renderItemReferences = renderItemReferences
        self.imageEffects = imageEffects
        self.animationLayers = animationLayers
        self.color = color
        self.textureAnimationTime = textureAnimationTime
        self.videoTextureTime = videoTextureTime
        self.imageAlignment = imageAlignment
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + name.utf8.count
        + (imageAlignment?.utf8.count ?? 0)
        + dependencyIDs.count * MemoryLayout<NodeID>.stride
        + localTransform.estimatedByteSize
        + worldTransform.estimatedByteSize
        + worldPosition.estimatedByteSize
        + renderItemReferences.reduce(0) { $0 + $1.utf8.count }
        + imageEffects.reduce(0) { $0 + $1.estimatedByteSize }
        + animationLayers.reduce(0) { $0 + $1.estimatedByteSize }
    }
}

public struct FrameTextureBinding: Codable, Equatable, Sendable {
    public let slot: Int
    public let path: String
    public var sourceType: String? = nil
    /// Authored placeholder used while a system texture is unavailable.
    public var fallbackPath: String? = nil

    public var estimatedByteSize: Int { MemoryLayout<Self>.stride + path.utf8.count + (sourceType?.utf8.count ?? 0) + (fallbackPath?.utf8.count ?? 0) }
}

public struct FrameMaterialPass: Codable, Equatable, Sendable {
    public let index: Int
    public let shaderPath: String
    public let blending: Int
    public let culling: Int
    public let depthTest: Int
    public let depthWrite: Int
    public let textures: [FrameTextureBinding]
    public let userTextures: [FrameTextureBinding]
    public let constants: [String: FrameValue]
    public let combos: [String: Int]

    public init(
        index: Int,
        shaderPath: String,
        blending: Int,
        culling: Int,
        depthTest: Int,
        depthWrite: Int,
        textures: [FrameTextureBinding],
        userTextures: [FrameTextureBinding],
        constants: [String: FrameValue],
        combos: [String: Int]
    ) {
        self.index = index
        self.shaderPath = shaderPath
        self.blending = blending
        self.culling = culling
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.textures = textures
        self.userTextures = userTextures
        self.constants = constants
        self.combos = combos
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + shaderPath.utf8.count
        + textures.reduce(0) { $0 + $1.estimatedByteSize }
        + userTextures.reduce(0) { $0 + $1.estimatedByteSize }
        + constants.reduce(0) { partial, entry in partial + entry.key.utf8.count + entry.value.estimatedByteSize }
        + combos.count * (MemoryLayout<Int>.stride * 2)
    }
}

public struct FrameMaterial: Codable, Equatable, Sendable {
    public let id: String
    public let sourceNodeID: NodeID
    public let sourceFile: String
    public let passOrdering: [Int]
    public let passes: [FrameMaterialPass]

    public init(
        id: String,
        sourceNodeID: NodeID,
        sourceFile: String,
        passOrdering: [Int],
        passes: [FrameMaterialPass]
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.sourceFile = sourceFile
        self.passOrdering = passOrdering
        self.passes = passes
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + id.utf8.count
        + sourceFile.utf8.count
        + passOrdering.count * MemoryLayout<Int>.stride
        + passes.reduce(0) { $0 + $1.estimatedByteSize }
    }
}

public struct FrameRenderTargetDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let scale: Double
    public let unique: Bool
    public let format: String

    public init(name: String, scale: Double, unique: Bool, format: String = "rgba8888") {
        self.name = name
        self.scale = scale
        self.unique = unique
        self.format = format
    }

    private enum CodingKeys: String, CodingKey { case name, scale, unique, format }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        scale = try values.decode(Double.self, forKey: .scale)
        unique = try values.decode(Bool.self, forKey: .unique)
        format = try values.decodeIfPresent(String.self, forKey: .format) ?? "rgba8888"
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride + name.utf8.count + format.utf8.count
    }
}

public struct FrameEffectPass: Codable, Equatable, Sendable {
    public let materialReference: String?
    public let binds: [FrameTextureBinding]
    public let command: Int?
    public let source: String?
    public let target: String?

    public init(
        materialReference: String?,
        binds: [FrameTextureBinding],
        command: Int?,
        source: String?,
        target: String?
    ) {
        self.materialReference = materialReference
        self.binds = binds
        self.command = command
        self.source = source
        self.target = target
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + (materialReference?.utf8.count ?? 0)
        + binds.reduce(0) { $0 + $1.estimatedByteSize }
        + (source?.utf8.count ?? 0)
        + (target?.utf8.count ?? 0)
    }
}

public struct FrameImageEffect: Codable, Equatable, Sendable {
    public let id: Int
    /// Authored array position, stable when earlier effects are hidden. IDs may repeat.
    public let sourceIndex: Int?
    public let renderTargets: [FrameRenderTargetDescriptor]
    public let passes: [FrameEffectPass]

    public init(id: Int, sourceIndex: Int? = nil, renderTargets: [FrameRenderTargetDescriptor], passes: [FrameEffectPass]) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.renderTargets = renderTargets
        self.passes = passes
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + renderTargets.reduce(0) { $0 + $1.estimatedByteSize }
        + passes.reduce(0) { $0 + $1.estimatedByteSize }
    }
}

public struct FrameCameraBloom: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let strength: Double
    public let threshold: Double

    public init(enabled: Bool, strength: Double, threshold: Double) {
        self.enabled = enabled
        self.strength = strength
        self.threshold = threshold
    }

    public var estimatedByteSize: Int { MemoryLayout<Self>.stride }
}

public struct FrameLight: Codable, Equatable, Sendable {
    public let nodeID: NodeID
    public let type: Int
    public let visible: Bool
    public let position: RuntimeVector3
    public let angles: RuntimeVector3
    public let color: RuntimeVector3
    public let intensity: Double
    public let radius: Double
    public let length: Double
    public let innerCone: Double
    public let outerCone: Double
    public let castsShadow: Bool
    /// Authored tube endpoint transformed into world coordinates; nil for
    /// older descriptors that only carry a centered length.
    public let endPosition: RuntimeVector3?
    /// Nil in older packets; modern radial lighting defaults to exponent two.
    public var exponent: Double? = nil

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + position.estimatedByteSize
        + angles.estimatedByteSize
        + color.estimatedByteSize
        + (endPosition?.estimatedByteSize ?? 0)
    }
}

public struct FrameParticleSystem: Codable, Equatable, Sendable {
    public let nodeID: NodeID
    public let visible: Bool
    public let materialReference: String?
    public let rendererName: String
    public let maxParticleCount: UInt32
    public let liveParticleEstimate: UInt32
    public let emissionEnabled: Bool
    public let sequenceMultiplier: Double
    public let startTime: UInt32
    public let instances: [FrameParticleInstance]
    /// Trail/rope renderer configuration (nil for plain sprite renderers).
    public let rendererParameters: FrameParticleRendererParameters?
    /// Simulated child systems (eventfollow/eventspawn/eventdeath/static),
    /// rendered in the parent node's transform space.
    public let childSystems: [FrameParticleSystem]
    public let animationMode: String

    public init(
        nodeID: NodeID,
        visible: Bool,
        materialReference: String?,
        rendererName: String,
        maxParticleCount: UInt32,
        liveParticleEstimate: UInt32,
        emissionEnabled: Bool,
        sequenceMultiplier: Double,
        startTime: UInt32,
        instances: [FrameParticleInstance],
        rendererParameters: FrameParticleRendererParameters? = nil,
        childSystems: [FrameParticleSystem] = [],
        animationMode: String = "sequence"
    ) {
        self.nodeID = nodeID
        self.visible = visible
        self.materialReference = materialReference
        self.rendererName = rendererName
        self.maxParticleCount = maxParticleCount
        self.liveParticleEstimate = liveParticleEstimate
        self.emissionEnabled = emissionEnabled
        self.sequenceMultiplier = sequenceMultiplier
        self.startTime = startTime
        self.instances = instances
        self.rendererParameters = rendererParameters
        self.childSystems = childSystems
        self.animationMode = animationMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decode(NodeID.self, forKey: .nodeID)
        visible = try container.decode(Bool.self, forKey: .visible)
        materialReference = try container.decodeIfPresent(String.self, forKey: .materialReference)
        rendererName = try container.decode(String.self, forKey: .rendererName)
        maxParticleCount = try container.decode(UInt32.self, forKey: .maxParticleCount)
        liveParticleEstimate = try container.decode(UInt32.self, forKey: .liveParticleEstimate)
        emissionEnabled = try container.decode(Bool.self, forKey: .emissionEnabled)
        sequenceMultiplier = try container.decode(Double.self, forKey: .sequenceMultiplier)
        startTime = try container.decode(UInt32.self, forKey: .startTime)
        instances = try container.decodeIfPresent([FrameParticleInstance].self, forKey: .instances) ?? []
        rendererParameters = try container.decodeIfPresent(
            FrameParticleRendererParameters.self,
            forKey: .rendererParameters
        )
        childSystems = try container.decodeIfPresent([FrameParticleSystem].self, forKey: .childSystems) ?? []
        animationMode = try container.decodeIfPresent(String.self, forKey: .animationMode) ?? "sequence"
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + rendererName.utf8.count
        + (materialReference?.utf8.count ?? 0)
        + instances.reduce(0) { $0 + $1.estimatedByteSize }
        + childSystems.reduce(0) { $0 + $1.estimatedByteSize }
    }
}

public struct FrameParticleRendererParameters: Codable, Equatable, Sendable {
    public let length: Double
    public let maxLength: Double
    public let minLength: Double
    public let subdivision: Double

    public init(length: Double, maxLength: Double, minLength: Double, subdivision: Double) {
        self.length = length
        self.maxLength = maxLength
        self.minLength = minLength
        self.subdivision = subdivision
    }
}

public struct FrameParticleInstance: Codable, Equatable, Sendable {
    public let position: RuntimeVector3
    public let rotation: RuntimeVector3
    public let size: Float
    public let color: RuntimeVector4
    public let velocity: RuntimeVector3
    public let lifetimePosition: Float
    public let animationRandom: Float?

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + position.estimatedByteSize
        + rotation.estimatedByteSize
        + color.estimatedByteSize
        + velocity.estimatedByteSize
    }
}

public struct FrameText: Codable, Equatable, Sendable {
    public let nodeID: NodeID
    public let visible: Bool
    public let content: String
    public let fontPath: String
    public let pointSize: Double
    public internal(set) var size: RuntimeVector2
    public let maxWidth: Double
    public let maxRows: Int
    public let padding: Int
    public let color: RuntimeVector4
    public let horizontalAlign: String
    public let verticalAlign: String
    public let limitWidth: Bool
    public let limitRows: Bool
    public let limitUseEllipsis: Bool
    public let blockAlign: Bool
    public let castShadow: Bool
    public let opaqueBackground: Bool
    public let backgroundColor: RuntimeVector4

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + content.utf8.count
        + fontPath.utf8.count
        + size.estimatedByteSize
        + color.estimatedByteSize
        + backgroundColor.estimatedByteSize
    }
}

public enum FrameSoundTransportState: String, Codable, Equatable, Sendable {
    case playing, paused, stopped, failed
}

public struct FrameSoundTransport: Codable, Equatable, Sendable {
    public let nodeID: NodeID
    public let state: FrameSoundTransportState
    public let runID: UInt64
    /// Absolute resolved sound-layer gain; the app multiplies master gain once.
    public let gain: Float

    public init(nodeID: NodeID, state: FrameSoundTransportState, runID: UInt64, gain: Float) {
        self.nodeID = nodeID
        self.state = state
        self.runID = runID
        self.gain = gain
    }
}

public struct FramePacket: Codable, Equatable, Sendable {
    public let metadata: SceneMetadata
    public let timing: RuntimeClock
    public let cursor: RuntimeCursorState?
    public let cameraBloom: FrameCameraBloom?
    /// Evaluated 2D camera magnification. It does not alter layer world coordinates.
    public let cameraZoom: Float
    public let properties: [String: FrameValue]
    public let nodes: [FrameNode]
    public let materials: [FrameMaterial]
    public let lights: [FrameLight]
    public let particleSystems: [FrameParticleSystem]
    public let texts: [FrameText]
    public let soundTransports: [FrameSoundTransport]
    /// Frequency analysis of the host audio input for audio-reactive shaders.
    public let audio: AudioInputState?

    public init(
        metadata: SceneMetadata,
        timing: RuntimeClock,
        cursor: RuntimeCursorState?,
        cameraBloom: FrameCameraBloom?,
        properties: [String: FrameValue],
        nodes: [FrameNode],
        materials: [FrameMaterial],
        lights: [FrameLight],
        particleSystems: [FrameParticleSystem],
        texts: [FrameText],
        soundTransports: [FrameSoundTransport] = [],
        audio: AudioInputState? = nil,
        cameraZoom: Float = 1
    ) {
        self.metadata = metadata
        self.timing = timing
        self.cursor = cursor
        self.cameraBloom = cameraBloom
        self.cameraZoom = Self.validCameraZoom(cameraZoom)
        self.properties = properties
        self.nodes = nodes
        self.materials = materials
        self.lights = lights
        self.particleSystems = particleSystems
        self.texts = texts
        self.soundTransports = soundTransports
        self.audio = audio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(SceneMetadata.self, forKey: .metadata)
        timing = try container.decode(RuntimeClock.self, forKey: .timing)
        cursor = try container.decodeIfPresent(RuntimeCursorState.self, forKey: .cursor)
        cameraBloom = try container.decodeIfPresent(FrameCameraBloom.self, forKey: .cameraBloom)
        cameraZoom = Self.validCameraZoom(try container.decodeIfPresent(Float.self, forKey: .cameraZoom) ?? 1)
        properties = try container.decode([String: FrameValue].self, forKey: .properties)
        nodes = try container.decode([FrameNode].self, forKey: .nodes)
        materials = try container.decode([FrameMaterial].self, forKey: .materials)
        lights = try container.decode([FrameLight].self, forKey: .lights)
        particleSystems = try container.decode([FrameParticleSystem].self, forKey: .particleSystems)
        texts = try container.decode([FrameText].self, forKey: .texts)
        soundTransports = try container.decodeIfPresent([FrameSoundTransport].self, forKey: .soundTransports) ?? []
        audio = try container.decodeIfPresent(AudioInputState.self, forKey: .audio)
    }

    public var estimatedByteSize: Int {
        MemoryLayout<Self>.stride
        + (cursor?.estimatedByteSize ?? 0)
        + (cameraBloom?.estimatedByteSize ?? 0)
        + properties.reduce(0) { partial, entry in partial + entry.key.utf8.count + entry.value.estimatedByteSize }
        + nodes.reduce(0) { $0 + $1.estimatedByteSize }
        + materials.reduce(0) { $0 + $1.estimatedByteSize }
        + lights.reduce(0) { $0 + $1.estimatedByteSize }
        + particleSystems.reduce(0) { $0 + $1.estimatedByteSize }
        + texts.reduce(0) { $0 + $1.estimatedByteSize }
        + soundTransports.count * MemoryLayout<FrameSoundTransport>.stride
    }

    private static func validCameraZoom(_ value: Float) -> Float {
        value.isFinite && value > 0 ? value : 1
    }

    public func encodedByteSize() throws -> Int {
        try JSONEncoder().encode(self).count
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
