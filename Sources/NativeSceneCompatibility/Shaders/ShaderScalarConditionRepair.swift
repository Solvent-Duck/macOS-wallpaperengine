import Foundation

/// HLSL accepts scalar numeric conditions; GLSL requires bool. Repair only
/// a diagnosed condition and simple scalar operands, leaving other errors
/// visible instead of guessing how to rewrite an arbitrary expression.
enum ShaderScalarConditionRepair {
    static func attempt(message: String, vertexGLSL: String, fragmentGLSL: String) -> ShaderVectorRepair.Repair? {
        let pattern = #"(vertex|fragment) unit parsing failed: ERROR: 0:(\d+): [^\n]*boolean expression expected"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)),
              let stageRange = Range(match.range(at: 1), in: message),
              let lineRange = Range(match.range(at: 2), in: message),
              let lineNumber = Int(message[lineRange]) else { return nil }
        let stage: ShaderStage = message[stageRange] == "vertex" ? .vertex : .fragment
        var lines = (stage == .vertex ? vertexGLSL : fragmentGLSL).components(separatedBy: "\n")
        guard lineNumber > 0, lineNumber <= lines.count else { return nil }
        let original = lines[lineNumber - 1]
        let operand = #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\[\]]+\])*|[-+]?\d+(?:\.\d+)?)"#
        let ternary = #"(^\s*|[=(:,;]\s*|\breturn\s+)"# + operand + #"(\s*\?)"#
        let branch = #"(\b(?:if|while)\s*\(\s*)"# + operand + #"(\s*\))"#
        let repaired = original.replacingOccurrences(of: ternary, with: "$1bool($2)$3", options: .regularExpression)
            .replacingOccurrences(of: branch, with: "$1bool($2)$3", options: .regularExpression)
        guard repaired != original else { return nil }
        lines[lineNumber - 1] = repaired
        return ShaderVectorRepair.Repair(stage: stage, line: lineNumber, source: lines.joined(separator: "\n"))
    }
}
