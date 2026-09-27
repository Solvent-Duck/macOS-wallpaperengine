import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

@Suite(.serialized)
struct TextRendererTests {
    @Test func mediaTitleColorAndPlaybackEventsReachRenderedPixels() throws {
        let root = try fixture(text: "placeholder")
        defer { try? FileManager.default.removeItem(at: root) }
        try changeText(root, ["text": ["value": "placeholder", "script": """
        export function mediaPropertiesChanged(e) { thisLayer.text = e.title; }
        export function mediaThumbnailChanged(e) { thisLayer.color = e.textColor; }
        export function mediaPlaybackChanged(e) { thisLayer.visible = e.state !== MediaPlaybackEvent.PLAYBACK_STOPPED; }
        """]])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: load(root), device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        func capture() throws -> [UInt8] {
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: 0, into: texture, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            return read(texture)
        }
        let stopped = try capture()
        #expect(stride(from: 0, to: stopped.count, by: 4).allSatisfy { stopped[$0] == 0 && stopped[$0 + 1] == 0 && stopped[$0 + 2] == 0 })
        var state = SceneMediaState()
        state.enabled = true
        state.playback = .playing
        state.properties.title = "H"
        state.thumbnail.textColor = RuntimeVector3(x: 0, y: 1, z: 0)
        renderer.updateMediaState(state)
        let playing = try capture()
        #expect(stride(from: 0, to: playing.count, by: 4).contains { playing[$0 + 1] > 200 && playing[$0] == 0 && playing[$0 + 2] == 0 })
        state.playback = .paused
        renderer.updateMediaState(state)
        #expect(try capture() == playing)
        state.properties.title = "W"
        renderer.updateMediaState(state)
        #expect(try capture() != playing)
        state.playback = .stopped
        renderer.updateMediaState(state)
        #expect(try capture() == stopped)
    }

