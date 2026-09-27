import Foundation

/// WE's HLSL fragment inputs are local values. GLSL stage inputs are read-only;
/// copy a diagnosed writable input into private storage before entering main.
enum ShaderInputMutationRepair {
    static func attempt(message: String, vertexGLSL: String, fragmentGLSL: String) -> ShaderVectorRepair.Repair? {
        guard message.contains("can't modify shader input"), message.contains("fragment"),
              let diagnostic = try? NSRegularExpression(pattern: #"l-value required \"([A-Za-z_][A-Za-z0-9_]*)\""#),
              let match = diagnostic.firstMatch(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)),
              let nameRange = Range(match.range(at: 1), in: message) else { return nil }
        let name = String(message[nameRange])
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?m)^[ \t]*(?:varying|in)[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?(vec[234]|float|int)[ \t]+"# + escaped + #"[ \t]*;[^\n]*"#
        guard let declarationRegex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let declarations = declarationRegex.matches(in: fragmentGLSL, range: NSRange(fragmentGLSL.startIndex..<fragmentGLSL.endIndex, in: fragmentGLSL))
        guard !declarations.isEmpty else { return nil }
        let storage = "__we_mutable_\(name)"
        let initialize = "__we_init_\(name)"
        guard !fragmentGLSL.contains(storage), !fragmentGLSL.contains(initialize) else { return nil }
        var result = fragmentGLSL
        // Different shader versions can declare the same varying under
        // mutually exclusive guards. Keep each private copy in its guard.
        for declaration in declarations.reversed() {
            guard let typeRange = Range(declaration.range(at: 1), in: fragmentGLSL),
                  let declarationRange = Range(declaration.range, in: fragmentGLSL) else { return nil }
            var type = String(fragmentGLSL[typeRange])
            var insertion = declarationRange.upperBound
            // A wider vertex output may already have a narrower fragment view.
            let tail = fragmentGLSL[insertion...]
            let macroPattern = #"^\s*#define[ \t]+"# + escaped + #"[ \t]+\("# + escaped + #"\.([xyzw]{2,3})\)[^\n]*"#
            if let regex = try? NSRegularExpression(pattern: macroPattern),
               let macro = regex.firstMatch(in: String(tail), range: NSRange(tail.startIndex..<tail.endIndex, in: tail)),
               let range = Range(macro.range, in: tail), let swizzle = Range(macro.range(at: 1), in: tail) {
                type = "vec\(tail[swizzle].count)"
                insertion = range.upperBound
            }
            result.insert(contentsOf: "\n\(type) \(storage);\nvoid \(initialize)() { \(storage) = \(name); }\n#undef \(name)\n#define \(name) \(storage)\n", at: insertion)
        }
        guard let mainRegex = try? NSRegularExpression(pattern: #"\bvoid\s+main\s*\(\s*(?:void)?\s*\)\s*\{"#) else { return nil }
        let mains = mainRegex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
        guard !mains.isEmpty else { return nil }
        for main in mains.reversed() {
            guard let range = Range(main.range, in: result) else { return nil }
            result.insert(contentsOf: "\n\(initialize)();\n", at: range.upperBound)
        }
        let line = fragmentGLSL[..<Range(declarations[0].range, in: fragmentGLSL)!.lowerBound].filter { $0 == "\n" }.count + 1
        return ShaderVectorRepair.Repair(stage: .fragment, line: line, source: result)
    }
}
