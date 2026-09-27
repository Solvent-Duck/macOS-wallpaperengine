import Foundation

/// HLSL permits a local const initialized from runtime data. GLSL 330 does
/// not; retain its value and scope but remove the rejected local qualifier.
enum ShaderLocalConstantRepair {
    static func attempt(message: String, vertexGLSL: String, fragmentGLSL: String) -> ShaderVectorRepair.Repair? {
        guard let regex = try? NSRegularExpression(pattern: #"ERROR: 0:(\d+): 'non-constant initializer'"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)),
              let number = Range(match.range(at: 1), in: message), let line = Int(message[number]) else { return nil }
        let stage: ShaderStage = message.contains("fragment unit parsing failed") ? .fragment : .vertex
        let source = stage == .fragment ? fragmentGLSL : vertexGLSL
        var lines = source.components(separatedBy: "\n")
        guard line > 0, line <= lines.count else { return nil }
        // Do not turn compile-time globals, array sizes, or function parameter
        // qualifiers into a new runtime initialization order.
        var depth = 0
        for text in lines.prefix(line - 1) {
            let code = text.components(separatedBy: "//")[0]
            depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
        }
        guard depth > 0,
              let qualifier = lines[line - 1].range(of: #"\bconst\s+(?=(?:float|int|uint|bool|[biu]?vec[234]|mat[234])\b)"#, options: .regularExpression) else { return nil }
        lines[line - 1].removeSubrange(qualifier)
        return ShaderVectorRepair.Repair(stage: stage, line: line, source: lines.joined(separator: "\n"))
    }
}
