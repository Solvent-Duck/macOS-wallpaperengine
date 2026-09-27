import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptAssetTests {
    @Test func registeredFontCanBeReturnedFromAFontPropertyScript() throws {
        let root = try fixture(font: ["value": "Helvetica", "script": """
        const font = engine.registerAsset('fonts/Custom.ttf');
        export function update() { return font; }
        """])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SceneRuntime(scene: try load(root), textLayouts: TextLayoutEngine(assetRoots: [root]))
        let frame = try #require(runtime.step(deltaTime: 0).texts.first)
        #expect(frame.fontPath == "fonts/Custom.ttf")
        #expect(frame.size.x > 0 && frame.size.y > 0)
    }

    @Test func sharedHandlesSelectFontsAndRefreshWhilePaused() throws {
        let root = try fixture(controller: """
        shared.font = engine.registerAsset('fonts/Custom.ttf');
        const alternate = engine.registerAsset('fonts/Alternate.ttf');
        const layer = thisScene.getLayer('Text');
        export function applyUserProperties(changed) {
            if ('choice' in changed) layer.font = changed.choice === 1 ? alternate : shared.font;
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SceneRuntime(scene: try load(root), textLayouts: TextLayoutEngine(assetRoots: [root]))
        let initial = try #require(runtime.step(deltaTime: 0).texts.first)
        #expect(initial.fontPath == "fonts/Custom.ttf")
        runtime.setPaused(true)
        let changed = try #require(runtime.step(deltaTime: 1, propertyOverrides: ["choice": .int(1)]).texts.first)
        #expect(changed.fontPath == "fonts/Alternate.ttf")
        #expect(changed.size.x != initial.size.x && runtime.elapsedTime == 0)
        #expect(runtime.step(deltaTime: 1, propertyOverrides: ["choice": .int(1)]).texts.first?.fontPath == changed.fontPath)
    }

    @Test func handlesSurviveAcrossScriptModulesAndPreserveRelativeUnicodePaths() throws {
        let host = ScriptHost()
        _ = try host.evaluate(source: "const font = engine.registerAsset('fonts/workshop/123/字体 File.ttf'); export function update() { shared.font = font; return 1; }",
                              baseValue: .int(0), properties: [:], instanceID: "producer")
        let source = "export function update() { return shared.font; }"
        for _ in 0..<2 {
            #expect(try host.evaluate(source: source, baseValue: .string(""), properties: [:], instanceID: "consumer") == .string("fonts/workshop/123/字体 File.ttf"))
        }
    }

    @Test func windowsPathSeparatorsResolveToTheSameFontPath() throws {
        let host = ScriptHost()
        let source = #"""
        const font = engine.registerAsset('fonts\\workshop\\123\\Custom Font.ttf');
        export function update() { return font; }
        """#
        #expect(try host.evaluate(source: source, baseValue: .string(""), properties: [:]) == .string("fonts/workshop/123/Custom Font.ttf"))
    }

    @Test func registeredHandlesWorkInStandaloneSceneCallbacks() throws {
        let host = ScriptHost()
        let values = try host.executeSceneCallback(source: """
        const font = engine.registerAsset('fonts/Callback.ttf');
        export function init() { thisObject.font = font; }
        """, callback: .initialize, thisObject: ["font": .string("Helvetica")], changedUserProperties: [:],
        engine: SceneScriptEngineState(runtime: 0, screenResolution: RuntimeVector2(x: 128, y: 128)),
        input: SceneScriptInputState(cursorPosition: nil))
        #expect(values["font"] == .string("fonts/Callback.ttf"))
    }

    @Test func invalidAssetPathsAreRejectedWithoutBreakingLaterRegistration() throws {
        let host = ScriptHost()
        let source = #"""
        const invalid = ['', '/tmp/font.ttf', '../font.ttf', 'fonts/../font.ttf', 'C:\\fonts\\font.ttf', 'https://example.invalid/font.ttf', 'fonts/a\0.ttf', null];
        let rejected = 0;
        for (const file of invalid) {
            try { engine.registerAsset(file); } catch (error) { rejected++; }
        }
        const valid = engine.registerAsset('fonts/Valid.ttf');
        export function update() { return rejected === invalid.length ? valid : 'validation failed'; }
        """#
        #expect(try host.evaluate(source: source, baseValue: .string(""), properties: [:]) == .string("fonts/Valid.ttf"))
    }

    private func fixture(font: Any = "Helvetica", controller: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEAssetFonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/System/Library/Fonts/Supplemental/Courier New.ttf", toPath: root.appendingPathComponent("fonts/Custom.ttf").path)
        try FileManager.default.copyItem(atPath: "/System/Library/Fonts/Supplemental/Arial.ttf", toPath: root.appendingPathComponent("fonts/Alternate.ttf").path)
        var nodes: [[String: Any]] = []
        if let controller { nodes.append(["id": 1, "image": "missing.json", "origin": ["value": "0 0 0", "script": controller]]) }
        nodes.append(["id": 2, "name": "Text", "text": "MMMM", "font": font, "pointsize": 12, "size": "1 1"])
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": ["choice": ["type": "slider", "value": 0]]]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": nodes])
            .write(to: root.appendingPathComponent("scene.json"))
        return root
    }

    private func load(_ root: URL) throws -> SceneDescription {
        try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