    @Test func registeredFontHandleRendersThePackagedFontInsteadOfTheDefault() throws {
        let root = try fixture(text: "MMMM")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("fonts/workshop/123")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/System/Library/Fonts/Supplemental/Courier New.ttf",
                                        toPath: directory.appendingPathComponent("Custom Font.ttf").path)
        let device = try #require(MTLCreateSystemDefaultDevice())
        func raster(_ font: Any) throws -> MTLTexture {
            try changeText(root, ["font": font])
            let layouts = TextLayoutEngine(assetRoots: [root])
            let runtime = SceneRuntime(scene: try load(root), textLayouts: layouts)
            let frame = try #require(runtime.step(deltaTime: 0).texts.first)
            let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm, textLayouts: layouts)
            let texture = try renderer.rasterizedTexture(for: frame)
            return try #require(texture)
        }
        let original = try raster("Helvetica")
        let registered = try raster(["value": "Helvetica", "script": """
        const font = engine.registerAsset('fonts/workshop/123/Custom Font.ttf');
        export function update() { return font; }
        """])
        let direct = try raster("fonts/workshop/123/Custom Font.ttf")
        #expect(registered.width == direct.width && registered.height == direct.height)
        let samePixels = read(registered) == read(direct)
        #expect(samePixels)
        #expect(registered.width != original.width)
    }

    @Test func scriptSizeMatchesRasterAfterLiveStyleAndColorChanges() throws {
        let root = try fixture(text: "H")
        defer { try? FileManager.default.removeItem(at: root) }
        try changeText(root, ["origin": ["value": "0 0 0", "script": """
        let frame = 0;
        export function update() {
            const second = frame++ > 0;
            thisLayer.font = second ? 'Helvetica' : 'Courier';
            thisLayer.text = second ? 'ALPHA BETA GAMMA DELTA' : 'HH';
            thisLayer.pointsize = second ? 12 : 6;
            thisLayer.padding = second ? 9 : 4;
            thisLayer.limitwidth = true; thisLayer.maxwidth = 96;
            thisLayer.limitrows = true; thisLayer.maxrows = 1;
            thisLayer.limituseellipsis = second;
            thisLayer.horizontalalign = second ? 'right' : 'left';
            thisLayer.verticalalign = second ? 'top' : 'bottom';
            thisLayer.opaquebackground = second;
            thisLayer.backgroundcolor = new Vec4(0, 0, 1, 0);
            thisLayer.color = second ? new Vec3(0, 1, 0) : new Vec3(1, 0, 0);
            const size = thisLayer.size;
            return new Vec3(size.x, size.y, 0);
        }
        """]])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layouts = TextLayoutEngine(assetRoots: [root])
        let runtime = SceneRuntime(scene: try load(root), textLayouts: layouts)
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm, textLayouts: layouts)
        var heights: [Int] = []
        for index in 0..<2 {
            let packet = runtime.step(deltaTime: 0.1)
            let frame = try #require(packet.texts.first)
            let raster = try renderer.rasterizedTexture(for: frame)
            let texture = try #require(raster)
            let position = try #require(packet.nodes.first).worldPosition
            #expect(frame.size.x == Float(texture.width) && frame.size.y == Float(texture.height))
            #expect(position.x == frame.size.x && position.y == frame.size.y)
            #expect(texture.width == 96 + (index == 0 ? 8 : 18))
            let pixels = read(texture)
            if index == 0 {
                #expect(pixels[3] == 0)
                #expect(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 200 && pixels[$0 + 3] > 200 })
            } else {
                #expect(Array(pixels.prefix(4)) == [0, 0, 255, 255])
                #expect(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0 + 1] > 200 && pixels[$0] == 0 })
            }
            heights.append(texture.height)
        }
        #expect(heights[1] > heights[0])
    }

    @Test func currentTextAndFontDetermineRasterSizeInsteadOfSavedPlaceholderBounds() throws {
        let root = try fixture(text: "DAY")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        func texture(_ content: String, size: String, pointSize: Double = 11.52) throws -> MTLTexture {
            try changeText(root, ["text": content, "size": size, "pointsize": pointSize, "padding": 4])
            let frame = try #require(SceneRuntime(scene: load(root)).step(deltaTime: 0).texts.first)
            let rasterized = try renderer.rasterizedTexture(for: frame)
            return try #require(rasterized)
        }
        let short = try texture("DAY", size: "1 1")
        let long = try texture("S U N D A Y", size: "1 1")
        let alternate = try texture("S U N D A Y", size: "800 600")
        #expect(long.width > short.width * 2)
        #expect(long.height == short.height)
        #expect(long.width == alternate.width && long.height == alternate.height)
        #expect(read(long) == read(alternate), "Saved editor bounds must not clip or stretch current text")
        let large = try texture("DAY", size: "1 1", pointSize: 23.04)
        #expect(abs((large.width - 8) - (short.width - 8) * 2) <= 2)
        #expect(abs((large.height - 8) - (short.height - 8) * 2) <= 2)
    }

    @Test func widthAndRowLimitsWrapCurrentTextAndCanAddEllipsis() throws {
        let root = try fixture(text: "ALPHA BETA GAMMA DELTA")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        func texture(_ changes: [String: Any]) throws -> MTLTexture {
            try changeText(root, changes)
            let frame = try #require(SceneRuntime(scene: load(root)).step(deltaTime: 0).texts.first)
            let rasterized = try renderer.rasterizedTexture(for: frame)
            return try #require(rasterized)
        }
        let wrapped = try texture(["size": "1 1", "limitwidth": true, "maxwidth": 180, "padding": 4])
        let single = try texture(["limitrows": true, "maxrows": 1])
        let ellipsis = try texture(["limituseellipsis": true])
        #expect(wrapped.width <= 188 && wrapped.width > 100)
        #expect(wrapped.height > single.height * 2)
        #expect(single.width == ellipsis.width && single.height == ellipsis.height)
        let pixelsDiffer = read(single) != read(ellipsis)
        #expect(pixelsDiffer, "Overflow must visibly add the ellipsis")
        let unlimited = try texture(["limitwidth": false, "limitrows": false])
        #expect(unlimited.width > 400 && unlimited.height == single.height)
    }

    @Test(arguments: ["left", "center", "right"], [0, 1])
    func textAlignmentAnchorsTheQuadWithAndWithoutEffects(alignment: String, effects: Int) throws {
        let root = try fixture(text: "HH", effectCount: effects)
        defer { try? FileManager.default.removeItem(at: root) }
        try changeText(root, ["size": "88 88", "pointsize": 6, "horizontalalign": alignment])
        let pixels = try render(root)
        let visible = (0..<16384).filter { pixels[$0 * 4] > 128 }
        let xs = visible.map { $0 % 128 }
        let left = try #require(xs.min()), right = try #require(xs.max())
        #expect(right - left > 25)
        switch alignment {
        case "left": #expect(left >= 63 && right > 90)
        case "right": #expect(right <= 64 && left < 38)
        default: #expect(abs(left + right - 127) <= 3)
        }
    }

    @Test(arguments: ["top", "center", "bottom"], [0, 1])
    func verticalAlignmentAnchorsCurrentTextGeometry(alignment: String, effects: Int) throws {
        let root = try fixture(text: "H", effectCount: effects)
        defer { try? FileManager.default.removeItem(at: root) }
        try changeText(root, ["size": "88 88", "pointsize": 6, "verticalalign": alignment])
        let pixels = try render(root)
        let visible = (0..<16384).filter { pixels[$0 * 4] > 128 }
        let ys = visible.map { $0 / 128 }
        let top = try #require(ys.min()), bottom = try #require(ys.max())
        #expect(bottom - top >= 16)
        switch alignment {
        case "top": #expect(top >= 63 && bottom > 80)
        case "bottom": #expect(bottom <= 64 && top < 46)
        default: #expect(abs(top + bottom - 127) <= 5)
        }
    }

    @Test func explicitBlankLinesGrowLayoutAndOldTextTexturesAreReplaced() throws {
        let root = try fixture(text: "H")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        func raster(_ content: String) throws -> MTLTexture {
            try changeText(root, ["text": content, "size": "1 1"])
            let frame = try #require(SceneRuntime(scene: load(root)).step(deltaTime: 0).texts.first)
            let texture = try renderer.rasterizedTexture(for: frame)
            return try #require(texture)
        }
        let first = try raster("H")
        let cached = try raster("H")
        #expect(first === cached)
        let multiline = try raster("H\n\nH")
        #expect(multiline.height > first.height * 2 && multiline.width == first.width)
        let restored = try raster("H")
        #expect(restored !== first, "The prior value must not remain cached after this layer changes")
        let samePixels = read(restored) == read(first)
        #expect(samePixels)
    }

    private func changeText(_ root: URL, _ changes: [String: Any]) throws {
        let url = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var node = try #require((scene["objects"] as? [[String: Any]])?.first)
        node.merge(changes, uniquingKeysWith: { _, value in value })
        scene["objects"] = [node]
        try JSONSerialization.data(withJSONObject: scene).write(to: url)
    }

    @Test(arguments: [0, 1, 2], [0.5, 2.0])
    func cameraZoomScalesTextAndItsEffectsOnce(effectCount: Int, zoom: Double) throws {
        let root = try fixture(text: "H", effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("scene.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var general = try #require(raw["general"] as? [String: Any])
        if effectCount == 2 {
            general["orthogonalprojection"] = ["width": 0, "height": 0, "auto": true]
            // Keep this zoom fixture facing the 2D plane. A target at the
            // origin would tilt the view and introduce depth-plane clipping.
            raw["camera"] = ["eye": "8 4 0", "center": "8 4 -1", "up": "0 1 0"]
        }
        raw["general"] = general
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        let reference = try render(root)
        general["zoom"] = zoom; raw["general"] = general
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        let pixels = try render(root)
        func bounds(_ pixels: [UInt8]) throws -> [Int] {
            let visible = (0..<16384).filter { pixels[$0 * 4] > 128 }
            let xs = visible.map { $0 % 128 }, ys = visible.map { $0 / 128 }
            return try [#require(xs.min()), #require(xs.max()), #require(ys.min()), #require(ys.max())]
        }
        for (before, after) in zip(try bounds(reference), try bounds(pixels)) {
            #expect(abs(Double(after) - ((Double(before) + 0.5 - 64) * zoom + 63.5)) <= 2)
        }
    }

    @Test(arguments: [12.0, 20.0, 25.0, 30.0])
    func roundedTextHeightKeepsTheLine(pointSize: Double) throws {
        let root = try fixture(text: "H")
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent("scene.json")
        var authored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var node = try #require((authored["objects"] as? [[String: Any]])?.first)
        // Helvetica's natural line box includes 20% typesetting leading.
        let height = Int((pointSize * 300 / 72 * 1.2).rounded())
        node["pointsize"] = pointSize
        node["padding"] = 0
        node["size"] = "200 \(height)"
        authored["objects"] = [node]
        try JSONSerialization.data(withJSONObject: authored).write(to: sceneURL)
        let scene = try load(root)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        let text = try #require(SceneRuntime(scene: scene).step(deltaTime: 0).texts.first)
        let rasterized = try renderer.rasterizedTexture(for: text)
        let texture = try #require(rasterized, "Integer-rounded authored height must not suppress the whole line")
        #expect(texture.height > 0 && texture.height <= height, "Use the current line metrics within the former rounded-height fixture")
        let pixels = read(texture)
        #expect(stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 100 }.count > 100)
    }

    @Test(arguments: [12.0, 24.0], [0, 16])
    func sceneFontScaleAndPaddingPreserveGlyphs(pointSize: Double, padding: Int) throws {
        let root = try fixture(text: "H")
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneURL = root.appendingPathComponent("scene.json")
        var authored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var node = try #require((authored["objects"] as? [[String: Any]])?.first)
        node["pointsize"] = pointSize
        node["padding"] = padding
        node["size"] = "128 128"
        authored["objects"] = [node]
        try JSONSerialization.data(withJSONObject: authored).write(to: sceneURL)
        let scene = try load(root)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        let text = try #require(SceneRuntime(scene: scene).step(deltaTime: 0).texts.first)
        let rasterized = try renderer.rasterizedTexture(for: text)
        let texture = try #require(rasterized)
        try changeText(root, ["padding": 0])
        let unpaddedFrame = try #require(SceneRuntime(scene: load(root)).step(deltaTime: 0).texts.first)
        let unpaddedRaster = try renderer.rasterizedTexture(for: unpaddedFrame)
        let unpadded = try #require(unpaddedRaster)
        #expect(texture.width == unpadded.width + padding * 2)
        #expect(texture.height == unpadded.height + padding * 2)
        let pixels = read(texture)
        let rows = (0..<texture.height).filter { y in
            (0..<texture.width).contains { pixels[(y * texture.width + $0) * 4 + 3] > 100 }
        }
        let first = try #require(rows.first), last = try #require(rows.last)
        // Authored local text dimensions imply 300-DPI font rasterization.
        // Helvetica's H at 12pt is about 36 pixels tall, and doubles at 24pt.
        #expect(abs(Double(last - first + 1) - pointSize * 3) <= 2)
        #expect(abs(first + last - (texture.height - 1)) < 18)
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func textAndImagesRespectAuthoredPaintOrder(effectCount: Int, textOnTop: Bool) throws {
        let root = try fixture(text: "F", effectCount: effectCount)
        defer { try? FileManager.default.removeItem(at: root) }
        func json(_ path: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(path))
        }
        let sceneURL = root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        let text = try #require((scene["objects"] as? [[String: Any]])?.first)
        let cover: [String: Any] = ["id": 2, "image": "cover-model.json", "origin": "64 64 0"]
        scene["objects"] = textOnTop ? [cover, text] : [text, cover]
        try json("scene.json", scene)
        try json("cover-model.json", ["material": "cover-material.json", "width": 128, "height": 128])
        try json("cover-material.json", ["passes": [["shader": "cover", "blending": "normal"]]])
        try FileManager.default.copyItem(at: root.appendingPathComponent("shaders/copy.vert"), to: root.appendingPathComponent("shaders/cover.vert"))
        try "void main() { gl_FragColor = vec4(0, 0, 1, 1); }"
            .write(to: root.appendingPathComponent("shaders/cover.frag"), atomically: true, encoding: .utf8)
        let pixels = try render(root)
        let red = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 20 }.count
        if textOnTop {
            #expect(red > 200)
        } else {
            #expect(red == 0, "The later opaque image must cover the text")
            #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0 + 2] == 255 })
        }
    }

    @Test(arguments: ["top", "center", "bottom"])
    func glyphsAreUprightAndKeepTheirPadding(alignment: String) throws {
        let root = try fixture(text: "F", alignment: alignment)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = try load(root)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try TextRenderer(device: device, assetRoots: [root], colorPixelFormat: .rgba8Unorm)
        let text = try #require(SceneRuntime(scene: scene).step(deltaTime: 0).texts.first)
        let rasterized = try renderer.rasterizedTexture(for: text)
        let texture = try #require(rasterized)
        let pixels = read(texture)
        let rows = (0..<texture.height).map { y in (0..<texture.width).filter { pixels[(y * texture.width + $0) * 4 + 3] > 100 }.count }
        let first = try #require(rows.firstIndex(where: { $0 > 0 }))
        let last = try #require(rows.lastIndex(where: { $0 > 0 }))
        // F has a wide upper bar and only its stem at the bottom.
        #expect(rows[first..<min(first + 6, last)].max()! > rows[max(first, last - 5)...last].max()! * 2)
        #expect(last - first > 25, "The complete glyph must fit in the texture")
        #expect(first >= 4 && last < texture.height - 4)
        #expect(last - first < texture.height - 8)

    }

    @Test(arguments: [0, 1, 2])
    func textEffectsPreserveGeometryColorAndOpacity(effectCount: Int) throws {
        let root = try fixture(text: "F", effectCount: effectCount, alpha: 0.5)
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try render(root)
        let visible = (0..<(128 * 128)).filter { pixels[$0 * 4] > 20 }
        #expect(visible.count > 200)
        let xs = visible.map { $0 % 128 }, ys = visible.map { $0 / 128 }
        let minX = try #require(xs.min()), maxX = try #require(xs.max())
        let minY = try #require(ys.min()), maxY = try #require(ys.max())
        #expect(abs(minX + maxX - 127) < 12, "The layer origin is the center of its quad")
        #expect(abs(minY + maxY - 127) < 12)
        let peakRed = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max()!
        #expect(abs(Int(peakRed) - 128) <= 1, "Apply 50% opacity once, including through effect passes")
        let peakGreen = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0 + 1] }.max()!
        let peakBlue = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0 + 2] }.max()!
        #expect(peakGreen == 0)
        #expect(peakBlue == 0)
        if effectCount > 0 {
            let plain = try fixture(text: "F", alpha: 0.5)
            defer { try? FileManager.default.removeItem(at: plain) }
            let reference = try render(plain)
            #expect(zip(pixels, reference).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Copy effects must preserve every pixel")
        }
    }

    @Test func effectCannotReplaceAnimatedLayerOpacity() throws {
        let root = try fixture(text: "H", effectCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try changeText(root, ["alpha": ["value": 1, "script": """
        const values = [0, 0.25, 1, 0.5, 0];
        let frame = 0;
        export function update() { return values[frame++]; }
        """]])
        // An effect may expand coverage beyond glyphs (for example, glow).
        // Its replacement alpha must still respect the layer's own opacity.
        try "void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }"
            .write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: load(root), device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var fullCoverage = 0
        for expected in [0, 64, 255, 128, 0] {
            let command = try #require(queue.makeCommandBuffer())
            try renderer.renderNextFrame(deltaTime: 1.0 / 60, into: texture, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            #expect(command.status == .completed)
            let pixels = read(texture)
            let red = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }
            #expect(abs(red.max()! - expected) <= 1, "Effect output must follow live layer opacity")
            if expected == 255 { fullCoverage = red.filter { $0 > 200 }.count }
        }
        let plain = try fixture(text: "H")
        defer { try? FileManager.default.removeItem(at: plain) }
        let glyphPixels = try render(plain)
        let glyphCoverage = stride(from: 0, to: glyphPixels.count, by: 4).filter { glyphPixels[$0] > 200 }.count
        #expect(fullCoverage > glyphCoverage * 2, "Do not clip expanded effect output to the original glyph mask")
    }

    private func fixture(text: String, alignment: String = "center", effectCount: Int = 0, alpha: Double = 1) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WETextPixels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        func json(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        try json("project.json", ["type": "scene", "file": "scene.json"])
        try json("scene.json", [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 128, "height": 128], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "text": text, "font": "Helvetica", "pointsize": 11.52, "size": "88 88",
                         "origin": "64 64 0", "padding": 4, "verticalalign": alignment, "horizontalalign": "center",
                         "color": "1 0 0", "alpha": alpha,
                         "effects": (0..<effectCount).map { ["id": $0 + 10, "file": "effect.json"] }]]
        ])
        try json("effect.json", ["passes": [["material": "effect-material.json"]]])
        // Translucent authored passes must not multiply alpha while copying
        // the already rasterized text into an empty intermediate texture.
        try json("effect-material.json", ["passes": [["shader": "copy", "blending": "translucent"]]])
        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_TexCoord;
        void main() { v_TexCoord = a_TexCoord; gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }
        """.write(to: root.appendingPathComponent("shaders/copy.vert"), atomically: true, encoding: .utf8)
        try """
        uniform sampler2D g_Texture0;
        uniform vec4 g_Color4;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4; }
        """.write(to: root.appendingPathComponent("shaders/copy.frag"), atomically: true, encoding: .utf8)
        return root
    }

    private func load(_ root: URL) throws -> SceneDescription {
        try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }

    private func render(_ root: URL) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try NativeSceneRenderer(scene: load(root), device: device, assetRoots: [root])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(queue.makeCommandBuffer())
        try renderer.renderNextFrame(deltaTime: 0, into: texture, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        return read(texture)
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&pixels, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return pixels
    }
}
