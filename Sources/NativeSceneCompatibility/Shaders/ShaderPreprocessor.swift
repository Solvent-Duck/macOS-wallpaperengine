import Foundation

public struct ShaderPreprocessor: Sendable {
    public let assetResolver: ShaderAssetResolver

    public init(assetResolver: ShaderAssetResolver) {
        self.assetResolver = assetResolver
    }

    public func preprocess(_ source: String, stage: ShaderStage, file: String) throws -> String {
        let withLibraries = try preprocessTopLevelLibraries(in: source, file: file)
        let withConditionals = sanitizeConditionals(in: withLibraries)
        return sanitizeFragmentVaryings(in: withConditionals, stage: stage)
    }

    private func preprocessTopLevelLibraries(in source: String, file: String) throws -> String {
        var includeBlocks: [String] = []
        let lines = spliceContinuedLines(source).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var processedLines: [String] = []
        var activeLibraries = Set([normalizedLibraryName(file)])

        for line in lines {
            let lineString = String(line)

            if let includeName = parseDirectiveArgument(in: lineString, prefix: "#include") {
                let includeContent = try resolveLibraryContent(
                    assetResolver.includeShader(includeName),
                    containerName: includeName,
                    activeLibraries: &activeLibraries,
                    beginPrefix: "// begin of include from file ",
                    endPrefix: "// end of included from file "
                )
                includeBlocks.append(includeContent)
                processedLines.append("// include \(includeName)")
                continue
            }

            if let requireName = parseRequireName(in: lineString) {
                let requireContent = try resolveLibraryContent(
                    requiredLibrary(requireName),
                    containerName: requireName,
                    activeLibraries: &activeLibraries,
                    beginPrefix: "// begin of require ",
                    endPrefix: "// end of require "
                )
                processedLines.append(requireContent.trimmingCharacters(in: .newlines))
                continue
            }

            processedLines.append(lineString)
        }

        let processed = processedLines.joined(separator: "\n")
        guard !includeBlocks.isEmpty else {
            return processed
        }

        let includeContent = includeBlocks.joined(separator: "\n")
        return injectIncludes(includeContent, into: processed)
    }

    private func resolveLibraryContent(
        _ source: String,
        containerName: String,
        activeLibraries: inout Set<String>,
        beginPrefix: String,
        endPrefix: String
    ) throws -> String {
        let normalizedName = normalizedLibraryName(containerName)
        guard activeLibraries.insert(normalizedName).inserted else {
            return "// skipped recursive include \(containerName)\n"
        }
        defer { activeLibraries.remove(normalizedName) }

        let resolved = try resolveNestedLibraries(in: source, activeLibraries: &activeLibraries)
        return "\(beginPrefix)\(containerName)\n\(resolved)\n\(endPrefix)\(containerName)\n"
    }

    private func resolveNestedLibraries(in source: String, activeLibraries: inout Set<String>) throws -> String {
        let lines = spliceContinuedLines(source).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var processedLines: [String] = []

        for line in lines {
            let lineString = String(line)

            if let includeName = parseDirectiveArgument(in: lineString, prefix: "#include") {
                let includeContent = try resolveLibraryContent(
                    assetResolver.includeShader(includeName),
                    containerName: includeName,
                    activeLibraries: &activeLibraries,
                    beginPrefix: "// begin of include from file ",
                    endPrefix: "// end of included from file "
                )
                processedLines.append(includeContent.trimmingCharacters(in: .newlines))
                continue
            }

            if let requireName = parseRequireName(in: lineString) {
                let requireContent = try resolveLibraryContent(
                    requiredLibrary(requireName),
                    containerName: requireName,
                    activeLibraries: &activeLibraries,
                    beginPrefix: "// begin of require ",
                    endPrefix: "// end of require "
                )
                processedLines.append(requireContent.trimmingCharacters(in: .newlines))
                continue
            }

            processedLines.append(lineString)
        }

        return processedLines.joined(separator: "\n")
    }

    private func requiredLibrary(_ name: String) throws -> String {
        // #require requests an engine-generated library. Keep ordinary #include
        // resolution separate so authored shader files retain their contents.
        if normalizedLibraryName(name) == "LightingV1.h" {
            return LightingShaderLibrary.source
        }
        return try assetResolver.includeShader(name)
    }

    private func spliceContinuedLines(_ source: String) -> String {
        // HLSL sources can continue ordinary expressions as well as macros.
        // Resolve these before GLSL 330 parsing and before processing includes.
        source.replacingOccurrences(of: "\\\r\n", with: "")
            .replacingOccurrences(of: "\\\n", with: "")
            .replacingOccurrences(of: "\\\r", with: "")
    }

