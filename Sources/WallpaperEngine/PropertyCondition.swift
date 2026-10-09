import Foundation

/// A parsed `condition` from a project.json property ("show this control only when…").
///
/// Wallpaper Engine evaluates these as JavaScript expressions over the other
/// properties, e.g. `clock.value == true && style.value == 2`. The corpus only
/// uses property reads, literals, comparisons, `!`, `&&`, `||` and parentheses,
/// so this is a small recursive-descent evaluator with JavaScript's loose
/// equality and truthiness rather than a JS engine.
///
/// Conditions that fail to parse are treated as always visible, so a control is
/// never hidden because of an expression this evaluator doesn't understand.
struct PropertyCondition: Equatable, Sendable {
    indirect enum Expression: Equatable, Sendable {
        case literal(Value)
        /// `name.value`, or a bare `name` (authors occasionally omit `.value`).
        case property(String)
        case not(Expression)
        case and(Expression, Expression)
        case or(Expression, Expression)
        case compare(Expression, Comparison, Expression)
    }

    enum Comparison: Equatable, Sendable {
        case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    }

    enum Value: Equatable, Sendable {
        case bool(Bool)
        case number(Double)
        case string(String)
        case undefined
    }

    let expression: Expression

    /// Returns nil for an empty or unparseable condition (i.e. always visible).
    init?(_ source: String) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tokens = Tokenizer.tokenize(source) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let expression = parser.parseOr(), parser.isAtEnd else { return nil }
        self.expression = expression
    }

    /// Evaluate with `lookup` returning the current value of a property key.
    func isSatisfied(_ lookup: (String) -> Value) -> Bool {
        Self.evaluate(expression, lookup).isTruthy
    }

    private static func evaluate(_ expression: Expression, _ lookup: (String) -> Value) -> Value {
        switch expression {
        case .literal(let value):
            return value
        case .property(let key):
            return lookup(key)
        case .not(let inner):
            return .bool(!evaluate(inner, lookup).isTruthy)
        case .and(let lhs, let rhs):
            let left = evaluate(lhs, lookup)
            return left.isTruthy ? evaluate(rhs, lookup) : left
        case .or(let lhs, let rhs):
            let left = evaluate(lhs, lookup)
            return left.isTruthy ? left : evaluate(rhs, lookup)
        case .compare(let lhs, let comparison, let rhs):
            return .bool(compare(evaluate(lhs, lookup), comparison, evaluate(rhs, lookup)))
        }
    }

    private static func compare(_ lhs: Value, _ comparison: Comparison, _ rhs: Value) -> Bool {
        switch comparison {
        case .equal: return looselyEqual(lhs, rhs)
        case .notEqual: return !looselyEqual(lhs, rhs)
        default:
            // Relational operators compare numerically; NaN (undefined, text) is never ordered.
            let a = lhs.number, b = rhs.number
            switch comparison {
            case .less: return a < b
            case .lessOrEqual: return a <= b
            case .greater: return a > b
            default: return a >= b
            }
        }
    }

    /// JavaScript `==`: same-type values compare directly, everything else numerically.
    private static func looselyEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.undefined, .undefined): return true
        case (.undefined, _), (_, .undefined): return false
        case let (.string(a), .string(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        default: return lhs.number == rhs.number
        }
    }
}

extension PropertyCondition.Value {
    var isTruthy: Bool {
        switch self {
        case .bool(let flag): return flag
        case .number(let number): return number != 0 && !number.isNaN
        case .string(let string): return !string.isEmpty
        case .undefined: return false
        }
    }

    /// JavaScript `Number(x)`.
    var number: Double {
        switch self {
        case .bool(let flag): return flag ? 1 : 0
        case .number(let number): return number
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? 0 : (Double(trimmed) ?? .nan)
        case .undefined: return .nan
        }
    }
}

// MARK: - Tokenizer

private enum Token: Equatable {
    case identifier(String)
    case number(Double)
    case string(String)
    case op(String)
    case leftParen, rightParen
}

