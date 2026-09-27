import Foundation

/// Wallpaper Engine's own shader compiler follows HLSL implicit-truncation
/// rules: a binary op between different-sized vectors truncates the larger
/// operand (e.g. `vec4 * vec2` is `vec4.xy * vec2`). glslang rejects this,
/// so on that specific compile error we swizzle the larger operand down and
/// retry. Repairs are driven entirely by glslang's error output.
enum ShaderVectorRepair {

    struct Repair {
        let stage: ShaderStage
        let line: Int
        let source: String
    }

    private static let errorPattern = try? NSRegularExpression(
        pattern: #"(vertex|fragment) unit parsing failed: ERROR: 0:(\d+): '([*+\/-])' :\s+wrong operand types: no operation '.' exists that takes a left-hand operand of type '[^']*?(\d)-component vector of float' and a right operand of type '[^']*?(\d)-component vector of float'"#
    )

    /// Attempts one repair for a glslang failure message. `occurrence`
    /// selects which operator occurrence on the line to patch, so repeated
    /// failures on the same line advance to the next candidate.
    static func attempt(
        message: String,
        vertexGLSL: String,
        fragmentGLSL: String,
        occurrence: Int
    ) -> Repair? {
        guard let errorPattern else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = errorPattern.firstMatch(in: message, range: range),
              let stageRange = Range(match.range(at: 1), in: message),
              let lineRange = Range(match.range(at: 2), in: message),
              let opRange = Range(match.range(at: 3), in: message),
              let leftRange = Range(match.range(at: 4), in: message),
              let rightRange = Range(match.range(at: 5), in: message),
              let lineNumber = Int(message[lineRange]),
              let leftComponents = Int(message[leftRange]),
              let rightComponents = Int(message[rightRange]),
              let op = message[opRange].first,
              leftComponents != rightComponents else {
            return nil
        }

        let stage: ShaderStage = message[stageRange] == "vertex" ? .vertex : .fragment
        let source = stage == .vertex ? vertexGLSL : fragmentGLSL
        var lines = source.components(separatedBy: "\n")
        guard lineNumber >= 1, lineNumber <= lines.count else { return nil }

        guard let repairedLine = ShaderArithmeticRepair.repair(
            line: lines[lineNumber - 1], source: source, op: op, left: leftComponents, right: rightComponents
        ) ?? truncateOperand(
            line: lines[lineNumber - 1],
            op: op,
            leftComponents: leftComponents,
            rightComponents: rightComponents,
            occurrence: occurrence
        ) else {
            return nil
        }

        lines[lineNumber - 1] = repairedLine
        return Repair(stage: stage, line: lineNumber, source: lines.joined(separator: "\n"))
    }

    private static func truncateOperand(
        line: String,
        op: Character,
        leftComponents: Int,
        rightComponents: Int,
        occurrence: Int
    ) -> String? {
        let chars = Array(line)
        let targetComponents = min(leftComponents, rightComponents)
        let swizzle = targetComponents == 2 ? ".xy" : ".xyz"
        var seen = 0

        var index = 0
        while index < chars.count {
            defer { index += 1 }
            guard chars[index] == op else { continue }
            // Skip compound assignment (`*=`) and comment markers (`//`).
            if index + 1 < chars.count, chars[index + 1] == "=" { continue }
            if op == "/", index + 1 < chars.count, chars[index + 1] == "/" { index += 1; continue }
            if op == "/", index > 0, chars[index - 1] == "/" { continue }

            let candidate: String?
            if leftComponents > rightComponents {
                candidate = insertAfterLeftOperand(chars: chars, opIndex: index, swizzle: swizzle)
            } else {
                candidate = insertAfterRightOperand(chars: chars, opIndex: index, swizzle: swizzle)
            }
            guard let candidate, candidate != line else { continue }
            if seen == occurrence {
                return candidate
            }
            seen += 1
        }
        return nil
    }

    /// `... v_PointerUV * rhs` → `... v_PointerUV.xy * rhs`
    private static func insertAfterLeftOperand(chars: [Character], opIndex: Int, swizzle: String) -> String? {
        var end = opIndex - 1
        while end >= 0, chars[end] == " " || chars[end] == "\t" {
            end -= 1
        }
        guard end >= 0 else { return nil }

        if chars[end] == ")" {
            // Balanced group (possibly a call); the swizzle goes right after.
            var depth = 0
            var scan = end
            while scan >= 0 {
                if chars[scan] == ")" { depth += 1 }
                if chars[scan] == "(" {
                    depth -= 1
                    if depth == 0 { break }
                }
                scan -= 1
            }
            guard scan >= 0 else { return nil }
        } else if !(chars[end].isLetter || chars[end].isNumber || chars[end] == "_" || chars[end] == ".") {
            return nil
        }

        var result = String(chars[0...end])
        result += swizzle
        result += String(chars[(end + 1)...])
        return result
    }

    /// `lhs * someVec4` → `lhs * someVec4.xy`
    private static func insertAfterRightOperand(chars: [Character], opIndex: Int, swizzle: String) -> String? {
        var start = opIndex + 1
        while start < chars.count, chars[start] == " " || chars[start] == "\t" {
            start += 1
        }
        guard start < chars.count else { return nil }

        var end = start
        if chars[end] == "(" {
            var depth = 0
            while end < chars.count {
                if chars[end] == "(" { depth += 1 }
                if chars[end] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            guard end < chars.count else { return nil }
        } else {
            guard chars[end].isLetter || chars[end] == "_" else { return nil }
            while end + 1 < chars.count,
                  chars[end + 1].isLetter || chars[end + 1].isNumber || chars[end + 1] == "_" || chars[end + 1] == "." {
                end += 1
            }
            // Function call: include the argument list.
            if end + 1 < chars.count, chars[end + 1] == "(" {
                var depth = 0
                var scan = end + 1
                while scan < chars.count {
                    if chars[scan] == "(" { depth += 1 }
                    if chars[scan] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    scan += 1
                }
                guard scan < chars.count else { return nil }
                end = scan
            }
        }

        var result = String(chars[0...end])
        result += swizzle
        if end + 1 < chars.count {
            result += String(chars[(end + 1)...])
        }
        return result
    }
}
