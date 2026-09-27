import Foundation

public enum ShaderStage: String, Codable, Sendable {
    case vertex
    case fragment
}

public struct ShaderCompilationRequest: Equatable, Sendable {
    public let shaderPath: String
    public let assetRoots: [URL]
    public let combos: [String: Int]
    public let overrideCombos: [String: Int]
    public let textureSlots: Set<Int>

    public init(
        shaderPath: String,
        assetRoots: [URL],
        combos: [String: Int] = [:],
        overrideCombos: [String: Int] = [:],
        textureSlots: Set<Int> = []
    ) {
        self.shaderPath = shaderPath
        self.assetRoots = assetRoots
        self.combos = combos
        self.overrideCombos = overrideCombos
        self.textureSlots = textureSlots
    }
}

public struct MetalShaderVertexAttribute: Codable, Equatable, Sendable {
    public let name: String
    public let location: UInt32
    public let vecSize: UInt32
    public let bufferIndex: UInt32
}

public struct MetalShaderCompilation: Codable, Equatable, Sendable {
    public let vertexMSL: String
    public let fragmentMSL: String
    public let vertexUniformSlots: [String: UInt32]
    public let fragmentUniformSlots: [String: UInt32]
    public let fragmentTextureSlots: [String: UInt32]
    public let fragmentSamplerSlots: [String: UInt32]
    public let vertexAttributes: [MetalShaderVertexAttribute]
}

public struct CompiledShaderPair: Codable, Equatable, Sendable {
    public let shaderPath: String
    public let vertexGLSL: String
    public let fragmentGLSL: String
    public let discoveredCombos: [String: Int]
    public let metal: MetalShaderCompilation
}

public enum ShaderPipelineError: LocalizedError {
    case missingShader(String)
    case malformedInclude(String)
    case malformedRequire(String)
    case invalidMetadata(String)
    case compilerUnavailable
    case compilationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingShader(let path):
            return "Missing shader asset: \(path)"
        case .malformedInclude(let line):
            return "Malformed #include directive: \(line)"
        case .malformedRequire(let line):
            return "Malformed #require directive: \(line)"
        case .invalidMetadata(let content):
            return "Invalid shader metadata: \(content)"
        case .compilerUnavailable:
            return "The native shader compiler bridge returned no result"
        case .compilationFailed(let reason):
            return "Shader compilation failed: \(reason)"
        }
    }
}
