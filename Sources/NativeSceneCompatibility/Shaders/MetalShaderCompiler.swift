import CShaderCompiler
import Foundation

public enum MetalShaderCompiler {
    /// Finalize the underlying glslang process state. Call once before exit
    /// to prevent crashes from C++ static destructors running out of order.
    public static func finalizeCompiler() {
        nsc_finalize_glslang()
    }

    static func preprocess(source: String, stage: ShaderStage) -> String? {
        source.withCString { input in
            guard let output = nsc_preprocess_shader_source(input, stage == .fragment ? 1 : 0) else { return nil }
            defer { nsc_free_compiler_string(output) }
            return String(validatingCString: output)
        }
    }

    public static func compile(vertex: String, fragment: String) throws -> MetalShaderCompilation {
        let response = try vertex.withCString { vertexCString in
            try fragment.withCString { fragmentCString in
                guard let raw = nsc_compile_shader_pair_to_msl_json(vertexCString, fragmentCString) else {
                    throw ShaderPipelineError.compilerUnavailable
                }

                defer { nsc_free_compiler_string(raw) }

                guard let string = String(validatingCString: raw) else {
                    throw ShaderPipelineError.compilerUnavailable
                }

                let data = Data(string.utf8)
                let decoded = try JSONDecoder().decode(CompilerResponse.self, from: data)
                guard decoded.ok else {
                    throw ShaderPipelineError.compilationFailed(decoded.error ?? "unknown error")
                }

                guard let compilation = decoded.compilation else {
                    throw ShaderPipelineError.compilationFailed("missing MSL payload")
                }

                return compilation
            }
        }

        return MetalShaderCompilation(
            vertexMSL: patchGeneratedMSL(response.vertexMSL),
            fragmentMSL: patchGeneratedMSL(response.fragmentMSL),
            vertexUniformSlots: response.vertexUniformSlots,
            fragmentUniformSlots: response.fragmentUniformSlots,
            fragmentTextureSlots: response.fragmentTextureSlots,
            fragmentSamplerSlots: response.fragmentSamplerSlots,
            vertexAttributes: response.vertexAttributes
        )
    }

    /// SPIRV-Cross emits helper functions whose scalar/vector parameters are
    /// `constant T&` references (inherited from their uniform origin), but
    /// call sites may pass thread-local values, which Metal cannot bind to
    /// the constant address space. Passing primitives by value is always
    /// legal, so strip the reference qualifier. Struct references
    /// (`constant type_Globals&`) are left untouched.
    private static func devalueConstantPrimitiveParams(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"constant ((?:float|half|int|uint|bool)[234]?(?:x[234])?)& (\w+)(?=\s*[,)])"#,
            with: "$1 $2",
            options: .regularExpression
        )
    }

    /// Works around SPIRV-Cross output gaps: shaders that pass uniform arrays
    /// to functions call `spvArrayCopyFromConstantToStack` with an
    /// `spvUnsafeArray` source, but only the raw-array overload is emitted.
    /// Inject compatible overloads right after the spvUnsafeArray definition.
    private static func patchGeneratedMSL(_ source: String) -> String {
        let source = devalueConstantPrimitiveParams(source)
        guard source.contains("spvArrayCopyFromConstantToStack"),
              let structRange = source.range(of: "struct spvUnsafeArray"),
              let closeRange = source.range(of: "\n};", range: structRange.upperBound..<source.endIndex) else {
            return source
        }

        let overloads = """


        template<typename T, size_t N>
        inline void spvArrayCopyFromConstantToStack(thread T (&dst)[N], constant spvUnsafeArray<T, N>& src)
        {
            for (size_t i = 0; i < N; i++)
            {
                dst[i] = src.elements[i];
            }
        }

        template<typename T, size_t N>
        inline void spvArrayCopyFromConstantToStack(thread spvUnsafeArray<T, N>& dst, constant spvUnsafeArray<T, N>& src)
        {
            for (size_t i = 0; i < N; i++)
            {
                dst.elements[i] = src.elements[i];
            }
        }
        """

        var patched = source
        patched.insert(contentsOf: overloads, at: closeRange.upperBound)
        return patched
    }
}

private struct CompilerResponse: Decodable {
    let ok: Bool
    let error: String?
    let vertexMSL: String?
    let fragmentMSL: String?
    let vertexUniformSlots: [String: UInt32]?
    let fragmentUniformSlots: [String: UInt32]?
    let fragmentTextureSlots: [String: UInt32]?
    let fragmentSamplerSlots: [String: UInt32]?
    let vertexAttributes: [MetalShaderVertexAttribute]?

    var compilation: MetalShaderCompilation? {
        guard
            let vertexMSL,
            let fragmentMSL,
            let vertexUniformSlots,
            let fragmentUniformSlots,
            let fragmentTextureSlots,
            let fragmentSamplerSlots,
            let vertexAttributes
        else {
            return nil
        }

        return MetalShaderCompilation(
            vertexMSL: vertexMSL,
            fragmentMSL: fragmentMSL,
            vertexUniformSlots: vertexUniformSlots,
            fragmentUniformSlots: fragmentUniformSlots,
            fragmentTextureSlots: fragmentTextureSlots,
            fragmentSamplerSlots: fragmentSamplerSlots,
            vertexAttributes: vertexAttributes
        )
    }
}
