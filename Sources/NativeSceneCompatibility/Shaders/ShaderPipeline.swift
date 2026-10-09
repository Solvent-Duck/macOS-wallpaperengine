import Foundation

public enum ShaderPipeline {
    public static func compile(_ request: ShaderCompilationRequest) throws -> CompiledShaderPair {
        let resolver = ShaderAssetResolver(roots: request.assetRoots)
        let rawVertex = try resolver.vertexShader(request.shaderPath)
        let rawFragment = try resolver.fragmentShader(request.shaderPath)

        var discoveredCombos = ComboResolver.discoverCombos(
            in: [rawVertex, rawFragment],
            combos: request.combos,
            overrideCombos: request.overrideCombos
        )
        let preprocessor = ShaderPreprocessor(assetResolver: resolver)
        var vertexBody = rewriteCStyleCasts(
            in: renameReservedIdentifiers(
                in: metalRenderTargetCoordinates(try preprocessor.preprocess(rawVertex, stage: .vertex, file: request.shaderPath))
            )
        )
        var fragmentBody = rewriteCStyleCasts(
            in: renameReservedIdentifiers(
                in: metalRenderTargetCoordinates(try preprocessor.preprocess(rawFragment, stage: .fragment, file: request.shaderPath))
            )
        )
        // WE compiles stage pairs together and shares varying declarations;
        // real workshop fragments reference varyings they never declare.
        vertexBody = ShaderVaryingInterface.sanitizeDeclarations(vertexBody)
        fragmentBody = ShaderVaryingInterface.sanitizeDeclarations(fragmentBody)
        fragmentBody = injectMissingVaryings(from: vertexBody, into: fragmentBody)
        fragmentBody = ShaderVaryingInterface.normalizeFragment(vertex: vertexBody, fragment: fragmentBody)

        for (name, value) in ComboResolver.textureCombos(in: [vertexBody, fragmentBody], textureSlots: request.textureSlots)
            where request.combos[name] == nil && request.overrideCombos[name] == nil {
            discoveredCombos[name] = value
        }
        let defineBlock = ComboResolver.defineBlock(
            combos: request.combos,
            overrideCombos: request.overrideCombos,
            discoveredCombos: discoveredCombos
        )

        vertexBody = Self.neutralizeRuntimeConditions(in: vertexBody)
        fragmentBody = Self.neutralizeRuntimeConditions(in: fragmentBody)

        // Combos referenced by includes (e.g. `#if LIGHTING` in common
        // headers) may never be annotated or supplied; glslang aborts on
        // undefined macros in #if expressions, so default them to 0.
        let fallbackDefines = Self.undefinedConditionalMacros(
            in: [vertexBody, fragmentBody],
            existingDefines: defineBlock
        )
        let effectiveDefineBlock = defineBlock + fallbackDefines

        var vertexGLSL = buildFinalSource(
            file: request.shaderPath,
            stage: .vertex,
            defineBlock: effectiveDefineBlock,
            body: vertexBody
        )
        var fragmentGLSL = buildFinalSource(
            file: request.shaderPath,
            stage: .fragment,
            defineBlock: effectiveDefineBlock,
            body: fragmentBody
        )

        // WE's own compiler applies HLSL implicit truncation to mixed-size
        // vector ops; glslang rejects them. Repair the reported operand and
        // retry, advancing through candidate occurrences on repeats.
        let metal: MetalShaderCompilation
        var repairOccurrences: [String: Int] = [:]
        // glslang stops at the first error, so a shader full of HLSL-isms
        // (e.g. a dozen runtime consts) needs one retry per repair.
        var repairsRemaining = 48
        while true {
            do {
                metal = try MetalShaderCompiler.compile(vertex: vertexGLSL, fragment: fragmentGLSL)
                break
            } catch ShaderPipelineError.compilationFailed(let message) where repairsRemaining > 0 {
                repairsRemaining -= 1
                let key = message.components(separatedBy: "\n").first ?? message
                let occurrence = repairOccurrences[key, default: 0]
                repairOccurrences[key] = occurrence + 1
                guard let repair = ShaderVectorRepair.attempt(
                    message: message,
                    vertexGLSL: vertexGLSL,
                    fragmentGLSL: fragmentGLSL,
                    occurrence: occurrence
                ) ?? ShaderScalarConditionRepair.attempt(message: message, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL)
                    ?? ShaderInputMutationRepair.attempt(message: message, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL)
                    ?? ShaderLocalConstantRepair.attempt(message: message, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL)
                    ?? ShaderGlobalConstantRepair.attempt(message: message, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL)
                    ?? ShaderScalarInitializerRepair.attempt(message: message, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL)
                    ?? ShaderEmptyFunctionRepair.attempt(message: message, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL) else {
                    try dumpAndRethrow(
                        ShaderPipelineError.compilationFailed(message),
                        shaderPath: request.shaderPath,
                        vertexGLSL: vertexGLSL,
                        fragmentGLSL: fragmentGLSL
                    )
                }
                switch repair.stage {
                case .vertex:
                    vertexGLSL = repair.source
                case .fragment:
                    fragmentGLSL = repair.source
                }
            } catch {
                try dumpAndRethrow(
                    error,
                    shaderPath: request.shaderPath,
                    vertexGLSL: vertexGLSL,
                    fragmentGLSL: fragmentGLSL
                )
            }
        }

        return CompiledShaderPair(
            shaderPath: request.shaderPath,
            vertexGLSL: vertexGLSL,
            fragmentGLSL: fragmentGLSL,
            discoveredCombos: discoveredCombos,
            metal: metal
        )
    }

