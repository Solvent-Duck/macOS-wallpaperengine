import Foundation
import Testing
@testable import WallpaperEngine

struct PropertyLayoutTests {
    private func parse(_ properties: [String: Any]) throws -> [WallpaperProperty] {
        WallpaperProperty.parse(from: try JSONSerialization.data(withJSONObject: ["general": ["properties": properties]]))
    }

    @Test func authoredTypeSpellingsAreKept() throws {
        let properties = try parse([
            "header": ["type": "group", "text": "Clock", "order": 1],
            "credit": ["type": "Text", "text": "<b>Thanks</b>", "order": 2],
            "note": ["type": "label", "text": "Note", "order": 3],
            "blank": ["type": "", "text": "Blank", "order": 4],
            "untyped": ["text": "Untyped", "index": 5],
            "launcher": ["type": "usershortcut", "text": "#1", "order": 6],
            "scheme": ["type": "color", "text": "ui_browse_properties_scheme_color", "value": "1 0 0", "order": 0],
            "nothing": ["order": 7],
        ])
        #expect(properties.map(\.key) == ["scheme", "header", "credit", "note", "blank", "untyped", "launcher"])
        #expect(properties.map(\.type) == [.color, .group, .text, .text, .text, .text, .usershortcut])
        #expect(properties.first?.text == "Scheme Color")
        #expect(properties.filter(\.type.holdsValue).map(\.key) == ["scheme"])
    }

    @Test func nativeScenePropertiesRegainLayout() throws {
        let authored = try parse([
            "effects": ["type": "group", "text": "Effects", "order": 1],
            "snow": ["type": "bool", "text": "Snow", "value": true, "order": 2],
            "amount": ["type": "slider", "text": "Amount", "value": 0.5, "order": 3, "condition": "snow.value == true"],
            "launcher": ["type": "usershortcut", "text": "#1", "order": 4],
        ])
        // The native parser drops groups and maps usershortcut to text.
        var native = authored.filter { $0.type != .group }.map { property -> WallpaperProperty in
            var property = property
            property.condition = nil
            if property.type == .usershortcut { property.type = .text }
            return property
        }
        native[1].defaultValue = "0.75" // native value semantics must win
        let merged = WallpaperProperty.mergingLayout(native: native, authored: authored)
        #expect(merged.map(\.key) == ["effects", "snow", "amount", "launcher"])
        #expect(merged[2].condition != nil && merged[2].defaultValue == "0.75")
        #expect(merged[3].type == .usershortcut)

        let byKey = Dictionary(uniqueKeysWithValues: merged.map { ($0.key, $0) })
        #expect(WallpaperProperty.isVisible(merged[2], among: byKey, values: ["snow": "1"]))
        #expect(!WallpaperProperty.isVisible(merged[2], among: byKey, values: ["snow": "0"]))
    }

    @Test func groupsSplitSectionsAndShortcutsAreOmitted() throws {
        let properties = try parse([
            "scheme": ["type": "color", "value": "1 1 1", "order": 0],
            "clock": ["type": "group", "text": "Clock", "order": 1],
            "enable": ["type": "bool", "value": true, "order": 2],
            "launcher": ["type": "usershortcut", "order": 3],
            "bars": ["type": "group", "text": "Bars", "order": 4],
            "height": ["type": "slider", "value": 1, "order": 5],
        ])
        let sections = PropertyLayout.sections(properties)
        #expect(sections.map { $0.header?.key } == [nil, "clock", "bars"])
        #expect(sections.map { $0.items.map(\.key) } == [["scheme"], ["enable"], ["height"]])
    }

    @Test func htmlLabelsBecomeReadableTextWithLinks() throws {
        let label = try #require(PropertyLayout.labelText(
            "<center><h3><b>Like it?</b></h3><br>Rate &amp; share!\u{200E}<a href='https://example.com/x'>Donate</a></center>"
        ))
        #expect(String(label.characters) == "Like it?\nRate & share!Donate")
        #expect(label.runs.contains { $0.link == URL(string: "https://example.com/x") })
        #expect(PropertyLayout.labelText("<hr><center><a href='https://x'><img src='q.png'></a></center>").map { String($0.characters) } == "x")
        #expect(PropertyLayout.labelText("<br> \u{200E} <hr>") == nil)
        #expect(PropertyLayout.labelText("<a href='javascript:alert(1)'>Run</a>").map { String($0.characters) } == "Run")
        #expect(PropertyLayout.labelText("<a href='javascript:alert(1)'>Run</a>")?.runs.allSatisfy { $0.link == nil } == true)
    }

    @MainActor @Test func legacyPathKeyedSettingsMigrateToFolderName() throws {
        let suite = "PropertyLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var project = WallpaperProject(title: "T", type: .scene, file: "scene.json", preview: nil, description: nil, tags: nil)
        project.directoryURL = URL(fileURLWithPath: "/Library/Steam/431960/123456")
        defaults.set(["clock": "1"], forKey: "WallpaperProperties./Library/Steam/431960/123456")

        #expect(DesktopWindowManager.loadPropertyValues(for: project, defaults: defaults) == ["clock": "1"])
        #expect(defaults.dictionary(forKey: "WallpaperProperties.123456") as? [String: String] == ["clock": "1"])
        #expect(defaults.object(forKey: "WallpaperProperties./Library/Steam/431960/123456") == nil)

        // A copy of the same wallpaper elsewhere shares its settings.
        project.directoryURL = URL(fileURLWithPath: "/Users/me/Wallpaper Projects/123456")
        #expect(DesktopWindowManager.loadPropertyValues(for: project, defaults: defaults) == ["clock": "1"])
    }
}
