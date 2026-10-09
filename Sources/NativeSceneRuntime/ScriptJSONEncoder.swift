import CoreFoundation
import Foundation

/// Fast JSON encoding for the values the script host sends to QuickJS every
/// call. It accepts what `JSONSerialization` accepts for these payloads
/// (null, booleans, numbers, strings, arrays and string-keyed dictionaries)
/// and sorts keys the same way, so scripts see the same values in the same
/// key order. Anything else, including non-finite numbers and non-ASCII keys,
/// returns nil so the caller falls back to `JSONSerialization` and keeps its
/// behaviour and errors. Not thread-safe: each script host owns one.
struct ScriptJSONEncoder {
    /// `JSONSerialization` sorts keys with `localizedStandardCompare`, which
    /// is too slow to run per call; payloads reuse a few key sets.
    private var keyOrders: [[String]: [String]?] = [:]

    mutating func encode(_ value: Any) -> String? {
        var output = ""
        output.reserveCapacity(128)
        return append(value, to: &output) ? output : nil
    }

    private mutating func sortedKeys(_ keys: Dictionary<String, Any>.Keys) -> [String]? {
        let signature = keys.sorted()
        if let cached = keyOrders[signature] { return cached }
        var order: [String]? = nil
        if signature.allSatisfy({ $0.utf8.allSatisfy { $0 < 0x80 } }) {
            let sorted = signature.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            // Ties (e.g. "a1" and "a01") have no known JSONSerialization order.
            let hasTie = zip(sorted, sorted.dropFirst()).contains { $0.localizedStandardCompare($1) == .orderedSame }
            order = hasTie ? nil : sorted
        }
        if keyOrders.count > 4096 { keyOrders.removeAll() }
        keyOrders[signature] = order
        return order
    }

    private mutating func append(_ value: Any, to output: inout String) -> Bool {
        if value is NSNull {
            output += "null"
            return true
        }
        if let string = value as? String {
            Self.appendString(string, to: &output)
            return true
        }
        if let number = value as? NSNumber {
            return Self.appendNumber(number, to: &output)
        }
        if let array = value as? [Any] {
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                guard append(element, to: &output) else { return false }
            }
            output += "]"
            return true
        }
        if let dictionary = value as? [String: Any] {
            guard let keys = sortedKeys(dictionary.keys) else { return false }
            output += "{"
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                Self.appendString(key, to: &output)
                output += ":"
                guard append(dictionary[key]!, to: &output) else { return false }
            }
            output += "}"
            return true
        }
        return false
    }

    private static func appendNumber(_ number: NSNumber, to output: inout String) -> Bool {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            output += number.boolValue ? "true" : "false"
            return true
        }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            guard double.isFinite else { return false }
            // Swift prints the shortest representation that round-trips, so
            // JS parses exactly the same double.
            output += double.description
            return true
        }
        output += number.stringValue
        return true
    }

    private static func appendString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case let control where control.value < 0x20:
                output += "\\u00"
                output += String(control.value, radix: 16).leftPadded(to: 2)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
