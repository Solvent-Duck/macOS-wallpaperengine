import Foundation

/// HLSL broadcasts scalar initializers to every vector component. Repair only
/// a diagnosed numeric literal; leave other expressions and assignments alone.
enum ShaderScalarInitializerRepair {
    static func attempt(message: String, vertexGLSL: String, fragmentGLSL: String) -> ShaderVectorRepair.Repair? {
        let pattern = #"ERROR: 0:(\d+): '=' :\s+cannot convert from ' const (?:int|float)' to ' temp ([234])-component vector of float'"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)),
              let lineRange = Range(match.range(at: 1), in: message), let line = Int(message[lineRange]),
              let sizeRange = Range(match.range(at: 2), in: message) else { return nil }
        let size = String(message[sizeRange])
        let stage: ShaderStage = message.contains("fragment unit parsing failed") ? .fragment : .vertex
        let source = stage == .fragment ? fragmentGLSL : vertexGLSL
        var lines = source.components(separatedBy: "\n")
        guard line > 0, line <= lines.count else { return nil }
        let initializer = #"\b(?:vec|float|half)"# + size + #"\s+[A-Za-z_]\w*\s*=\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[fF]?)\s*;"#
        guard let declaration = try? NSRegularExpression(pattern: initializer),
              let found = declaration.firstMatch(in: lines[line - 1], range: NSRange(lines[line - 1].startIndex..<lines[line - 1].endIndex, in: lines[line - 1])),
              let value = Range(found.range(at: 1), in: lines[line - 1]) else { return nil }
        lines[line - 1].replaceSubrange(value, with: "vec\(size)(\(lines[line - 1][value]))")
        return ShaderVectorRepair.Repair(stage: stage, line: line, source: lines.joined(separator: "\n"))
    }
}