    /// WE's reflections, refraction and layer blending select top-first render-target UVs for HLSL.
    /// Metal uses the same texture convention, even though our input language
    /// is GLSL. Adapt these coordinate guards without enabling HLSL syntax or
    /// changing ordinary authored texture coordinates.
    private static func metalRenderTargetCoordinates(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"#ifdef\s+HLSL\s*\n\s*((?:position\.y\s*=\s*1\.0\s*-\s*position\.y\s*;\s*)?(v_ScreenCoord|v_ScreenPos)\.y\s*=\s*-\2\.y\s*;)\s*\n\s*#endif"#,
            with: "$1", options: .regularExpression
        ).replacingOccurrences(
            of: #"#ifndef\s+HLSL\s*\n\s*screenRefractionOffset\.y\s*=\s*-screenRefractionOffset\.y\s*;\s*\n\s*#endif"#,
            with: "", options: .regularExpression
        ).replacingOccurrences(
            of: #"#ifdef\s+HLSL\s*\n\s*(normal\.y\s*=\s*-normal\.y\s*;)\s*\n\s*#endif"#,
            with: "$1", options: .regularExpression
        )
    }

    /// HLSL-style C casts (`(int) x`, `(float)(x + y)`) are illegal in GLSL;
    /// rewrite them as constructor calls. A bare parenthesized type is only
    /// ever a cast in this dialect, so the rewrite is safe.
    private static func rewriteCStyleCasts(in source: String) -> String {
        guard source.range(
            of: #"\(\s*(?:int|uint|float|bool)\s*\)"#,
            options: .regularExpression
        ) != nil else {
            return source
        }
        var result = source
        // Cast before a parenthesized expression: `(int) (n + d)` → `int (n + d)`.
        result = result.replacingOccurrences(
            of: #"\(\s*(int|uint|float|bool)\s*\)\s*(?=\()"#,
            with: "$1",
            options: .regularExpression
        )
        // Cast before an identifier/element access: `(int) n` → `int(n)`.
        result = result.replacingOccurrences(
            of: #"\(\s*(int|uint|float|bool)\s*\)\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+|\[[^\[\]]*\])*)"#,
            with: "$1($2)",
            options: .regularExpression
        )
        return result
    }

    /// Copies `varying` declarations that exist in the vertex body into the
    /// fragment body when the fragment references them without declaring
    /// them, preserving the preprocessor guards they were declared under.
    private static func injectMissingVaryings(from vertexBody: String, into fragmentBody: String) -> String {
        let declarationPattern = try? NSRegularExpression(
            pattern: #"(?:^|(?<=;))\s*varying\s+(?:lowp\s+|mediump\s+|highp\s+)?(\w+)\s+(\w+)\s*;"#
        )
        guard let declarationPattern else { return fragmentBody }

        func declarations(in line: String) -> [(type: String, name: String)] {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return declarationPattern.matches(in: line, range: range).compactMap { match in
                guard let typeRange = Range(match.range(at: 1), in: line),
                      let nameRange = Range(match.range(at: 2), in: line) else { return nil }
                return (String(line[typeRange]), String(line[nameRange]))
            }
        }

        // A declaration after another semicolon is still declared. Searching
        // only the start of each line injected duplicate fragment varyings.
        func codeLines(_ source: String) -> [String] {
            source.replacingOccurrences(of: #"/\*[\s\S]*?\*/|//[^\n]*"#, with: " ", options: .regularExpression)
                .components(separatedBy: "\n")
        }

        // Vertex declarations with the conditional stack they sit under.
        var vertexDeclarations: [(type: String, name: String, guards: [String])] = []
        var guardStack: [String] = []
        for rawLine in codeLines(vertexBody) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") {
                guardStack.append(line)
            } else if line.hasPrefix("#endif") {
                if !guardStack.isEmpty { guardStack.removeLast() }
            } else if line.hasPrefix("#else") || line.hasPrefix("#elif") {
                if !guardStack.isEmpty { guardStack[guardStack.count - 1] = line }
            } else {
                // #else/#elif replacements are best-effort; skip those.
                let cleanGuards = guardStack.filter { $0.hasPrefix("#if") }
                guard cleanGuards.count == guardStack.count else { continue }
                for declared in declarations(in: rawLine) {
                    vertexDeclarations.append((declared.type, declared.name, cleanGuards))
                }
            }
        }
        guard !vertexDeclarations.isEmpty else { return fragmentBody }

        var fragmentDeclared = Set<String>()
        for rawLine in codeLines(fragmentBody) {
            for declared in declarations(in: rawLine) {
                fragmentDeclared.insert(declared.name)
            }
        }

        var injected = ""
        for declared in vertexDeclarations where !fragmentDeclared.contains(declared.name) {
            guard fragmentBody.range(
                of: #"(?<![A-Za-z0-9_])\#(declared.name)(?![A-Za-z0-9_])"#,
                options: .regularExpression
            ) != nil else {
                continue
            }
            for guardLine in declared.guards {
                injected += guardLine + "\n"
            }
            injected += "varying \(declared.type) \(declared.name);\n"
            for _ in declared.guards {
                injected += "#endif\n"
            }
            fragmentDeclared.insert(declared.name)
        }
        guard !injected.isEmpty else { return fragmentBody }
        return injected + fragmentBody
    }

    private static func dumpAndRethrow(
        _ error: Error,
        shaderPath: String,
        vertexGLSL: String,
        fragmentGLSL: String
    ) throws -> Never {
        if let dumpDir = ProcessInfo.processInfo.environment["WE_DEBUG_SHADER_DUMP"] {
            let base = URL(fileURLWithPath: dumpDir)
                .appendingPathComponent(shaderPath.replacingOccurrences(of: "/", with: "_"))
            try? vertexGLSL.write(to: base.appendingPathExtension("vert.glsl"), atomically: true, encoding: .utf8)
            try? fragmentGLSL.write(to: base.appendingPathExtension("frag.glsl"), atomically: true, encoding: .utf8)
        }
        throw error
    }

    /// Workshop shaders written HLSL-style sometimes use identifiers that
    /// are reserved words in GLSL 330 (glslang rejects them). Lines with
    /// string literals (metadata annotations) are left untouched.
    private static func renameReservedIdentifiers(in source: String) -> String {
        // C++ alternative operator tokens are legal GLSL identifiers, but
        // remain reserved in the generated Metal source.
        var reserved = ["input", "output", "filter", "and", "and_eq", "bitand", "bitor", "compl", "not", "not_eq", "or", "or_eq", "xor", "xor_eq"]
        // GLSL variants sometimes implement this HLSL intrinsic themselves.
        // Keep authored helpers distinct from both our fallback macro and the
        // Metal standard-library overload when SPIRV-Cross emits a function.
        if source.range(of: #"\b(?:float|vec[234])\s+log10\s*\("#, options: .regularExpression) != nil {
            reserved.append("log10")
        }
        guard reserved.contains(where: { source.contains($0) }) else {
            return source
        }
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            var text = String(line)
            guard !text.contains("\"") else {
                return text
            }
            for word in reserved where text.contains(word) {
                text = text.replacingOccurrences(
                    of: #"(?<![A-Za-z0-9_])\#(word)(?![A-Za-z0-9_])"#,
                    with: "we_\(word)",
                    options: .regularExpression
                )
            }
            return text
        }
        return lines.joined(separator: "\n")
    }

    /// Some workshop shaders test runtime values in preprocessor conditions
    /// (`#if g_Texture0Resolution.x < g_Texture0Resolution.y`). Member access
    /// can never be evaluated by the preprocessor; treat the condition as
    /// false, as if those values were 0. Defaulting the names to 0 instead
    /// would redefine the uniform and every `.x`/`.y` swizzle in the shader.
    static func neutralizeRuntimeConditions(in body: String) -> String {
        guard body.contains("#if") || body.contains("#elif"),
              let memberAccess = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*\s*\.\s*[A-Za-z_]"#) else { return body }
        var changed = false
        let lines = body.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let keyword = trimmed.hasPrefix("#if ") ? "#if" : trimmed.hasPrefix("#elif ") ? "#elif" : nil
            guard let keyword else { return line }
            let code = trimmed.components(separatedBy: "//")[0]
            guard memberAccess.firstMatch(in: code, range: NSRange(code.startIndex..<code.endIndex, in: code)) != nil else { return line }
            changed = true
            return "\(keyword) 0 // runtime condition: \(code.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces))"
        }
        return changed ? lines.joined(separator: "\n") : body
    }

    private static func undefinedConditionalMacros(
        in bodies: [String],
        existingDefines: String
    ) -> String {
        // Names defined by the pipeline's own header/stage prologues.
        var defined: Set<String> = [
            "GLSL", "HLSL", "gl_FragColor", "varying", "attribute",
            "mul", "max", "lerp", "frac", "CASTU", "CAST2", "CAST3", "CAST4",
            "CAST3X3", "saturate", "texSample2D", "texSample2DLod",
            "log10", "atan2", "fmod", "ddx", "ddy",
        ]
        for line in existingDefines.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count >= 2, parts[0] == "#define" {
                defined.insert(String(parts[1]))
            }
        }

        var locallyDefined = Set<String>()
        var definednessChecked = Set<String>()
        var referenced = Set<String>()
        let identifierPattern = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
        let keywords: Set<String> = ["defined", "true", "false"]

        for body in bodies {
            for rawLine in body.split(whereSeparator: \.isNewline) {
                // Workshop shaders annotate conditionals ("#if X == 2 //RGB
                // mode"); identifiers in comments must not become defines.
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if let commentStart = line.range(of: "//") {
                    line = String(line[..<commentStart.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("#define ") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 {
                        // Strip any macro parameter list.
                        locallyDefined.insert(String(parts[1].prefix(while: { $0 != "(" })))
                    }
                    continue
                }
                if line.hasPrefix("#ifdef ") || line.hasPrefix("#ifndef ") {
                    // Names tested for definedness must stay undefined;
                    // a zero default would still count as defined.
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 {
                        definednessChecked.insert(String(parts[1]))
                    }
                    continue
                }
                guard line.hasPrefix("#if ") || line.hasPrefix("#elif ") else {
                    continue
                }
                if line.contains("defined(") || line.contains("defined ") {
                    // Same rule for `#if defined(X)` forms: record and skip.
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    identifierPattern?.enumerateMatches(in: line, range: range) { match, _, _ in
                        guard let match, let matchRange = Range(match.range, in: line) else {
                            return
                        }
                        let name = String(line[matchRange])
                        if !keywords.contains(name), name != "if", name != "elif" {
                            definednessChecked.insert(name)
                        }
                    }
                    continue
                }
                let expression = String(line.drop(while: { $0 != " " }))
                let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
                identifierPattern?.enumerateMatches(in: expression, range: range) { match, _, _ in
                    guard let match, let matchRange = Range(match.range, in: expression) else {
                        return
                    }
                    let name = String(expression[matchRange])
                    if !keywords.contains(name), !name.hasPrefix("GL_") {
                        referenced.insert(name)
                    }
                }
            }
        }

        let missing = referenced
            .subtracting(defined)
            .subtracting(locallyDefined)
            .subtracting(definednessChecked)
            .sorted()
        guard !missing.isEmpty else {
            return ""
        }
        return missing.map { "#define \($0) 0" }.joined(separator: "\n") + "\n"
    }

    private static func buildFinalSource(
        file: String,
        stage: ShaderStage,
        defineBlock: String,
        body: String
    ) -> String {
        shaderHeader(file) + stageDefines(stage) + defineBlock + body
    }

    private static func shaderHeader(_ file: String) -> String {
        """
        #version 330
        // ======================================================
        // Processed shader \(file)
        // ======================================================
        precision highp float;
        #define mul(x, y) ((y) * (x))
        #define max(x, y) max (y, x)
        #define lerp mix
        #define frac fract
        #define CASTU(x) (uint(x))
        #define CAST2(x) (vec2(x))
        #define CAST3(x) (vec3(x))
        #define CAST4(x) (vec4(x))
        #define CAST3X3(x) (mat3(x))
        #define saturate(x) (clamp(x, 0.0, 1.0))
        #define texSample2D texture
        #define texSample2DLod textureLod
        #define DECLARE_SAMPLER2D_PARAMETER(name) sampler2D name
        #define MAKE_SAMPLER2D_ARGUMENT(name) name
        #define log10(x) log2(x) * 0.301029995663981
        #define atan2 atan
        #define fmod(x, y) ((x)-(y)*trunc((x)/(y)))
        #define ddx dFdx
        #define ddy(x) dFdy(-(x))
        #define GLSL 1
        #define float2 vec2
        #define float3 vec3
        #define float4 vec4
        #define half2 vec2
        #define half3 vec3
        #define half4 vec4
        #define float3x3 mat3
        #define float4x4 mat4
        #define float2x2 mat2

        """
    }

    private static func stageDefines(_ stage: ShaderStage) -> String {
        switch stage {
        case .fragment:
            return """
            #define gl_FragColor out_FragColor
            out vec4 out_FragColor;
            #define varying in

            """
        case .vertex:
            return """
            #define attribute in
            #define varying out

            """
        }
    }
}
