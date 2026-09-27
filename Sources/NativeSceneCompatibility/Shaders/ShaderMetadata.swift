import Foundation

enum ShaderMetadata {
    static func looksLikeMetadata(_ content: String) -> Bool {
        guard let first = content.first(where: { !$0.isWhitespace }) else {
            return false
        }

        return first == "{" || first == "["
    }

    static func parseObject(_ content: String) throws -> [String: Any] {
        func parse(_ candidate: String) throws -> [String: Any] {
            let data = Data(candidate.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw ShaderPipelineError.invalidMetadata(content)
            }
            return dictionary
        }

        do {
            return try parseRelaxedJSON(content)
        } catch {
            let requoted = quoteBareKeys(in: content)
            return try parseRelaxedJSON(requoted)
        }
    }

    private static func parseRelaxedJSON(_ content: String) throws -> [String: Any] {
        do {
            return try parseJSONObject(content)
        } catch {
            return try parseJSONObject(stripTrailingCommas(in: content))
        }
    }

    private static func parseJSONObject(_ content: String) throws -> [String: Any] {
        let data = Data(content.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ShaderPipelineError.invalidMetadata(content)
        }
        return dictionary
    }

    private static func quoteBareKeys(in content: String) -> String {
        let pattern = #"([\{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return content
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: #"$1"$2"$3"#)
    }

    private static func stripTrailingCommas(in content: String) -> String {
        var result = String()
        result.reserveCapacity(content.count)

        var isInString = false
        var isEscaped = false
        let scalars = Array(content)
        var index = 0

        while index < scalars.count {
            let character = scalars[index]

            if isEscaped {
                result.append(character)
                isEscaped = false
                index += 1
                continue
            }

            if character == "\\" {
                result.append(character)
                isEscaped = true
                index += 1
                continue
            }

            if character == "\"" {
                isInString.toggle()
                result.append(character)
                index += 1
                continue
            }

            if !isInString, character == "," {
                var lookahead = index + 1
                while lookahead < scalars.count, scalars[lookahead].isWhitespace {
                    lookahead += 1
                }

                if lookahead < scalars.count, scalars[lookahead] == "]" || scalars[lookahead] == "}" {
                    index += 1
                    continue
                }
            }

            result.append(character)
            index += 1
        }

        return result
    }
}
