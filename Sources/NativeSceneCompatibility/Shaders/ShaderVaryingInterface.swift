import Foundation

/// Match stage declarations before linking: glslang promotes mismatched
/// vectors without updating expression types, yielding invalid MSL. Preserve
/// the fragment's component view, filling components absent from the vertex
/// output with zero. Exact Windows values for absent components are unverified.
enum ShaderVaryingInterface {
    /// Some workshop exports attach a component suffix to a declaration,
    /// such as `varying vec4 v_Size.xy;`. The suffix is not part of the
    /// interface name; retain the declared vector type and the bare name.
    static func sanitizeDeclarations(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"(?m)^([ \t]*varying[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?\w+[ \t]+[A-Za-z_][A-Za-z0-9_]*)\.[xyzwrgba]{1,4}([ \t]*;)"#,
            with: "$1$2", options: .regularExpression
        )
    }

    static func normalizeFragment(vertex: String, fragment: String) -> String {
        let pattern = #"(?m)^([ \t]*varying[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?)vec([234])([ \t]+)([A-Za-z_][A-Za-z0-9_]*)([ \t]*;)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return fragment }

        func declarations(_ source: String) -> [String: [NSTextCheckingResult]] {
            Dictionary(grouping: regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))) {
                String(source[Range($0.range(at: 4), in: source)!])
            }
        }

        let vertexDeclarations = declarations(vertex)
        let fragmentDeclarations = declarations(fragment)
        var result = fragment
        // Work backwards so edits do not invalidate subsequent ranges.
        for match in fragmentDeclarations.values.flatMap({ $0 }).sorted(by: { $0.range.location > $1.range.location }) {
            let name = String(fragment[Range(match.range(at: 4), in: fragment)!])
            guard fragmentDeclarations[name]?.count == 1,
                  let producers = vertexDeclarations[name], producers.count == 1,
                  let sourceCount = Int(vertex[Range(producers[0].range(at: 2), in: vertex)!]),
                  let targetCount = Int(fragment[Range(match.range(at: 2), in: fragment)!]),
                  sourceCount != targetCount,
                  let range = Range(match.range, in: result) else { continue }
            let declaration = String(fragment[Range(match.range(at: 1), in: fragment)!]) + "vec\(sourceCount)"
                + String(fragment[Range(match.range(at: 3), in: fragment)!]) + name
                + String(fragment[Range(match.range(at: 5), in: fragment)!])
            let expression: String
            if sourceCount > targetCount {
                expression = "\(name).\(String("xyzw".prefix(targetCount)))"
            } else {
                let padding = Array(repeating: "0.0", count: targetCount - sourceCount).joined(separator: ", ")
                expression = "vec\(targetCount)(\(name), \(padding))"
            }
            result.replaceSubrange(range, with: declaration + "\n#define \(name) (\(expression))\n")
        }
        return result
    }
}
