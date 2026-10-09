import Foundation

/// A value in Valve's KeyValues text format (`.vdf`, `.acf`): either a string
/// or an ordered list of key/value pairs. Keys are matched case-insensitively,
/// as Steam does, and duplicate keys keep their first occurrence for lookup.
public enum VDF: Equatable, Sendable {
    case string(String)
    case object([(key: String, value: VDF)])

    public static func == (lhs: VDF, rhs: VDF) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public subscript(key: String) -> VDF? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The key/value pairs of an object, in file order; empty for a string.
    public var entries: [(key: String, value: VDF)] {
        if case .object(let pairs) = self { return pairs }
        return []
    }

    public struct ParseError: Error, Equatable {
        public let message: String
    }

    /// Parse a whole document. The result is an object holding the top-level
    /// pairs, so `VDF.parse(text)["libraryfolders"]` reaches the root block.
    public static func parse(_ text: String) throws -> VDF {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return .object(try parser.parsePairs(topLevel: true))
    }

    public static func parse(contentsOf url: URL) throws -> VDF {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var index = 0

    enum Token { case string(String), open, close }

    mutating func parsePairs(topLevel: Bool) throws -> [(key: String, value: VDF)] {
        var pairs: [(key: String, value: VDF)] = []
        while true {
            guard let token = try nextToken() else {
                if topLevel { return pairs }
                throw VDF.ParseError(message: "unexpected end of input inside a block")
            }
            switch token {
            case .close:
                if topLevel { throw VDF.ParseError(message: "unmatched '}'") }
                return pairs
            case .open:
                throw VDF.ParseError(message: "'{' where a key was expected")
            case .string(let key):
                guard let valueToken = try nextToken() else {
                    throw VDF.ParseError(message: "key \"\(key)\" has no value")
                }
                switch valueToken {
                case .string(let value): pairs.append((key, .string(value)))
                case .open: pairs.append((key, .object(try parsePairs(topLevel: false))))
                case .close: throw VDF.ParseError(message: "key \"\(key)\" has no value")
                }
                skipConditional()
            }
        }
    }

    /// Skip whitespace and `//` comments, then read one token.
    mutating func nextToken() throws -> Token? {
        while index < scalars.count {
            let c = scalars[index]
            if c.properties.isWhitespace {
                index += 1
            } else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else {
                break
            }
        }
        guard index < scalars.count else { return nil }
        let c = scalars[index]
        switch c {
        case "{": index += 1; return .open
        case "}": index += 1; return .close
        case "\"": return .string(try quoted())
        default: return .string(bare())
        }
    }

    mutating func quoted() throws -> String {
        index += 1
        var out = String.UnicodeScalarView()
        while index < scalars.count {
            let c = scalars[index]
            index += 1
            if c == "\"" { return String(out) }
            if c == "\\", index < scalars.count {
                let next = scalars[index]
                index += 1
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default: out.append("\\"); out.append(next)
                }
            } else {
                out.append(c)
            }
        }
        throw VDF.ParseError(message: "unterminated string")
    }

    mutating func bare() -> String {
        var out = String.UnicodeScalarView()
        while index < scalars.count {
            let c = scalars[index]
            if c.properties.isWhitespace || c == "{" || c == "}" || c == "\"" { break }
            out.append(c)
            index += 1
        }
        return String(out)
    }

    /// Skip a platform conditional such as `[$OSX]` after a value.
    mutating func skipConditional() {
        var probe = index
        while probe < scalars.count, scalars[probe] == " " || scalars[probe] == "\t" { probe += 1 }
        guard probe < scalars.count, scalars[probe] == "[" else { return }
        while probe < scalars.count, scalars[probe] != "]", scalars[probe] != "\n" { probe += 1 }
        if probe < scalars.count, scalars[probe] == "]" { index = probe + 1 }
    }
}
