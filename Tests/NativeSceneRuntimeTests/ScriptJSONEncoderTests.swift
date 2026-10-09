import Foundation
@testable import NativeSceneRuntime
import Testing

struct ScriptJSONEncoderTests {
    private func reference(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func parsed(_ json: String) throws -> NSObject {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as! NSObject
    }

    @Test func matchesJSONSerializationValuesAndKeyOrder() throws {
        let parsedNumbers = try JSONSerialization.jsonObject(with: Data(#"{"a":1,"b":2.5,"c":true}"#.utf8))
        let samples: [Any] = [
            NSNull(), true, false, 0, -42, Int64.max, 0.1, -0.0, 1e-7, 1e21, Float(0.1), 3.0,
            "plain", "quote\" backslash\\ slash/ newline\n tab\t cr\r bell\u{07} snowman ☃ emoji 🎈",
            [1, "two", [3.5, NSNull()], ["nested": false]] as [Any],
            ["zeta": 1, "Alpha": 2, "_under": 3, "alpha": ["y": 1, "x": 2]] as [String: Any],
            parsedNumbers,
        ]
        for sample in samples {
            var encoder = ScriptJSONEncoder()
            let result = encoder.encode(sample)
            let encoded = try #require(result)
            #expect(try parsed(encoded) == parsed(reference(sample)), "\(sample)")
        }
        var encoder = ScriptJSONEncoder()
        let keyed: [String: Any] = Dictionary(uniqueKeysWithValues: ["b", "B", "a", "A", "_", "__x", "-a", "9", "10", "a b",
            "a_", "a-b", "a.b", "a1", "a01", "a2", "a10", "ab", "G", "g_time", "g_Time", "x_y", "xY", "z", "Z"].map { ($0, 1 as Any) })
        let expected = try reference(keyed)
        let first = encoder.encode(keyed), second = encoder.encode(keyed)
        #expect(first == expected)
        #expect(second == expected, "cached order")
    }

    @Test func leavesUnsupportedValuesToJSONSerialization() {
        var encoder = ScriptJSONEncoder()
        let results = [encoder.encode(Double.nan), encoder.encode(["x": Double.infinity]), encoder.encode(["ключ": 1]),
                       encoder.encode(Date())]
        #expect(results.allSatisfy { $0 == nil })
    }
}
