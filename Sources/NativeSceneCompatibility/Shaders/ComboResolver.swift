import Foundation

public enum ComboResolver {
    public static func textureCombos(in sources: [String], textureSlots: Set<Int>) -> [String: Int] {
        let pattern = #"\buniform\s+(?:(?:lowp|mediump|highp)\s+)?sampler\w*\s+g_Texture(\d+)\s*;\s*//\s*(\{.*\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: Int] = [:]
        for source in sources {
            for line in source.split(whereSeparator: \.isNewline).map(String.init) {
                guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                      let slotRange = Range(match.range(at: 1), in: line), let slot = Int(line[slotRange]),
                      let metadataRange = Range(match.range(at: 2), in: line),
                      let metadata = try? ShaderMetadata.parseObject(String(line[metadataRange])),
                      let combo = metadata["combo"] as? String else { continue }
                // An absent optional texture leaves its feature undefined.
                // Defining it as zero still enables authored #ifdef branches
                // (generic4 mixes #ifdef NORMALMAP with #if NORMALMAP).
                if textureSlots.contains(slot) { result[combo] = 1 }
            }
        }
        return result
    }

    public static func discoverCombos(
        in sources: [String],
        combos: [String: Int],
        overrideCombos: [String: Int]
    ) -> [String: Int] {
        var discovered: [String: Int] = [:]

        for source in sources {
            for line in source.split(whereSeparator: \.isNewline) {
                guard let range = line.range(of: "// [COMBO] ") else {
                    continue
                }

                let metadataContent = String(line[range.upperBound...])
                guard ShaderMetadata.looksLikeMetadata(metadataContent) else {
                    continue
                }

                guard
                    let metadata = try? ShaderMetadata.parseObject(metadataContent),
                    let comboName = metadata["combo"] as? String
                else {
                    continue
                }

                if combos[comboName] != nil || overrideCombos[comboName] != nil {
                    continue
                }

                discovered[comboName] = parseDefaultValue(from: metadata["default"])
            }
        }

        return discovered
    }

    public static func defineBlock(
        combos: [String: Int],
        overrideCombos: [String: Int],
        discoveredCombos: [String: Int]
    ) -> String {
        var addedNames = Set<String>()
        var lines: [String] = []

        func appendDefines(from source: [String: Int]) {
            for key in source.keys.sorted() {
                let defineName = key.uppercased()
                guard addedNames.insert(defineName).inserted, let value = source[key] else {
                    continue
                }

                lines.append("#define \(defineName) \(value)")
            }
        }

        appendDefines(from: overrideCombos)
        appendDefines(from: combos)
        appendDefines(from: discoveredCombos)

        guard !lines.isEmpty else {
            return ""
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseDefaultValue(from rawValue: Any?) -> Int {
        guard let rawValue else {
            return 0
        }

        if let number = rawValue as? NSNumber {
            return number.intValue
        }

        if let string = rawValue as? String {
            return Int(string) ?? 0
        }

        return 0
    }
}
