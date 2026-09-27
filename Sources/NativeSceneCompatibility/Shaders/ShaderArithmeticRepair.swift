import Foundation

/// Locate component-wise operands before truncating them. A reported minus in
/// `(uv * 2 - 1 - center)` refers to the whole left expression, not the scalar
/// immediately before that token. Macro names retain their inferred dimensions.
enum ShaderArithmeticRepair {
    static func repair(line: String, source: String, op: Character, left: Int, right: Int) -> String? {
        let parser = Parser(line: line, source: source)
        let candidates = parser.expressions()
        guard let candidate = candidates.first(where: { $0.op == String(op) && $0.left.components == left && $0.right.components == right }) else { return nil }
        let operand = left > right ? candidate.left : candidate.right
        let range = parser.tokens[operand.start].range.lowerBound..<parser.tokens[operand.end - 1].range.upperBound
        let swizzle = min(left, right) == 2 ? "xy" : "xyz"
        return line.replacingCharacters(in: range, with: "(\(line[range])).\(swizzle)")
    }

    private struct Token { let text: String; let range: Range<String.Index> }
    private struct Expression { let start: Int; let end: Int; let components: Int? }
    private struct Binary { let op: String; let left: Expression; let right: Expression }

    private final class Parser {
        let tokens: [Token]
        private let symbols: [String: Int]
        private let macros: [String: String]
        private let recursion: Int
        private var cursor = 0
        private var binaries: [Binary] = []

        convenience init(line: String, source: String) {
            var symbols: [String: Int] = [:]
            var macros: [String: String] = [:]
            if let regex = try? NSRegularExpression(pattern: #"\b(float|int|uint|bool|[biu]?vec[234])\s+([A-Za-z_]\w*)"#) {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) {
                    guard let type = Range(match.range(at: 1), in: source), let name = Range(match.range(at: 2), in: source) else { continue }
                    symbols[String(source[name])] = Int(source[type].suffix(1)) ?? 1
                }
            }
            if let regex = try? NSRegularExpression(pattern: #"(?m)^\s*#define[ \t]+([A-Za-z_]\w*)[ \t]+([^\r\n]+)"#) {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) {
                    guard let name = Range(match.range(at: 1), in: source), let value = Range(match.range(at: 2), in: source) else { continue }
                    macros[String(source[name])] = String(source[value])
                }
            }
            self.init(line: line, symbols: symbols, macros: macros, recursion: 0)
        }

        init(line: String, symbols: [String: Int], macros: [String: String], recursion: Int) {
            self.symbols = symbols
            self.macros = macros
            self.recursion = recursion
            let regex = try! NSRegularExpression(pattern: #"//.*|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[fFuU]?|[A-Za-z_]\w*|[^\s]"#)
            self.tokens = regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)).compactMap { match in
                guard let range = Range(match.range, in: line), !line[range].hasPrefix("//") else { return nil }
                return Token(text: String(line[range]), range: range)
            }
        }

        func expressions() -> [Binary] {
            while cursor < tokens.count {
                let start = cursor
                _ = expression(minimum: 0)
                if cursor == start { cursor += 1 }
            }
            return binaries
        }

        private func dimensions(_ name: String) -> Int? {
            if ["float", "int", "uint", "bool"].contains(name) { return 1 }
            if name.range(of: #"^[biu]?vec[234]$"#, options: .regularExpression) != nil { return Int(name.suffix(1)) }
            if let known = symbols[name] { return known }
            if recursion < 8, let value = macros[name] {
                let parser = Parser(line: value, symbols: symbols, macros: macros, recursion: recursion + 1)
                return parser.expression(minimum: 0)?.components
            }
            return nil
        }

        private func expression(minimum: Int) -> Expression? {
            guard var left = primary() else { return nil }
            while cursor < tokens.count, let precedence = Self.precedence[tokens[cursor].text], precedence >= minimum {
                let op = tokens[cursor].text
                cursor += 1
                guard let right = expression(minimum: precedence + 1) else { break }
                binaries.append(Binary(op: op, left: left, right: right))
                let size: Int?
                if let a = left.components, let b = right.components { size = a == 1 || b == 1 ? max(a, b) : min(a, b) }
                else { size = nil }
                left = Expression(start: left.start, end: right.end, components: size)
            }
            return left
        }

        private func primary() -> Expression? {
            guard cursor < tokens.count else { return nil }
            let start = cursor
            let name = tokens[cursor].text
            cursor += 1
            var size: Int?
            if name == "(" {
                size = expression(minimum: 0)?.components
                guard consume(")") else { return nil }
            } else if name == "-" || name == "+" {
                size = primary()?.components
            } else if name.first?.isNumber == true || name.hasPrefix(".") && name.count > 1 {
                size = 1
            } else if name.first?.isLetter == true || name.hasPrefix("_") {
                size = dimensions(name)
                if consume("(") {
                    var arguments: [Int?] = []
                    while cursor < tokens.count, tokens[cursor].text != ")" {
                        let previous = cursor
                        arguments.append(expression(minimum: 0)?.components)
                        if !consume(",") || cursor == previous { break }
                    }
                    guard consume(")") else { return nil }
                    if ["dot", "length", "distance"].contains(name) { size = 1 }
                    else if ["texSample2D", "texture2D", "texture", "textureLod"].contains(name) { size = 4 }
                    else if size == nil, ["abs", "sin", "cos", "min", "max", "clamp", "mix", "pow", "normalize"].contains(name) {
                        size = arguments.compactMap { $0 }.max()
                    }
                }
            } else { return nil }
            if consume("."), cursor < tokens.count {
                let swizzle = tokens[cursor].text
                size = swizzle.allSatisfy { "xyzwrgba stpq".contains($0) } ? swizzle.count : nil
                cursor += 1
            }
            return Expression(start: start, end: cursor, components: size)
        }

        private func consume(_ text: String) -> Bool {
            guard cursor < tokens.count, tokens[cursor].text == text else { return false }
            cursor += 1
            return true
        }

        private static let precedence = ["+": 1, "-": 1, "*": 2, "/": 2]
    }
}
