import Foundation

/// Optional effects may leave an empty helper when all of its implementations
/// and calls are disabled. Remove only an empty, unreferenced definition after
/// the compiler has expanded macros/conditionals; never invent a return value.
enum ShaderEmptyFunctionRepair {
    static func attempt(message: String, vertexGLSL: String, fragmentGLSL: String) -> ShaderVectorRepair.Repair? {
        guard let diagnostic = try? NSRegularExpression(pattern: #"function does not return a value: ([A-Za-z_]\w*)"#),
              let match = diagnostic.firstMatch(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)),
              let nameRange = Range(match.range(at: 1), in: message) else { return nil }
        let name = NSRegularExpression.escapedPattern(for: String(message[nameRange]))
        let stage: ShaderStage = message.contains("fragment unit parsing failed") ? .fragment : .vertex
        let source = stage == .fragment ? fragmentGLSL : vertexGLSL
        guard let expanded = MetalShaderCompiler.preprocess(source: source, stage: stage),
              let references = try? NSRegularExpression(pattern: #"\b"# + name + #"\b"#),
              references.numberOfMatches(in: expanded, range: NSRange(expanded.startIndex..<expanded.endIndex, in: expanded)) == 1,
              let definition = try? NSRegularExpression(pattern: #"\b(?:float|int|uint|bool|[biu]?vec[234]|mat[234])\s+"# + name + #"\s*\([^{};]*\)\s*\{\s*\}"#),
              let function = definition.firstMatch(in: expanded, range: NSRange(expanded.startIndex..<expanded.endIndex, in: expanded)),
              let range = Range(function.range, in: expanded) else { return nil }
        let line = expanded[..<range.lowerBound].filter { $0 == "\n" }.count + 1
        let replacement = expanded[range].map { $0 == "\n" ? "\n" : " " }.joined()
        return ShaderVectorRepair.Repair(stage: stage, line: line,
                                        source: expanded.replacingCharacters(in: range, with: replacement))
    }
}
