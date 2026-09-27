import Foundation
import Testing
@testable import WallpaperEngine

struct WallpaperPropertyTests {
    @Test func nestedPropertiesPreserveTypesOptionsAndStableOrdering() throws {
        let properties = WallpaperProperty.parse(from: Data(#"""
        {"properties":{"ignored":{"type":"slider","value":9}},"general":{"properties":{
          "mode":{"type":"combo","text":"Mode","order":1,"value":2,"options":[{"value":1,"label":"First"},{"value":2,"label":"Second"}]},
          "stringmode":{"type":"combo","order":2,"value":"02","options":[{"value":"02","label":"Leading zero"}]},
          "enabled":{"type":"bool","order":3,"value":"true"},
          "z":{"type":"slider","text":"Same","value":4},"a":{"type":"slider","text":"Same","value":3}
        }}}
        """#.utf8))
        #expect(properties.map(\.key) == ["mode", "stringmode", "enabled", "a", "z"])
        #expect(properties[0].defaultValue == "2")
        #expect(properties[0].options?.map(\.value) == ["1", "2"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(WallpaperProperty.javaScriptPayload(properties: properties, values: [:]).utf8)) as? [String: [String: Any]])
        #expect(payload["mode"]?["value"] as? Int == 2)
        #expect(payload["mode"]?["text"] as? String == "Second")
        #expect(payload["stringmode"]?["value"] as? String == "02")
        #expect(payload["enabled"]?["value"] as? Bool == true)
    }

    @Test func propertyEventsSafelyEncodeKeysStringsAndInvalidNumbers() throws {
        let key = "text\t\"\n"
        let value = "quotes \" slash \\ tab\t newline\ncontrol\u{1} end"
        let data = try JSONSerialization.data(withJSONObject: ["properties": [
            key: ["type": "textinput", "value": ""],
            "speed": ["type": "slider", "value": 2],
            "label": ["type": "text", "value": "label"]
        ]])
        let properties = WallpaperProperty.parse(from: data)
        let json = WallpaperProperty.javaScriptPayload(properties: properties, values: [key: value, "speed": "0});throw 'injected';//"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
        #expect(payload[key]?["value"] as? String == value)
        #expect(payload["speed"]?["value"] as? Int == 2)
        #expect(payload["label"] == nil)
        let slider = try #require(properties.first(where: { $0.key == "speed" }))
        #expect(slider.jsLiteral(from: "nan") == "0")
        #expect(slider.jsLiteral(from: "inf") == "0")
    }
}
