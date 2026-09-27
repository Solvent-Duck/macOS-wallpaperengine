import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct TextStyleTests {
    @Test func scriptStyleWritesReachTheCurrentFrameAndPersist() throws {
        let scene = try fixture(controller: """
        const text = thisScene.getLayer('Text');
        export function init() {
            text.font = 'Courier'; text.padding = 12;
            text.horizontalalign = 'right'; text.verticalalign = 'top';
            text.limitwidth = true; text.maxwidth = 150;
            text.limitrows = true; text.maxrows = 2; text.limituseellipsis = true;
            text.opaquebackground = true; text.castshadow = true; text.blockalign = true;
        }
        """)
        let runtime = SceneRuntime(scene: scene)
        for _ in 0..<2 {
            let text = try #require(runtime.step(deltaTime: 0.1).texts.first)
            #expect(text.fontPath == "Courier" && text.padding == 12)
            #expect(text.horizontalAlign == "right" && text.verticalAlign == "top")
            #expect(text.limitWidth && text.maxWidth == 150)
            #expect(text.limitRows && text.maxRows == 2 && text.limitUseEllipsis)
            #expect(text.opaqueBackground && text.castShadow && text.blockAlign)
        }
    }

    @Test func authoredStylePropertiesRefreshWhileTheSceneIsPaused() throws {
        let scene = try fixture(text: [
            "font": ["value": "Helvetica", "user": "font"],
            "padding": ["value": 0, "user": "padding"],
            "horizontalalign": ["value": "center", "user": "alignment"],
            "maxwidth": ["value": 80, "user": "width"], "limitwidth": true,
        ], properties: [
            "font": ["type": "textinput", "value": "Courier"],
            "padding": ["type": "slider", "value": 10],
            "alignment": ["type": "combo", "value": "left"],
            "width": ["type": "slider", "value": 120],
        ])
        let runtime = SceneRuntime(scene: scene)
        let initial = try #require(runtime.step(deltaTime: 0).texts.first)
        #expect(initial.fontPath == "Courier" && initial.padding == 10 && initial.horizontalAlign == "left")
        #expect(initial.maxWidth == 120)
        runtime.setPaused(true)
        let changed = try #require(runtime.step(deltaTime: 1, propertyOverrides: [
            "font": .string("Helvetica"), "padding": .int(4), "alignment": .string("right"), "width": .int(75),
        ]).texts.first)
        #expect(changed.fontPath == "Helvetica" && changed.padding == 4 && changed.horizontalAlign == "right")
        #expect(changed.maxWidth == 75 && runtime.elapsedTime == 0)
    }

    @Test func sizeReadsReflectWritesWithinTheSameCallbackAndMatchFrameDimensions() throws {
        let runtime = SceneRuntime(scene: try fixture(controller: """
        const text = thisScene.getLayer('Text');
        let initial;
        export function init() {
            text.text = 'HH'; text.pointsize = 12; text.padding = 0;
            initial = text.size.copy();
        }
        export function update() {
            text.text = 'HHHH'; text.pointsize = 24; text.padding = 8;
            const size = text.size;
            return new Vec3(size.x, size.y, size.x / initial.x);
        }
        """))
        let frame = runtime.step(deltaTime: 0)
        let text = try #require(frame.texts.first)
        let position = try #require(frame.nodes.first).worldPosition
        #expect(position.x > 200 && position.y > 80 && position.z > 3.5)
        #expect(text.size.x == position.x && text.size.y == position.y)
    }

    @Test func measuredSizeIsReadOnlyAndComponentWritesCannotPoisonLaterReads() throws {
        let runtime = SceneRuntime(scene: try fixture(controller: """
        'use strict';
        const text = thisScene.getLayer('Text');
        export function update() {
            const before = text.size;
            text.size.x = 9999;
            let readOnly = false;
            try { text.size = new Vec2(1); } catch (error) { readOnly = error instanceof TypeError; }
            return new Vec3(text.size.x === before.x ? 1 : 0, readOnly ? 1 : 0, text.size.y);
        }
        """))
        let frame = runtime.step(deltaTime: 0)
        let position = try #require(frame.nodes.first).worldPosition
        #expect(position.x == 1 && position.y == 1 && position.z > 0)
    }

    @Test func emptyAndZeroSizeTextMeasureZeroAndCanBecomeVisibleAgain() throws {
        let runtime = SceneRuntime(scene: try fixture(controller: """
        let frame = 0;
        const text = thisScene.getLayer('Text');
        export function update() {
            text.text = frame === 0 ? '' : 'HH';
            text.pointsize = frame === 1 ? 0 : 12;
            frame++;
            const size = text.size;
            return new Vec3(size.x, size.y, 0);
        }
        """))
        for index in 0..<3 {
            let frame = runtime.step(deltaTime: 0)
            let text = try #require(frame.texts.first)
            let position = try #require(frame.nodes.first).worldPosition
            #expect(position.x == text.size.x && position.y == text.size.y)
            if index < 2 { #expect(text.size == .zero) }
            else { #expect(text.size.x > 0 && text.size.y > 0) }
        }
    }

    @Test(arguments: ["pointsize = 1e300", "padding = 1000000", "maxwidth = 1e100"])
    func oversizedMeasurementThrowsAndCanRecoverWithinTheCallback(assignment: String) throws {
        let runtime = SceneRuntime(scene: try fixture(controller: """
        const text = thisScene.getLayer('Text');
        export function update() {
            text.limitwidth = true;
            text.\(assignment);
            let rejected = false;
            try { text.size; } catch (error) { rejected = true; }
            text.pointsize = 12; text.padding = 4; text.maxwidth = 120;
            const size = text.size;
            return new Vec3(rejected ? 1 : 0, size.x, size.y);
        }
        """))
        let frame = runtime.step(deltaTime: 0)
        let position = try #require(frame.nodes.first).worldPosition
        let text = try #require(frame.texts.first)
        #expect(position.x == 1 && position.y == text.size.x && position.z == text.size.y)
        #expect(text.size.x > 0 && text.size.y > 0)
    }

    @Test func legacySerializedTextStylesRemainAvailableToScripts() throws {
        let original = try fixture(controller: """
        export function update() {
            const text = thisScene.getLayer('Text');
            return new Vec3(text.padding, text.font === 'Courier' ? 1 : 0, text.maxwidth);
        }
        """, text: ["font": "Courier", "padding": 6, "maxwidth": 250])
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var graph = try #require(raw["scene"] as? [String: Any])
        var nodes = try #require(graph["nodes"] as? [[String: Any]])
        for index in nodes.indices {
            if var text = nodes[index]["text"] as? [String: Any] {
                text.removeValue(forKey: "styleSettings"); nodes[index]["text"] = text
            }
        }
        graph["nodes"] = nodes
        raw["scene"] = graph
        let restored = try JSONDecoder().decode(SceneDescription.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(SceneRuntime(scene: restored).step(deltaTime: 0).nodes.first?.worldPosition == RuntimeVector3(x: 6, y: 1, z: 250))
    }

    private func fixture(controller: String? = nil, text: [String: Any] = [:], properties: [String: Any] = [:]) throws -> SceneDescription {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WETextStyles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var object: [String: Any] = ["id": 2, "name": "Text", "text": "HH", "font": "Helvetica", "pointsize": 12, "size": "88 88"]
        object.merge(text, uniquingKeysWith: { _, value in value })
        var objects: [[String: Any]] = []
        if let controller { objects.append(["id": 1, "image": "missing.json", "origin": ["value": "0 0 0", "script": controller]]) }
        objects.append(object)
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": properties]])
            .write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": objects])
            .write(to: root.appendingPathComponent("scene.json"))
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}
