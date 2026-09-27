import Foundation
import Testing
@testable import WallpaperEngine

struct WallpaperPresetTests {
    @Test func resolvesDependencyWhileKeepingPresetIdentityAndDefaults() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "100", ["title": "Base", "type": "web", "file": "index.html", "preview": "base.png", "general": ["properties": [
            "speed": ["type": "slider", "value": 1, "min": 0, "max": 10],
            "enabled": ["type": "bool", "value": true],
            "image": ["type": "file", "value": ""],
            "mode": ["type": "combo", "value": 1, "options": [["value": 1, "label": "One"], ["value": 2, "label": "Two"]]]
        ]]])
        try write(root, "200", ["title": "Preset", "dependency": "100", "preview": "preview.jpg", "preset": [
            "speed": 3.5, "enabled": NSNull(), "image": "files/photo ü.png", "mode": 2, "volume": 50
        ]])
        let project = try WallpaperLoader.load(from: root.appendingPathComponent("200/project.json"))
        #expect(project.type == .preset)
        #expect(project.type.isSupported)
        #expect(project.resolvedType == .web)
        #expect(project.resolvedTitle == "Preset")
        #expect(project.directoryURL?.lastPathComponent == "200")
        #expect(project.fileURL == root.appendingPathComponent("100/index.html"))
        #expect(project.previewURL == root.appendingPathComponent("200/preview.jpg"))
        let properties = Dictionary(uniqueKeysWithValues: project.resolvedProperties.map { ($0.key, $0) })
        #expect(properties["speed"]?.defaultValue == "3.5")
        #expect(properties["speed"]?.max == 10)
        #expect(properties["enabled"]?.defaultValue == "1")
        #expect(properties["image"]?.defaultValue == root.appendingPathComponent("200/files/photo ü.png").path)
        #expect(properties["mode"]?.jsLiteral(from: "2") == "2")
        #expect(project.presetSettings["volume"] == "50")
        let base = try WallpaperLoader.load(from: root.appendingPathComponent("100"))
        #expect(base.resolvedProperties.first(where: { $0.key == "speed" })?.defaultValue == "1")
    }

    @Test func nestedPresetsOverrideValuesAndRetainInheritedAssets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "100", ["title": "Base", "type": "video", "file": "movie.mp4", "preview": "base.jpg", "properties": ["image": ["type": "file", "value": ""], "speed": ["type": "slider", "value": 1]]])
        try write(root, "200", ["title": "First", "dependency": "100", "preset": ["image": "files/image.jpg", "speed": 2]])
        try write(root, "300", ["title": "Second", "type": "preset", "dependency": "200", "preset": ["speed": 3]])
        let project = try WallpaperLoader.load(from: root.appendingPathComponent("300"))
        #expect(project.resolvedType == .video)
        #expect(project.fileURL == root.appendingPathComponent("100/movie.mp4"))
        #expect(project.previewURL == root.appendingPathComponent("100/base.jpg"))
        #expect(project.resolvedProperties.first(where: { $0.key == "image" })?.defaultValue == root.appendingPathComponent("200/files/image.jpg").path)
        #expect(project.resolvedProperties.first(where: { $0.key == "speed" })?.defaultValue == "3")
    }

    @Test func missingCyclicAndInvalidDependenciesProduceSpecificErrors() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "200", ["dependency": "100", "preset": [:]])
        #expect(throws: WallpaperError.self) { try WallpaperLoader.load(from: root.appendingPathComponent("200")) }
        do { _ = try WallpaperLoader.load(from: root.appendingPathComponent("200")) }
        catch { #expect(error.localizedDescription.contains("requires workshop wallpaper 100")) }
        try write(root, "100", ["dependency": "200", "preset": [:]])
        do {
            _ = try WallpaperLoader.load(from: root.appendingPathComponent("200"))
            Issue.record("Cycle was accepted")
        } catch { #expect(error.localizedDescription.contains("dependency cycle")) }
        try write(root, "200", ["dependency": "../100", "preset": [:]])
        do {
            _ = try WallpaperLoader.load(from: root.appendingPathComponent("200"))
            Issue.record("Invalid dependency was accepted")
        } catch { #expect(error.localizedDescription.contains("Invalid wallpaper preset")) }
    }

    @MainActor @Test func presetSceneRetainsParsedContentAndOverridesNativeDefaults() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "100", ["title": "Scene", "type": "scene", "file": "scene.json", "general": ["properties": ["opacity": ["type": "slider", "value": 1]]]])
        let scene: [String: Any] = ["camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"], "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": []]
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("100/scene.json"))
        try write(root, "200", ["title": "Preset scene", "dependency": "100", "preset": ["opacity": 0.25, "wec_brs": 60]])
        let project = try WallpaperLoader.load(from: root.appendingPathComponent("200"))
        #expect(project.sceneDescription != nil)
        #expect(project.sceneResolution?.width == 64)
        #expect(project.resolvedTitle == "Preset scene")
        #expect(project.resolvedProperties.first?.defaultValue == "0.25")
        let sceneDescription = try #require(project.sceneDescription)
        let reportString = try #require(SceneRenderer.supportReportLine(for: sceneDescription, unappliedPresetOptions: Array(project.presetSettings.keys)))
        let report = try #require(JSONSerialization.jsonObject(with: Data(reportString.utf8)) as? [String: Any])
        #expect(report["parityStatus"] as? String == "partial")
        #expect(report["placeholderSubsystems"] as? [String] == ["preset-options"])
        #expect(report["unappliedPresetOptions"] as? [String] == ["wec_brs"])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEPreset-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ id: String, _ object: [String: Any]) throws {
        let directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("project.json"))
    }
}
