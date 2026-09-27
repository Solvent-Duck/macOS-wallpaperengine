import Foundation
import NativeSceneCore
import Testing

struct PackageLifetimeTests {
    @Test func extractionFailuresExplainTheMissingAssetAndRecoverOnRetry() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedRoot)
        do {
            _ = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path,
                packageTemporaryRoot: blockedRoot)
            Issue.record("An extraction into a regular file must fail")
        } catch {
            #expect(error.localizedDescription.contains("scene.json"))
            #expect(error.localizedDescription.contains("Package scene.pkg extraction failed:"))
            #expect(error.localizedDescription.contains("not-a-directory"))
        }
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path,
            packageTemporaryRoot: root.appendingPathComponent("recovered"))
        #expect(scene.scene != nil)
    }

    @Test func unusedBrokenPackageDoesNotPreventLoadingLooseAssets() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid package".utf8).write(to: root.appendingPathComponent("scene.pkg"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": []])
            .write(to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        #expect(scene.scene != nil)
        #expect(scene.extractedRoots.isEmpty)
    }

    @Test func extractedAssetsLiveUntilTheLastSceneCopyIsReleased() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryRoot = root.appendingPathComponent("extractions")
        var scene: SceneDescription? = try SceneDescriptionLoader.loadSceneDescription(
            wallpaperPath: root.path, assetsPath: root.path, packageTemporaryRoot: temporaryRoot)
        let extracted = try #require(scene?.extractedRoots.first)
        #expect(extracted.deletingLastPathComponent().path == temporaryRoot.path)
        #expect(try String(contentsOf: extracted.appendingPathComponent("asset.txt"), encoding: .utf8) == "owned asset")
        var retainedCopy = scene
        scene = nil
        withExtendedLifetime(retainedCopy) {
            #expect(FileManager.default.fileExists(atPath: extracted.path))
        }
        retainedCopy = nil
        #expect(!FileManager.default.fileExists(atPath: extracted.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("scene.pkg").path))
    }

    @Test(arguments: [false, true])
    func failedLoadsRemovePartialExtractions(escapingEntry: Bool) throws {
        let root = try fixture(invalidScene: !escapingEntry, escapingEntry: escapingEntry)
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryRoot = root.appendingPathComponent("extractions")
        #expect(throws: (any Error).self) {
            try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path,
                                                           packageTemporaryRoot: temporaryRoot)
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
        #expect(remaining.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    private func fixture(invalidScene: Bool = false, escapingEntry: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEPackageLifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json"])
            .write(to: root.appendingPathComponent("project.json"))
        let scene: [String: Any] = invalidScene ? [:] : ["camera": [:], "general": [:], "objects": []]
        var entries = [("scene.json", try JSONSerialization.data(withJSONObject: scene)), ("asset.txt", Data("owned asset".utf8))]
        if escapingEntry { entries.append(("../../escaped.txt", Data("must not escape".utf8))) }
        func u32(_ value: Int) -> Data {
            let value = UInt32(value)
            return Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func string(_ value: String) -> Data { u32(value.utf8.count) + Data(value.utf8) }
        var table = string("PKGV0001") + u32(entries.count)
        var payload = Data()
        for (name, data) in entries {
            table += string(name) + u32(payload.count) + u32(data.count)
            payload += data
        }
        try (table + payload).write(to: root.appendingPathComponent("scene.pkg"))
        return root
    }
}
