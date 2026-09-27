import Foundation
import Metal
import NativeSceneCore
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct SceneLightSpaceTests {
    @Test(arguments: ["lpoint", "lspot", "ltube", "ldirectional"], [false, true])
    func requiredLightingUsesLiveRadiusExponentAndLinearIntensity(type: String, withEffect: Bool) throws {
        let root = try fixture(type: type, withEffect: withEffect)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(raw["objects"] as? [[String: Any]])
        objects[1]["origin"] = "64.5 63.5 32"
        objects[1]["color"] = "0.125 0.25 0.375"
        objects[1]["visible"] = true
        objects[1]["controlpoint"] = "0 0 0"
        objects[1]["innercone"] = 0
        objects[1]["outercone"] = 0
        objects[1]["intensity"] = ["value": 0.5, "script": "export function update() { return Math.pow(2, engine.runtime * 2 - 1); }"]
        objects[1]["radius"] = ["value": 64, "script": "export function update() { return engine.runtime < 0.25 ? 64 : engine.runtime < 0.75 ? 128 : 16; }"]
        objects[1]["exponent"] = ["value": 2, "script": "export function update() { return engine.runtime < 0.25 ? 2 : 4; }"]
        objects.append(["id": 3, "light": type, "visible": false, "intensity": 1000, "radius": 1000])
        raw["objects"] = objects
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        try """
        // A diffuse-only helper isolates the engine's light inputs from BRDF
        // details. The required library must supply radius, exponent and color.
        vec3 ComputePBRLightShadow(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,
            float radius, float exponent, vec3 tint, vec3 f0, float roughness, float metallic, float shadow) {
            return lightColor * pow(max(0.0, 1.0 - length(L) / radius), exponent);
        }
        vec3 ComputePBRLightShadowInfinite(vec3 N, vec3 L, vec3 V, vec3 albedo,
            vec3 lightColor, vec3 tint, vec3 f0, float roughness, float metallic, float shadow) {
            return lightColor;
        }
        #require LightingV1
        varying vec3 v_WorldPos;
        void main() {
            gl_FragColor = vec4(PerformLighting_V1(v_WorldPos, vec3(1), vec3(0,0,1),
                vec3(0,0,1), vec3(1), vec3(0.04), 1.0, 0.0), 1);
        }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        // #require uses the engine library even if an old external shim exists.
        try "#error This external library must not satisfy require".write(
            to: root.appendingPathComponent("shaders/LightingV1.h"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0, 0.5, 0.5])
        let expected = type == "ldirectional" ? [[16, 32, 48], [32, 64, 96], [64, 128, 191]]
            : [[4, 8, 12], [10, 20, 30], [0, 0, 0]]
        for (frame, color) in zip(frames, expected) { expectPixel(frame, rgb: color) }
    }

    @Test func ordinaryLightingIncludeRetainsAuthoredContent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "vec4 authoredColor() { return vec4(0, 1, 0, 1); }".write(
            to: root.appendingPathComponent("shaders/LightingV1.h"), atomically: true, encoding: .utf8)
        try """
        #include "LightingV1.h"
        void main() { gl_FragColor = authoredColor(); }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        expectPixel(try #require(render(root, deltas: [0]).first), rgb: [0, 255, 0])
    }

    @Test func authoredLightShadowsRemainAnExplicitSupportGap() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(raw["objects"] as? [[String: Any]])
        objects[1]["castshadow"] = true
        raw["objects"] = objects
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let support = NativeSceneRenderer.support(scene: scene)
        #expect(support.isSupported)
        #expect(support.placeholderSubsystems.contains("light-shadows"))
        #expect(support.parityStatus == .partial)
    }

    @Test(arguments: [false, true], [false, true])
    func tubeEndpointsFollowAuthoredControlPointAndInheritedTransforms(showStart: Bool, scripted: Bool) throws {
        let root = try fixture(type: "ltube")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(raw["objects"] as? [[String: Any]])
        objects[1]["visible"] = true
        objects[1]["parent"] = 3
        objects[1]["angles"] = "0 0 \(Double.pi / 2)"
        objects[1]["scale"] = "2 3 1"
        objects[1]["controlpoint"] = "16 0 0"
        if scripted {
            objects[1]["intensity"] = ["value": 1, "script": """
            export function update(value) {
                thisLayer.controlpoint.x = 16 + engine.runtime * 8;
                thisLayer.controlpoint.z = engine.runtime * 8;
                return value;
            }
            """]
        }
        objects.append(["id": 3, "origin": "-32 -16 0", "scale": "2 1 1"])
        raw["objects"] = objects
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        let uniform = showStart ? "g_LTube_OriginA" : "g_LTube_OriginB"
        try """
        uniform vec4 \(uniform)[1];
        void main() { gl_FragColor = vec4(\(uniform)[0].xyz / 128.0, 1); }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0, 0.5, 0.5])
        for (index, frame) in frames.enumerated() {
            if showStart { expectPixel(frame, rgb: [191, 96, 64]) }
            else {
                let y = scripted ? [159, 175, 191][index] : 159
                let z = scripted ? [64, 72, 80][index] : 64
                expectPixel(frame, rgb: [191, y, z])
            }
        }
    }

    @Test(arguments: ["lpoint", "lspot", "ltube", "ldirectional"])
    func visibleLightTypesEnableTheirShaderLoops(type: String) throws {
        let root = try fixture(type: type)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #if LIGHTS_POINT
        uniform vec4 g_LPoint_Color[LIGHTS_POINT];
        #endif
        #if LIGHTS_SPOT
        uniform vec4 g_LSpot_Color[LIGHTS_SPOT];
        #endif
        #if LIGHTS_TUBE
        uniform vec4 g_LTube_Color[LIGHTS_TUBE];
        #endif
        #if LIGHTS_DIRECTIONAL
        uniform vec4 g_LDirectional_Color[LIGHTS_DIRECTIONAL];
        #endif
        void main() {
            vec3 color = vec3(0);
        #if LIGHTS_POINT
            for (uint i = 0u; i < CASTU(LIGHTS_POINT); ++i) color += g_LPoint_Color[i].rgb;
        #endif
        #if LIGHTS_SPOT
            for (uint i = 0u; i < CASTU(LIGHTS_SPOT); ++i) color += g_LSpot_Color[i].rgb;
        #endif
        #if LIGHTS_TUBE
            for (uint i = 0u; i < CASTU(LIGHTS_TUBE); ++i) color += g_LTube_Color[i].rgb;
        #endif
        #if LIGHTS_DIRECTIONAL
            for (uint i = 0u; i < CASTU(LIGHTS_DIRECTIONAL); ++i) color += g_LDirectional_Color[i].rgb;
        #endif
            gl_FragColor = vec4(color, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0.1, 0.6, 0.6])
        expectPixel(frames[0], rgb: [64, 128, 191])
        expectPixel(frames[1], rgb: [0, 0, 0])
        expectPixel(frames[2], rgb: [64, 128, 191])
    }

    @Test(arguments: [false, true], [0.5, 2.0])
    func cameraZoomPreservesWorldLightingAndEffectGeometry(withEffect: Bool, zoom: Double) throws {
        let root = try fixture(withEffect: withEffect)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var general = try #require(raw["general"] as? [String: Any])
        general["zoom"] = zoom
        general["clearcolor"] = "0 0 0"
        raw["general"] = general
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        try """
        varying vec3 v_WorldPos;
        void main() { gl_FragColor = vec4(v_WorldPos.xy / 128.0, 1, 1); }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frame = try #require(render(root, deltas: [0]).first)
        // Zoom changes the viewed world coordinate, never the layer's world transform.
        let x = Int(((76.5 - 64) / zoom + 64) / 128 * 255)
        let y = Int(((75.5 - 64) / zoom + 64) / 128 * 255)
        expectPixel(frame, x: 76, y: 52, rgb: [x, y, 255])
        expectPixel(frame, x: 4, y: 64, rgb: zoom < 1 ? [0, 0, 0] : [68, 127, 255])
    }

    @Test(arguments: [false, true])
    func lightCoordinatesMatchLayerWorldSpace(withEffect: Bool) throws {
        let root = try fixture(withEffect: withEffect)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform vec4 g_LPoint_Origin[1];
        varying vec3 v_WorldPos;
        void main() { gl_FragColor = vec4((g_LPoint_Origin[0].xy - v_WorldPos.xy) / 128.0 + 0.5, 1, 1); }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0.1])
        // Pixel (80,48) lies at world (80.5,79.5). The light is at (64,64).
        expectPixel(frames[0], x: 80, y: 48, rgb: [95, 97, 255])
    }

    @Test(arguments: [false, true])
    func rotatedLayersTransformTheirNormals(withEffect: Bool) throws {
        let root = try fixture(withEffect: withEffect, angles: "1.0471975512 0 0")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        varying vec3 v_Normal;
        void main() { gl_FragColor = vec4(abs(normalize(v_Normal)), 1); }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0.1])
        expectPixel(frames[0], rgb: [0, 221, 128])
    }

    @Test(arguments: [false, true], [0.5, 1.0, 2.0])
    func prelightingKeepsTheLayerScreenCoordinates(withEffect: Bool, zoom: Double) throws {
        let root = try fixture(withEffect: withEffect)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var general = try #require(raw["general"] as? [String: Any])
        general["zoom"] = zoom; raw["general"] = general
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        try """
        varying vec2 v_ScreenUV;
        void main() { gl_FragColor = vec4(v_ScreenUV, 0, 1); }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0.1])
        expectPixel(frames[0], x: 76, y: 52, rgb: [152, 105, 0])
    }

    @Test func modernShaderLightingUsesIntensity() throws {
        let root = try fixture(intensity: 0.5)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform vec4 g_LPoint_Color[1];
        void main() {
        #if SHADERVERSION < 62
            vec3 color = g_LPoint_Color[0].rgb;
        #else
            vec3 color = g_LPoint_Color[0].rgb * g_LPoint_Color[0].w * g_LPoint_Color[0].w;
        #endif
            gl_FragColor = vec4(color, 1);
        }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frames = try render(root, deltas: [0.1])
        expectPixel(frames[0], rgb: [16, 32, 48])
    }

    @Test(arguments: [false, true])
    func spotlightConeLightsItsCenterAndFadesTowardItsEdge(withEffect: Bool) throws {
        let root = try fixture(type: "lspot", withEffect: withEffect)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        uniform vec4 g_LSpot_Origin[1];
        uniform vec4 g_LSpot_Direction[1];
        varying vec3 v_WorldPos;
        void main() {
            // The cone calculation used by genericimage3/generic3 and LightingV1.
            vec3 delta = g_LSpot_Origin[0].xyz - v_WorldPos;
            float cone = -dot(normalize(delta), g_LSpot_Direction[0].xyz);
            cone = smoothstep(g_LSpot_Direction[0].w, g_LSpot_Origin[0].w, cone);
            gl_FragColor = vec4(vec3(cone), 1);
        }
        """.write(to: root.appendingPathComponent("shaders/lit.frag"), atomically: true, encoding: .utf8)
        let frame = try #require(render(root, deltas: [0.1]).first)
        expectPixel(frame, rgb: [255, 255, 255])
        // A diagonal corner is outside the outer cone; the horizontal edge
        // crosses the feathered interval between the authored 35/45 degrees.
        expectPixel(frame, x: 94, y: 94, rgb: [0, 0, 0])
        let feather = frame[(64 * 128 + 91) * 4]
        #expect(feather > 30 && feather < 220)
    }

    private func fixture(type: String = "lpoint", withEffect: Bool = false, angles: String = "0 0 0", intensity: Double = 1) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WELightSpace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func write(_ object: Any, _ file: String) throws { try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(file)) }
        try write(["type": "scene", "file": "scene.json"], "project.json")
        var node: [String: Any] = ["id": 1, "image": "model.json", "origin": "64 64 0", "angles": angles]
        if withEffect { node["effects"] = [["id": 1, "file": "effect.json"]] }
        try write(["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                   "general": ["orthogonalprojection": ["width": 128, "height": 128], "nearz": -100, "farz": 100],
                   "objects": [node, ["id": 2, "light": type, "origin": "64 64 32", "color": "0.25 0.5 0.75", "intensity": intensity,
                                      "visible": ["value": true, "script": "export function update() { return engine.runtime < 0.5 || engine.runtime > 1; }"]]]], "scene.json")
        try write(["material": "material.json", "width": 64, "height": 64], "model.json")
        try write(["passes": [["shader": "lit", "combos": ["LIGHTING": 1]]]], "material.json")
        try write(["passes": [["material": "copy.json"]]], "effect.json")
        try write(["passes": [["shader": "copy"]]], "copy.json")
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelMatrix;
        uniform mat4 g_ViewProjectionMatrix;
        uniform mat3 g_NormalModelMatrix;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat4 g_AltModelMatrix;
        uniform mat4 g_AltViewProjectionMatrix;
        uniform mat3 g_AltNormalModelMatrix;
        varying vec3 v_WorldPos;
        varying vec3 v_Normal;
        varying vec2 v_ScreenUV;
        void main() {
        #if PRELIGHTING
            vec4 world = g_AltModelMatrix * vec4(a_Position, 1);
            v_Normal = g_AltNormalModelMatrix * vec3(0, 0, 1);
            gl_Position = g_AltViewProjectionMatrix * world;
        #else
            vec4 world = g_ModelMatrix * vec4(a_Position, 1);
            v_Normal = g_NormalModelMatrix * vec3(0, 0, 1);
            gl_Position = g_ViewProjectionMatrix * world;
        #endif
            v_WorldPos = world.xyz;
            v_ScreenUV = gl_Position.xy / gl_Position.w * vec2(0.5, -0.5) + 0.5;
        #if PRELIGHTING
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1);
        #endif
        }
        """.write(to: root.appendingPathComponent("shaders/lit.vert"), atomically: true, encoding: .utf8)
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); v_TexCoord = a_TexCoord; }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        return root
    }

    private func render(_ root: URL, deltas: [Double]) throws -> [[UInt8]] {
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: scene, device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        return try deltas.map { delta in
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: delta, into: target, commandBuffer: command)
            command.commit(); command.waitUntilCompleted(); #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
            target.getBytes(&bytes, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
            return bytes
        }
    }
    private func expectPixel(_ bytes: [UInt8], x: Int = 64, y: Int = 64, rgb: [Int]) {
        for channel in 0..<3 { #expect(abs(Int(bytes[(y * 128 + x) * 4 + channel]) - rgb[channel]) <= 1) }
    }
}
