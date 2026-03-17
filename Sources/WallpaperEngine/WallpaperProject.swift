import Foundation

/// Represents the type of a Wallpaper Engine wallpaper.
enum WallpaperType: String, Codable {
    case video
    case web
    case scene
    case preset
    case application

    /// Whether this type is currently supported by the macOS renderer.
    var isSupported: Bool {
        switch self {
        case .video, .web:
            return true
        case .scene, .preset, .application:
            return false
        }
    }
}

/// Parsed representation of a Wallpaper Engine `project.json` file.
///
/// Every WE wallpaper directory contains a `project.json` with metadata
/// about the wallpaper type, its main file, title, preview image, and
/// user-configurable properties.
struct WallpaperProject: Codable {
    let title: String
    let type: WallpaperType
    let file: String
    let preview: String?
    let description: String?

    /// The directory containing this project.
    var directoryURL: URL?

    enum CodingKeys: String, CodingKey {
        case title, type, file, preview, description
    }

    /// The resolved URL of the main wallpaper file (video, HTML, scene.json, etc.).
    var fileURL: URL? {
        directoryURL?.appendingPathComponent(file)
    }

    /// The resolved URL of the preview image.
    var previewURL: URL? {
        guard let preview else { return nil }
        return directoryURL?.appendingPathComponent(preview)
    }
}

/// Loads and parses Wallpaper Engine wallpaper projects.
enum WallpaperLoader {

    /// Attempt to load a wallpaper from a URL.
    ///
    /// Handles three cases:
    /// 1. A directory containing `project.json` (standard WE layout)
    /// 2. A direct `project.json` file
    /// 3. A bare media file (video/HTML) — wraps it in a synthetic project
    static func load(from url: URL) throws -> WallpaperProject {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WallpaperError.fileNotFound(url)
        }

        // Case 1: Directory — look for project.json inside
        if isDirectory.boolValue {
            let projectFile = url.appendingPathComponent("project.json")
            if FileManager.default.fileExists(atPath: projectFile.path) {
                return try loadProject(from: projectFile, directory: url)
            }
            throw WallpaperError.noProjectFile(url)
        }

        // Case 2: Direct project.json
        if url.lastPathComponent == "project.json" {
            return try loadProject(from: url, directory: url.deletingLastPathComponent())
        }

        // Case 3: Bare media file — create a synthetic project
        return makeSyntheticProject(for: url)
    }

    private static func loadProject(from file: URL, directory: URL) throws -> WallpaperProject {
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        var project = try decoder.decode(WallpaperProject.self, from: data)
        project.directoryURL = directory
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
            description: nil
        )
        project.directoryURL = url.deletingLastPathComponent()
        return project
    }
}

enum WallpaperError: LocalizedError {
    case fileNotFound(URL)
    case noProjectFile(URL)
    case unsupportedType(WallpaperType)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .noProjectFile(let url):
            return "No project.json found in: \(url.path)"
        case .unsupportedType(let type):
            return "Unsupported wallpaper type: \(type.rawValue)"
        }
    }
}
