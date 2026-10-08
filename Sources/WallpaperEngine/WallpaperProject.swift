import Foundation
import NativeSceneBridge
import NativeSceneCore

/// Represents the type of a Wallpaper Engine wallpaper.
enum WallpaperType: String, Codable, Sendable {
    case video
    case web
    case scene
    case preset
    case application

    /// Whether this type is currently supported by the macOS renderer.
    var isSupported: Bool {
        switch self {
        case .video, .web, .scene, .preset:
            return true
        case .application:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue.lowercased()) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported wallpaper type: \(rawValue)"
            )
        }
        self = value
    }
}

/// Parsed representation of a Wallpaper Engine `project.json` file.
///
/// Every WE wallpaper directory contains a `project.json` with metadata
/// about the wallpaper type, its main file, title, preview image, and
/// user-configurable properties.
struct WallpaperProject: Codable, Sendable {
    let title: String
    let type: WallpaperType
    let file: String
    let preview: String?
    let description: String?
    var tags: [String]?

    /// The directory containing this project.
    var directoryURL: URL?
    /// Presets keep their own identity and preview, while rendering their dependency.
    var contentDirectoryURL: URL?
    var previewDirectoryURL: URL?
    var presetBaseType: WallpaperType?
    /// Host-level preset options, separate from authored user properties.
    var presetSettings: [String: String] = [:]

    /// User-configurable properties parsed from the `"properties"` block.
    /// Empty for bare media files and wallpapers with no properties.
    var properties: [WallpaperProperty] = []

    /// Native scene metadata normalized through the upstream C++ parsers.
    /// Populated only for scene wallpapers.
    var sceneDescription: SceneDescription?

    enum CodingKeys: String, CodingKey {
        case title, type, file, preview, description, tags
    }

    /// The resolved URL of the main wallpaper file (video, HTML, scene.json, etc.).
    var fileURL: URL? {
        (contentDirectoryURL ?? directoryURL)?.appendingPathComponent(file)
    }

    /// The resolved URL of the preview image.
    var previewURL: URL? {
        guard let preview else { return nil }
        return (previewDirectoryURL ?? directoryURL)?.appendingPathComponent(preview)
    }

    var resolvedTitle: String {
        type == .preset ? title : (sceneDescription?.metadata.title ?? title)
    }

    var resolvedType: WallpaperType {
        if let presetBaseType { return presetBaseType }
        guard let nativeType = sceneDescription?.metadata.projectType else {
            return type
        }

        switch nativeType {
        case .scene:
            return .scene
        case .web:
            return .web
        case .video:
            return .video
        case .unknown:
            return type
        }
    }

    var resolvedProperties: [WallpaperProperty] {
        if type == .preset { return properties }
        guard let native = sceneDescription?.userProperties else { return properties }
        return WallpaperProperty.mergingLayout(native: native.map(WallpaperProperty.init(nativeProperty:)), authored: properties)
    }

    /// Stable identity for library listings, recents and the active wallpaper.
    var libraryPath: String? { directoryURL?.standardizedFileURL.path }

    var sceneResolution: CGSize? {
        guard let resolution = sceneDescription?.metadata.defaultResolution,
              !resolution.isEmpty else {
            return nil
        }
        return CGSize(width: resolution.width, height: resolution.height)
    }
}

/// Loads and parses Wallpaper Engine wallpaper projects.
enum WallpaperLoader {

    /// Attempt to load a wallpaper from a URL.
    ///
    /// Handles four cases:
    /// 1. A directory containing `project.json` (standard WE layout)
    /// 2. A direct `project.json` file
    /// 3. A `.pkg` archive (WE's packed format) — extracts then loads
    /// 4. A bare media file (video/HTML) — wraps it in a synthetic project
    ///
    /// `metadataOnly` skips the native scene parse, which dominates load time;
    /// listings use it and load the full project only when one is opened.
    static func load(from url: URL, metadataOnly: Bool = false) throws -> WallpaperProject {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WallpaperError.fileNotFound(url)
        }

        // Case 1: Directory — look for project.json inside
        if isDirectory.boolValue {
            let projectFile = url.appendingPathComponent("project.json")
            if FileManager.default.fileExists(atPath: projectFile.path) {
                return try loadProject(from: projectFile, directory: url, metadataOnly: metadataOnly)
            }
            throw WallpaperError.noProjectFile(url)
        }

        // Case 2: Direct project.json
        if url.lastPathComponent == "project.json" {
            return try loadProject(from: url, directory: url.deletingLastPathComponent(), metadataOnly: metadataOnly)
        }

        // Case 3: WE .pkg archive — extract to temp dir and load
        if url.pathExtension.lowercased() == "pkg" {
            let extractedDir = try PackageParser.extract(pkgURL: url)
            return try load(from: extractedDir, metadataOnly: metadataOnly)
        }