    private func normalizedLibraryName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return name
        }
        return ((trimmed as NSString).deletingPathExtension as NSString)
            .appendingPathExtension("h") ?? trimmed
    }

    private func parseDirectiveArgument(in line: String, prefix: String) -> String? {
        guard let directiveRange = line.range(of: prefix) else {
            return nil
        }

        let remaining = line[directiveRange.upperBound...]
        guard
            let firstQuote = remaining.firstIndex(of: "\""),
            let secondQuote = remaining[remaining.index(after: firstQuote)...].firstIndex(of: "\"")
        else {
            return nil
        }

        return String(remaining[remaining.index(after: firstQuote)..<secondQuote])
    }

    private func parseRequireName(in line: String) -> String? {
        guard let range = line.range(of: "#require") else {
            return nil
        }

        let remaining = line[range.upperBound...]
        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { token in
                String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }

    private func injectIncludes(_ includeContent: String, into source: String) -> String {
        guard let mainRange = findMainFunction(in: source) else {
            return source + "\n" + includeContent + "\n"
        }

        let prefix = source[..<mainRange.lowerBound]
        let insertionIndex = findIncludeInsertionPoint(in: prefix) ?? prefix.endIndex
        var mutable = source
        mutable.insert(contentsOf: includeContent + "\n", at: insertionIndex)
        return mutable
    }

    private func findMainFunction(in source: String) -> Range<String.Index>? {
        source.range(of: #"void\s+main\s*\("#, options: .regularExpression)
    }

    private func findIncludeInsertionPoint(in prefix: Substring) -> String.Index? {
        let anchors = ["attribute", "varying", "uniform"]
        var latestLineEnd: Substring.Index?
        var conditionDepth = 0

        var lineStart = prefix.startIndex
        while lineStart < prefix.endIndex {
            let lineEnd = prefix[lineStart...].firstIndex(of: "\n") ?? prefix.endIndex
            let line = prefix[lineStart..<lineEnd]
            let trimmed = line.drop(while: \.isWhitespace)

            if trimmed.hasPrefix("#if") {
                conditionDepth += 1
            } else if trimmed.hasPrefix("#endif") {
                conditionDepth = max(conditionDepth - 1, 0)
            } else if conditionDepth == 0 {
                for anchor in anchors {
                    if trimmed.hasPrefix(anchor) {
                        latestLineEnd = lineEnd
                        break
                    }
                }
            }

            lineStart = lineEnd < prefix.endIndex ? prefix.index(after: lineEnd) : prefix.endIndex
        }

        return latestLineEnd
    }

    private func sanitizeConditionals(in source: String) -> String {
        var sanitized: [String] = []
        var openConditionals = 0

        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var lineString = String(line)
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)

            let isIf = trimmed.hasPrefix("#if") && !trimmed.hasPrefix("#ifdef") && !trimmed.hasPrefix("#ifndef")
            let isIfdef = trimmed.hasPrefix("#ifdef") || trimmed.hasPrefix("#ifndef")
            let isEndif = trimmed.hasPrefix("#endif")

            if isEndif && openConditionals == 0 {
                continue
            }

            if isIf || trimmed.hasPrefix("#elif") {
                // Workshop HLSL conditionals sometimes end in a semicolon.
                // Remove only that terminator, preserving a trailing comment.
                let comment = lineString.range(of: "//")?.lowerBound ?? lineString.endIndex
                let directive = String(lineString[..<comment]).replacingOccurrences(
                    of: #";(?=\s*$)"#, with: "", options: .regularExpression)
                lineString = directive + lineString[comment...]
            }

            sanitized.append(lineString)

            if isIf || isIfdef {
                openConditionals += 1
            } else if isEndif && openConditionals > 0 {
                openConditionals -= 1
            }
        }

        while openConditionals > 0 {
            sanitized.append("#endif")
            openConditionals -= 1
        }

        return sanitized.joined(separator: "\n")
    }

    private func sanitizeFragmentVaryings(in source: String, stage: ShaderStage) -> String {
        guard stage == .fragment else {
            return source
        }

        let varyingPattern = #"^\s*varying\s+([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$"#
        let mainPattern = #"void\s+main\s*\(\s*\)\s*\{"#
        guard
            let varyingRegex = try? NSRegularExpression(pattern: varyingPattern, options: [.anchorsMatchLines]),
            let mainRegex = try? NSRegularExpression(pattern: mainPattern)
        else {
            return source
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let varyingMatches = varyingRegex.matches(in: source, range: nsRange)
        guard !varyingMatches.isEmpty else {
            return source
        }

        guard let mainMatch = mainRegex.firstMatch(in: source, range: nsRange),
              let mainRange = Range(mainMatch.range, in: source)
        else {
            return source
        }

        // Strip comments before scanning: commented-out declarations
        // ("// vec2 v_TexCoord = ...") must not read as local shadows.
        let mainBody = String(source[mainRange.lowerBound...])
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: [.regularExpression])
        var mutatedVaryings: [(name: String, type: String)] = []
        var seen = Set<String>()

        for match in varyingMatches {
            guard
                let typeRange = Range(match.range(at: 1), in: source),
                let nameRange = Range(match.range(at: 2), in: source)
            else {
                continue
            }

            let type = String(source[typeRange])
            let name = String(source[nameRange])
            let assignmentPattern = #"(^|[^A-Za-z0-9_])\#(name)\s*="#
            // A local declaration shadowing the name makes the shim both
            // unnecessary and a redefinition once the #define rewrites it.
            let declarationPattern = #"(^|[^A-Za-z0-9_])(float|int|uint|bool|vec2|vec3|vec4|ivec2|ivec3|ivec4|mat2|mat3|mat4)\s+\#(name)\s*[=;,)]"#

            if mainBody.range(of: assignmentPattern, options: .regularExpression) != nil,
               mainBody.range(of: declarationPattern, options: .regularExpression) == nil,
               seen.insert(name).inserted {
                mutatedVaryings.append((name: name, type: type))
            }
        }

        guard !mutatedVaryings.isEmpty else {
            return source
        }

        let insertionIndex = mainRange.upperBound
        let prologue = mutatedVaryings.map { varying in
            """
                \(varying.type) _we_mut_\(varying.name) = \(varying.name);
            #define \(varying.name) _we_mut_\(varying.name)
            """
        }.joined(separator: "\n")

        var mutable = source
        mutable.insert(contentsOf: "\n" + prologue + "\n", at: insertionIndex)
        return mutable
    }
}
