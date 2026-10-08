import Foundation
import NativeSceneCore

/// Property types defined in Wallpaper Engine's project.json schema.
enum WEPropertyType: String, Sendable {
    case slider
    case bool
    case color
    case combo
    case text          // read-only label, not editable
    case textinput
    case file
    case scenetexture
    case group         // section header; following properties belong to it
    case usershortcut  // Windows app-launcher shortcut; not applicable on macOS

    /// Parse an authored type name. Wallpapers in the wild use `Text`, `label`
    /// and empty types for informational labels.
    init?(authored raw: String?) {
        switch raw?.lowercased() {
        case "label", "", nil: self = .text
        case let name?: self.init(rawValue: name)
        }
    }

    /// Whether the property carries a user value (as opposed to layout or a label).
    var holdsValue: Bool {
        switch self {
        case .text, .group, .usershortcut: return false
        default: return true
        }
    }
}

/// A selectable option for a `combo` property.
struct WEPropertyOption: Equatable, Sendable {
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
struct WallpaperProperty: Identifiable, Sendable {
    var id: String { key }

    let key: String
    var type: WEPropertyType
    /// Human-readable display label.
    let text: String
    /// Sort order from project.json; properties with no order get 999.
    let order: Int
    /// Default value in canonical string form.
    var defaultValue: String

    // Slider-specific
    let min: Double?
    let max: Double?
    let step: Double?
    let precision: Int?

    // Combo-specific
    let options: [WEPropertyOption]?
    /// Numeric combo values must remain numbers when sent to web wallpapers.
    var usesNumericComboValues: Bool = false
    /// Show the control only while this holds; nil means always visible.
    var condition: PropertyCondition? = nil
}

// MARK: - Parsing

extension WallpaperProperty {
    func applyingPresetValue(_ value: Any, directory: URL) throws -> WallpaperProperty {
        var property = self
        property.defaultValue = Self.canonicalize(value, type: type)
        if (type == .file || type == .scenetexture), let path = value as? String,
           path.replacingOccurrences(of: "\\", with: "/").hasPrefix("files/") {
            let root = directory.resolvingSymlinksInPath().standardizedFileURL
            let url = root.appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/")).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw WallpaperError.invalidPreset(directory) }
            property.defaultValue = url.path
        }
        return property
    }

    /// Parse the `"properties"` block from a project.json `Data` blob.
    /// Returns an empty array when the key is absent or the format is unexpected.
    static func parse(from data: Data) -> [WallpaperProperty] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let general = json["general"] as? [String: Any]
        let block = (general?["properties"] as? [String: Any]) ?? (json["properties"] as? [String: Any]) ?? [:]

        var result: [WallpaperProperty] = []
        for (key, raw) in block {
            guard let dict = raw as? [String: Any],
                  let propType = WEPropertyType(authored: dict["type"] as? String) else { continue }
            // An untyped entry is only meaningful as a label.
            if dict["type"] == nil && dict["text"] == nil { continue }

            let text = displayLabel(dict["text"] as? String ?? key, key: key)
            let order = (dict["order"] ?? dict["index"]) as? Int ?? 999

            var options: [WEPropertyOption]?
            if let optArr = dict["options"] as? [[String: Any]] {
                options = optArr.compactMap { opt in
                    guard let v = scalarString(opt["value"]) else { return nil }
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
                options:   options,
                usesNumericComboValues: propType == .combo && dict["value"] is NSNumber && !isBool(dict["value"] as Any),
                condition: (dict["condition"] as? String).flatMap(PropertyCondition.init)
            ))
        }

        return result.sorted { ($0.order, $0.text, $0.key) < ($1.order, $1.text, $1.key) }
    }

    // MARK: Private helpers

    /// WE uses unresolved i18n keys like "ui_browse_properties_scheme_color" for
    /// some built-in properties. Convert them to a readable form.
    static func displayLabel(_ raw: String, key: String) -> String {
        let prefix = "ui_browse_properties_"
        if raw.hasPrefix(prefix) { return humanize(String(raw.dropFirst(prefix.count))) }
        return raw.hasPrefix("ui_") ? humanize(key) : raw
    }

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
            if let string = raw as? String {
                return ["1", "true", "yes", "on"].contains(string.lowercased()) ? "1" : "0"
            }
            return isBool(raw) ? ((raw as! Bool) ? "1" : "0")
                               : (toDouble(raw) != 0 ? "1" : "0")
        case .color:
            return (raw as? String).map { normalizeColorString($0) } ?? "1 1 1"
        case .combo:
            return scalarString(raw) ?? ""
        case .textinput, .file, .scenetexture, .text, .group, .usershortcut:
            return raw as? String ?? ""
        }
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber, !isBool(number) { return number.stringValue }
        return nil
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

extension WallpaperProperty {
    init(nativeProperty: UserProperty) {
        self.init(
            key: nativeProperty.key,
            type: WEPropertyType(nativeProperty: nativeProperty.type),
            text: nativeProperty.label.isEmpty ? nativeProperty.key : Self.displayLabel(nativeProperty.label, key: nativeProperty.key),
            order: nativeProperty.order,
            defaultValue: Self.canonicalString(from: nativeProperty.defaultValue, type: nativeProperty.type),
            min: nativeProperty.minimum,
            max: nativeProperty.maximum,
            step: nativeProperty.step,
            precision: nativeProperty.precision,
            options: nativeProperty.options.map { WEPropertyOption(value: $0.value, label: $0.label) }
        )
    }

