import Foundation

/// HLSL accepts a global `const` initialized from uniforms
/// (`const float FEATHER = u_Feather * 0.5;`); GLSL requires a compile-time
/// constant. Turn the declaration into a macro so every use evaluates the
/// same expression where it appears, which is equivalent for these
/// side-effect-free initializers.
enum ShaderGlobalConstantRepair {
    private static let declaration = try? NSRegularExpression(
        pattern: #"^\s*const\s+(?:(?:lowp|mediump|highp)\s+)?(?:float|int|uint|bool|[biu]?vec[234]|mat[234](?:x[234])?)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?);\s*(//.*)?$"#
    )

    static func attempt(message: String, vertexGLSL: String, fragmentGLSL: String) -> ShaderVectorRepair.Repair? {
        guard message.contains("global const initializers must be constant"),
              let regex = try? NSRegularExpression(pattern: #"ERROR: 0:(\d+): '=' : global const initializers"#) else { return nil }
        // glslang reports every such declaration at once; shaders can have
        // dozens, so repair them all in one pass rather than one per retry.
        let reported = regex.matches(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message))
            .compactMap { Range($0.range(at: 1), in: message).flatMap { Int(message[$0]) } }
        guard let first = reported.first else { return nil }
        let stage: ShaderStage = message.contains("fragment unit parsing failed") ? .fragment : .vertex
        let source = stage == .fragment ? fragmentGLSL : vertexGLSL
        var lines = source.components(separatedBy: "\n")
        var repaired = false
        for line in Set(reported) where line > 0 && line <= lines.count {
            if let replacement = macro(for: lines[line - 1]) {
                lines[line - 1] = replacement
                repaired = true
            }
        }
        guard repaired else { return nil }
        return ShaderVectorRepair.Repair(stage: stage, line: first, source: lines.joined(separator: "\n"))
    }

    /// `#define NAME (expr)` for a single-line, single-declarator global
    /// const; nil for anything else (arrays, several declarators, or a
    /// declaration spanning lines).
    static func macro(for line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = declaration?.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { return nil }
        let value = String(line[valueRange])
        var depth = 0
        for character in value {
            if "([{".contains(character) { depth += 1 } else if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 { return nil }
        }
        guard depth == 0 else { return nil }
        return "#define \(line[nameRange]) (\(value))"
    }
}
