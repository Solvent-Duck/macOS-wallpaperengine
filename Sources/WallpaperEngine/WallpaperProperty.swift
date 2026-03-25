import Foundation

/// Property types defined in Wallpaper Engine's project.json schema.
enum WEPropertyType: String {
    case slider
    case bool
    case color
    case combo
    case text          // read-only label, not editable
    case textinput
    case file
    case scenetexture
}

/// A selectable option for a `combo` property.
struct WEPropertyOption: Equatable {
    let value: String
    let label: String
}

/// A user-configurable property parsed from a wallpaper's project.json.
///
/// Values are always stored as strings in a canonical format:
/// - `slider`    — decimal number, e.g. `"0.5"`
/// - `bool`      — `"1"` or `"0"`
/// - `color`     — space-separated 0–1 floats, e.g. `"1 0.5 0.2"`
/// - `combo`     — the option's value key, e.g. `"mode_a"`
/// - `textinput` — the raw string
struct WallpaperProperty: Identifiable {
    var id: String { key }

    let key: String
    let type: WEPropertyType
    /// Human-readable display label.
    let text: String
    /// Sort order from project.json; properties with no order get 999.
    let order: Int
    /// Default value in canonical string form.
    let defaultValue: String

    // Slider-specific
    let min: Double?
    let max: Double?
    let step: Double?
    let precision: Int?

    // Combo-specific
    let options: [WEPropertyOption]?
}

// MARK: - Parsing

extension WallpaperProperty {
    /// Parse the `"properties"` block from a project.json `Data` blob.
    /// Returns an empty array when the key is absent or the format is unexpected.
    static func parse(from data: Data) -> [WallpaperProperty] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["properties"] as? [String: Any] else { return [] }

        var result: [WallpaperProperty] = []
        for (key, raw) in block {
            guard let dict = raw as? [String: Any],
                  let typeStr = dict["type"] as? String,
                  let propType = WEPropertyType(rawValue: typeStr) else { continue }

            let rawLabel = dict["text"] as? String ?? key
            // WE uses unresolved i18n keys like "ui_browse_properties_scheme_color" for some
            // built-in properties. Convert them to a readable form.
            let text = rawLabel.hasPrefix("ui_") ? humanize(key) : rawLabel
            let order = dict["order"] as? Int ?? 999

            var options: [WEPropertyOption]?
            if let optArr = dict["options"] as? [[String: Any]] {
                options = optArr.compactMap { opt in
                    guard let v = opt["value"] as? String else { return nil }
                    let label = opt["label"] as? String ?? v
                    return WEPropertyOption(value: v, label: label)
                }
            }

            result.append(WallpaperProperty(
                key: key,
                type: propType,
                text: text,
                order: order,
                defaultValue: canonicalize(dict["value"], type: propType),
                min:       dict["min"]       as? Double,
                max:       dict["max"]       as? Double,
                step:      dict["step"]      as? Double,
                precision: dict["precision"] as? Int,
                options:   options
            ))
        }

        return result.sorted { ($0.order, $0.text) < ($1.order, $1.text) }
    }

    // MARK: Private helpers

    /// Convert a snake_case property key to a Title Case label.
    private static func humanize(_ key: String) -> String {
        key.components(separatedBy: CharacterSet(charactersIn: "_- "))
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Serialize a raw JSON value to its canonical storage string for a given type.
    private static func canonicalize(_ raw: Any?, type: WEPropertyType) -> String {
        guard let raw else { return fallback(for: type) }
        switch type {
        case .slider:
            return String(format: "%g", toDouble(raw))
        case .bool:
            return isBool(raw) ? ((raw as! Bool) ? "1" : "0")
                               : (toDouble(raw) != 0 ? "1" : "0")
        case .color:
            return (raw as? String).map { normalizeColorString($0) } ?? "1 1 1"
        case .combo, .textinput, .file, .scenetexture, .text:
            return raw as? String ?? ""
        }
    }

    private static func fallback(for type: WEPropertyType) -> String {
        switch type {
        case .slider: return "0"
        case .bool:   return "0"
        case .color:  return "1 1 1"
        default:      return ""
        }
    }

    /// Distinguish a JSON boolean from a JSON number via CoreFoundation type ID.
    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func toDouble(_ v: Any) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String   { return Double(s) ?? 0 }
        return 0
    }
}

// MARK: - Color Utilities

extension WallpaperProperty {
    /// Normalize any color string to space-separated 0–1 floats (`"r g b"`).
    /// Handles `#RRGGBB` hex, 0–255 integer triples, and 0–1 float triples.
    static func normalizeColorString(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)

        // Hex: #RRGGBB or RRGGBB
        let hex = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if hex.count == 6, let v = UInt32(hex, radix: 16) {
            let r = Double((v >> 16) & 0xFF) / 255
            let g = Double((v >>  8) & 0xFF) / 255
            let b = Double( v        & 0xFF) / 255
            return String(format: "%g %g %g", r, g, b)
        }

        let parts = t.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return "1 1 1" }

        // Detect 0–255 range
        if parts[0] > 1 || parts[1] > 1 || parts[2] > 1 {
            return String(format: "%g %g %g", parts[0]/255, parts[1]/255, parts[2]/255)
        }
        return String(format: "%g %g %g", parts[0], parts[1], parts[2])
    }

    /// Parse a stored color string to (r, g, b) in 0–1 range.
    static func colorComponents(from s: String) -> (r: Double, g: Double, b: Double)? {
        let parts = s.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// Serialize RGB 0–1 components to the storage string format.
    static func colorString(r: Double, g: Double, b: Double) -> String {
        String(format: "%g %g %g", r, g, b)
    }
}

// MARK: - JS Encoding

extension WallpaperProperty {
    /// Encode a stored value as a JavaScript literal for use in `applyUserProperties`.
    ///
    /// WE wallpapers expect each entry as `{ value: <jsLiteral> }`:
    /// - slider → number literal
    /// - bool   → `true` / `false`
    /// - color  → quoted string `"r g b"`
    /// - others → quoted string
    func jsLiteral(from storedValue: String) -> String {
        switch type {
        case .slider:
            return storedValue.isEmpty ? "0" : storedValue
        case .bool:
            return storedValue == "1" ? "true" : "false"
        default:
            // JSON-safe string escaping
            let esc = storedValue
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(esc)\""
        }
    }
}