        // Case 4: Bare media file — create a synthetic project
        return makeSyntheticProject(for: url)
    }

    private static func loadProject(from file: URL, directory: URL, visited: Set<URL> = [], metadataOnly: Bool) throws -> WallpaperProject {
        let identity = directory.resolvingSymlinksInPath().standardizedFileURL
        guard !visited.contains(identity), visited.count < 32 else {
            throw WallpaperError.cyclicPresetDependency(directory)
        }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["dependency"] != nil || (object["type"] as? String)?.lowercased() == "preset" {
            return try loadPreset(object, directory: directory, visited: visited.union([identity]), metadataOnly: metadataOnly)
        }
        let decodedProject: WallpaperProject

        do {
            decodedProject = try decoder.decode(WallpaperProject.self, from: data)
        } catch {
            print("[WallpaperEngine] Project decode failed for \(directory.lastPathComponent): \(error.localizedDescription)")
            throw error
        }

        var project = decodedProject
        project.directoryURL = directory
        project.properties = WallpaperProperty.parse(from: data)

        if project.type == .scene && !metadataOnly {
            do {
                let nativeScene = try SceneDescriptionAdapter.loadSceneDescription(
                    wallpaperPath: directory.path,
                    assetsPath: WallpaperAssets.defaultAssetsPath
                )
                project.sceneDescription = nativeScene
                print(
                    "[WallpaperEngine] Native scene model loaded: nodes=\(nativeScene.nodes.count), " +
                    "properties=\(nativeScene.userProperties.count), " +
                    "resolution=\(nativeScene.metadata.defaultResolution?.width ?? 0)x\(nativeScene.metadata.defaultResolution?.height ?? 0)"
                )
            } catch {
                print("[WallpaperEngine] Native scene model unavailable for \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return project
    }

    private static func loadPreset(_ object: [String: Any], directory: URL, visited: Set<URL>, metadataOnly: Bool) throws -> WallpaperProject {
        guard let dependency = object["dependency"] as? String, !dependency.isEmpty,
              dependency.utf8.allSatisfy({ (48...57).contains($0) }),
              let values = object["preset"] as? [String: Any] else {
            throw WallpaperError.invalidPreset(directory)
        }
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let dependencyDirectory = parent.appendingPathComponent(dependency, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard dependencyDirectory.deletingLastPathComponent() == parent else {
            throw WallpaperError.invalidPreset(directory)
        }
        let dependencyFile = dependencyDirectory.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: dependencyFile.path) else {
            throw WallpaperError.missingPresetDependency(dependency)
        }
        let base = try loadProject(from: dependencyFile, directory: dependencyDirectory, visited: visited, metadataOnly: metadataOnly)
        guard base.resolvedType.isSupported else { throw WallpaperError.unsupportedType(base.resolvedType) }
        var project = WallpaperProject(
            title: object["title"] as? String ?? base.resolvedTitle, type: .preset, file: base.file,
            preview: object["preview"] as? String ?? base.preview,
            description: object["description"] as? String ?? base.description,
            tags: object["tags"] as? [String] ?? base.tags
        )
        project.directoryURL = directory
        project.contentDirectoryURL = base.contentDirectoryURL ?? base.directoryURL
        project.previewDirectoryURL = object["preview"] is String ? directory : (base.previewDirectoryURL ?? base.directoryURL)
        project.presetBaseType = base.resolvedType
        project.sceneDescription = base.sceneDescription
        project.properties = try base.resolvedProperties.map { property in
            guard let value = values[property.key], !(value is NSNull) else { return property }
            return try property.applyingPresetValue(value, directory: directory)
        }
        project.presetSettings = base.presetSettings
        let propertyKeys = Set(project.properties.map(\.key))
        for (key, value) in values where !propertyKeys.contains(key) && !(value is NSNull) {
            if let string = value as? String { project.presetSettings[key] = string }
            else if let number = value as? NSNumber { project.presetSettings[key] = number.stringValue }
        }
        return project
    }

    private static func makeSyntheticProject(for url: URL) -> WallpaperProject {
        let ext = url.pathExtension.lowercased()
        let type: WallpaperType
        switch ext {
        case "mp4", "mov", "avi", "webm", "mkv", "m4v":
            type = .video
        case "html", "htm":
            type = .web
        default:
            type = .video  // Fallback: try to play it as video
        }

        var project = WallpaperProject(
            title: url.deletingPathExtension().lastPathComponent,
            type: type,
            file: url.lastPathComponent,
            preview: nil,
            description: nil,
            tags: nil
        )
        project.directoryURL = url.deletingLastPathComponent()
        return project
    }
}

enum WallpaperError: LocalizedError {
    case fileNotFound(URL)
    case noProjectFile(URL)
    case unsupportedType(WallpaperType)
    case invalidPreset(URL)
    case missingPresetDependency(String)
    case cyclicPresetDependency(URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .noProjectFile(let url):
            return "No project.json found in: \(url.path)"
        case .unsupportedType(let type):
            return "Unsupported wallpaper type: \(type.rawValue)"
        case .invalidPreset(let url):
            return "Invalid wallpaper preset: \(url.path)"
        case .missingPresetDependency(let id):
            return "This preset requires workshop wallpaper \(id). Install its dependency alongside the preset."
        case .cyclicPresetDependency(let url):
            return "Wallpaper preset dependency cycle or excessive nesting: \(url.path)"
        }
    }
}