    private static func canonicalString(from value: DynamicValueDescriptor?, type: UserPropertyKind) -> String {
        guard let value else {
            switch type {
            case .slider:
                return "0"
            case .bool:
                return "0"
            case .color:
                return "1 1 1"
            default:
                return ""
            }
        }

        switch (type, value.value) {
        case (.slider, .float(let scalar)):
            return String(format: "%g", scalar)
        case (.slider, .int(let scalar)):
            return String(scalar)
        case (.bool, .bool(let flag)):
            return flag ? "1" : "0"
        case (.bool, .int(let scalar)):
            return scalar == 0 ? "0" : "1"
        case (.color, .vec3(let components)):
            return colorString(from: components)
        case (.color, .vec4(let components)):
            return colorString(from: Array(components.prefix(3)))
        case (_, .string(let string)):
            return string
        case (_, .float(let scalar)):
            return String(format: "%g", scalar)
        case (_, .int(let scalar)):
            return String(scalar)
        case (_, .bool(let flag)):
            return flag ? "1" : "0"
        case (_, .vec2(let values)):
            return values.map { String(format: "%g", $0) }.joined(separator: " ")
        case (_, .vec3(let values)):
            return values.map { String(format: "%g", $0) }.joined(separator: " ")
        case (_, .vec4(let values)):
            return values.map { String(format: "%g", $0) }.joined(separator: " ")
        case (_, .ivec2(let values)):
            return values.map(String.init).joined(separator: " ")
        case (_, .ivec3(let values)):
            return values.map(String.init).joined(separator: " ")
        case (_, .ivec4(let values)):
            return values.map(String.init).joined(separator: " ")
        case (_, .null):
            return ""
        }
    }

    private static func colorString(from values: [Double]) -> String {
        let normalized = Array(values.prefix(3))
        return normalized.map { String(format: "%g", $0) }.joined(separator: " ")
    }
}

private extension WEPropertyType {
    init(nativeProperty kind: UserPropertyKind) {
        switch kind {
        case .slider:
            self = .slider
        case .bool:
            self = .bool
        case .color:
            self = .color
        case .combo:
            self = .combo
        case .text:
            self = .text
        case .textinput:
            self = .textinput
        case .file:
            self = .file
        case .scenetexture:
            self = .scenetexture
        case .unknown:
            self = .text
        }
    }
}

// MARK: - Layout Merge

extension WallpaperProperty {
    /// Scene properties come from the native scene parser, which keeps value
    /// semantics but drops layout: `condition`, `group` headers and untyped
    /// labels. Re-attach those from the app's own parse of the same project.json.
    static func mergingLayout(native: [WallpaperProperty], authored: [WallpaperProperty]) -> [WallpaperProperty] {
        let authoredByKey = Dictionary(authored.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = native.map { property -> WallpaperProperty in
            guard let layout = authoredByKey[property.key] else { return property }
            var property = property
            property.condition = layout.condition
            if !layout.type.holdsValue { property.type = layout.type }
            return property
        }
        let nativeKeys = Set(native.map(\.key))
        merged += authored.filter { !nativeKeys.contains($0.key) && !$0.type.holdsValue }
        return merged.sorted { ($0.order, $0.text, $0.key) < ($1.order, $1.text, $1.key) }
    }

    /// The value a condition expression sees for this property.
    func conditionValue(_ stored: String?) -> PropertyCondition.Value {
        let value = stored ?? defaultValue
        switch type {
        case .bool:
            return .bool(["1", "true", "yes", "on"].contains(value.lowercased()))
        case .slider:
            return .number(Double(value) ?? 0)
        case .combo where usesNumericComboValues:
            return .number(Double(value) ?? 0)
        default:
            return .string(value)
        }
    }

    /// Whether this control is visible given every property's current value.
    static func isVisible(_ property: WallpaperProperty, among properties: [String: WallpaperProperty], values: [String: String]) -> Bool {
        guard let condition = property.condition else { return true }
        return condition.isSatisfied { key in
            properties[key].map { $0.conditionValue(values[key]) } ?? .undefined
        }
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
        Self.jsonString(javaScriptValue(from: storedValue))
    }

    private func javaScriptValue(from storedValue: String) -> Any {
        switch type {
        case .slider:
            let value = Double(storedValue) ?? Double(defaultValue) ?? 0
            return value.isFinite ? value : 0
        case .bool:
            return ["1", "true", "yes", "on"].contains(storedValue.lowercased())
        case .combo where usesNumericComboValues:
            let value = Double(storedValue) ?? Double(defaultValue) ?? 0
            return value.isFinite ? value : 0
        default:
            return storedValue
        }
    }

    /// Serialize the complete event as JSON so keys and values cannot alter its JavaScript.
    static func javaScriptPayload(properties: [WallpaperProperty], values: [String: String]) -> String {
        var payload: [String: [String: Any]] = [:]
        for property in properties where property.type.holdsValue {
            let value = values[property.key] ?? property.defaultValue
            var entry: [String: Any] = ["value": property.javaScriptValue(from: value)]
            if property.type == .combo,
               let option = property.options?.first(where: { $0.value == value }) {
                entry["text"] = option.label
            }
            payload[property.key] = entry
        }
        return jsonString(payload)
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return json
    }
}