private enum Tokenizer {
    static func tokenize(_ source: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "(" { tokens.append(.leftParen); i += 1; continue }
            if c == ")" { tokens.append(.rightParen); i += 1; continue }
            if c == "\"" || c == "'" {
                guard let end = chars[(i + 1)...].firstIndex(of: c) else { return nil }
                tokens.append(.string(String(chars[(i + 1)..<end])))
                i = end + 1
                continue
            }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber)
                || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber && !(tokens.last.map(Self.endsOperand) ?? false)) {
                var j = i + 1
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let number = Double(String(chars[i..<j])) else { return nil }
                tokens.append(.number(number))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                tokens.append(.identifier(String(chars[i..<j])))
                i = j
                continue
            }
            // Longest operator first; `===`/`!==` behave like `==`/`!=` for these
            // value types, and a lone `=` is an author typo for `==`.
            let rest = String(chars[i..<min(i + 3, chars.count)])
            guard let op = ["===", "!==", "==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "="]
                .first(where: { rest.hasPrefix($0) }) else { return nil }
            tokens.append(.op(op))
            i += op.count
        }
        return tokens
    }

    private static func endsOperand(_ token: Token) -> Bool {
        switch token {
        case .identifier, .number, .string, .rightParen: return true
        case .op, .leftParen: return false
        }
    }
}

// MARK: - Parser

private struct Parser {
    let tokens: [Token]
    var index = 0

    var isAtEnd: Bool { index == tokens.count }

    private var current: Token? { index < tokens.count ? tokens[index] : nil }

    private mutating func consumeOp(_ candidates: Set<String>) -> String? {
        if case .op(let op) = current, candidates.contains(op) {
            index += 1
            return op
        }
        return nil
    }

    mutating func parseOr() -> PropertyCondition.Expression? {
        guard var lhs = parseAnd() else { return nil }
        while consumeOp(["||"]) != nil {
            guard let rhs = parseAnd() else { return nil }
            lhs = .or(lhs, rhs)
        }
        return lhs
    }

    private mutating func parseAnd() -> PropertyCondition.Expression? {
        guard var lhs = parseComparison() else { return nil }
        while consumeOp(["&&"]) != nil {
            guard let rhs = parseComparison() else { return nil }
            lhs = .and(lhs, rhs)
        }
        return lhs
    }

    private mutating func parseComparison() -> PropertyCondition.Expression? {
        guard var lhs = parseUnary() else { return nil }
        while let op = consumeOp(["==", "===", "=", "!=", "!==", "<", "<=", ">", ">="]) {
            guard let rhs = parseUnary() else { return nil }
            let comparison: PropertyCondition.Comparison
            switch op {
            case "!=", "!==": comparison = .notEqual
            case "<": comparison = .less
            case "<=": comparison = .lessOrEqual
            case ">": comparison = .greater
            case ">=": comparison = .greaterOrEqual
            default: comparison = .equal
            }
            lhs = .compare(lhs, comparison, rhs)
        }
        return lhs
    }

    private mutating func parseUnary() -> PropertyCondition.Expression? {
        if consumeOp(["!"]) != nil {
            return parseUnary().map { .not($0) }
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> PropertyCondition.Expression? {
        guard let token = current else { return nil }
        index += 1
        switch token {
        case .number(let number):
            return .literal(.number(number))
        case .string(let string):
            return .literal(.string(string))
        case .identifier(let name):
            switch name {
            case "true": return .literal(.bool(true))
            case "false": return .literal(.bool(false))
            case "undefined", "null": return .literal(.undefined)
            default:
                let parts = name.split(separator: ".", omittingEmptySubsequences: false)
                guard let key = parts.first, !key.isEmpty,
                      parts.count == 1 || (parts.count == 2 && parts[1] == "value") else { return nil }
                return .property(String(key))
            }
        case .leftParen:
            guard let inner = parseOr(), current == .rightParen else { return nil }
            index += 1
            return inner
        case .rightParen, .op:
            return nil
        }
    }
}
