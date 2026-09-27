import Foundation
import NativeSceneCore
import NativeSceneRuntime
import Testing

struct EffectTextureBindingTests {
    @Test(arguments: [false, true], [false, true])
    func effectBindingsPreserveSlotsAndFollowLiveProperties(text: Bool, inheritedBindings: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEEffectBindings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var node: [String: Any] = ["id": 1, "image": "model.json", "effects": [[
            "file": "effect.json", "id": 20, "passes": [["id": 900, "usertextures": [
                NSNull(), ["name": "$mediaPreviousThumbnail", "type": "system"], "selected", NSNull(),
                ["name": "shortcut", "type": "usershortcut"],
            ]]],
        ]]]
        if text { node.removeValue(forKey: "image"); node["text"] = "Cover" }
        let files: [String: Any] = [
            "project.json": ["type": "scene", "file": "scene.json", "general": ["properties": [
                "selected": ["type": "scenetexture", "value": ""],
                "base": ["type": "scenetexture", "value": "base-choice.png"],
                "inherited": ["type": "scenetexture", "value": "inherited.png"],
                "shortcut": ["type": "text", "value": "/Applications/Example.app"],
            ]]],
            "scene.json": ["camera": [:], "general": [:], "objects": [node]],
            "model.json": ["material": "base.json", "width": 8, "height": 8],
            "base.json": ["passes": [["shader": "unused"]]],
            "effect.json": ["passes": [["material": "effect-material.json"]]],
            "effect-material.json": ["passes": [["shader": "unused", "textures": [
                "chain.png", "fallback1.png", "fallback2.png", "fallback3.png", "fallback4.png",
            ], "usertextures": inheritedBindings ? [NSNull(), ["name": "$mediaThumbnail", "type": "system"], "base", "inherited"] : []]]],
        ]
        for (name, value) in files {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene, assetRoots: [root])
        for selected in ["", "chosen-a.png", "chosen-b.png", ""] {
            let frame = runtime.step(deltaTime: 0, propertyOverrides: ["selected": .string(selected)])
            let material = try #require(frame.materials.first { $0.sourceFile == "effect-material.json" })
            let pass = try #require(material.passes.first)
            let slots = Dictionary(uniqueKeysWithValues: pass.textures.map { ($0.slot, $0.path) })
            #expect(slots[0] == "chain.png")
            #expect(slots[1] == "$mediaPreviousThumbnail")
            #expect(pass.textures.first { $0.slot == 1 }?.sourceType == "system")
            #expect(pass.textures.first { $0.slot == 1 }?.fallbackPath == "fallback1.png")
            #expect(slots[2] == (selected.isEmpty ? "fallback2.png" : selected))
            #expect(slots[3] == (inheritedBindings ? "inherited.png" : "fallback3.png"))
            #expect(slots[4] == "fallback4.png")
        }
    }

    @Test func textureBindingsDecodeOlderPacketsAndRetainPlaceholders() throws {
        let old = Data(#"{"slot":1,"path":"$mediaThumbnail","sourceType":"system"}"#.utf8)
        let decoded = try JSONDecoder().decode(FrameTextureBinding.self, from: old)
        #expect(decoded.fallbackPath == nil)
        let current = Data(#"{"slot":1,"path":"$mediaThumbnail","sourceType":"system","fallbackPath":"placeholder.png"}"#.utf8)
        let binding = try JSONDecoder().decode(FrameTextureBinding.self, from: current)
        #expect(binding.fallbackPath == "placeholder.png")
        #expect(try JSONDecoder().decode(FrameTextureBinding.self, from: JSONEncoder().encode(binding)) == binding)
    }

    @Test func effectBindingSerializationPreservesNewAndOlderDescriptors() throws {
        for bindings in ["", #", "userTextures":[{"slot":1,"path":"$mediaThumbnail","sourceType":"system"}]"#] {
            let data = Data((#"{"id":1,"combos":{},"constants":{},"textures":[]"# + bindings + "}").utf8)
            let descriptor = try JSONDecoder().decode(EffectOverridePassDescriptor.self, from: data)
            let encoded = try JSONEncoder().encode(descriptor)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let textures = try #require(json["userTextures"] as? [[String: Any]])
            #expect(textures.count == (bindings.isEmpty ? 0 : 1))
            if !bindings.isEmpty { #expect(textures.first?["path"] as? String == "$mediaThumbnail") }
            #expect(try JSONDecoder().decode(EffectOverridePassDescriptor.self, from: encoded) == descriptor)
        }
    }
}
