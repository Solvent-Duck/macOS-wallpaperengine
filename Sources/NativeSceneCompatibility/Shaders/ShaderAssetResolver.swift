import Foundation

public struct ShaderAssetResolver: Sendable {
    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots
    }

    public func vertexShader(_ filename: String) throws -> String {
        try shader(replacingExtension(of: filename, with: "vert"))
    }

    public func fragmentShader(_ filename: String) throws -> String {
        try shader(replacingExtension(of: filename, with: "frag"))
    }

    public func includeShader(_ filename: String) throws -> String {
        try shader(replacingExtension(of: filename, with: "h"))
    }

    public func shader(_ filename: String) throws -> String {
        let fileManager = FileManager.default

        for root in roots {
            if let compatRelativePath = compatReplacementPath(for: filename) {
                let compatURL = root.appending(path: compatRelativePath, directoryHint: .notDirectory)
                if fileManager.fileExists(atPath: compatURL.path()) {
                    return try String(contentsOf: compatURL, encoding: .utf8)
                }
            }

            if let effectsRelativePath = effectsSearchPath(for: filename) {
                let effectsURL = root.appending(path: effectsRelativePath, directoryHint: .notDirectory)
                if fileManager.fileExists(atPath: effectsURL.path()) {
                    return try String(contentsOf: effectsURL, encoding: .utf8)
                }
            }

            let standardURL = root
                .appending(path: "shaders", directoryHint: .isDirectory)
                .appending(path: filename, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: standardURL.path()) {
                return try String(contentsOf: standardURL, encoding: .utf8)
            }
        }

        throw ShaderPipelineError.missingShader(filename)
    }

    private func effectsSearchPath(for filename: String) -> String? {
        guard filename.hasPrefix("effects/") else { return nil }
        let afterPrefix = String(filename.dropFirst("effects/".count))
        let firstComponent = String(afterPrefix.split(separator: "/").first ?? Substring(afterPrefix))
        // Extract the effect name (strip file extension if the first component is a filename)
        let baseName = ((firstComponent as NSString).deletingPathExtension as String)
        guard !baseName.isEmpty else { return nil }
        return "effects/\(baseName)/shaders/\(filename)"
    }

    private func compatReplacementPath(for filename: String) -> String? {
        let components = filename.split(separator: "/").map(String.init)
        guard components.count >= 4, components[0] == "workshop" else {
            return nil
        }

        let workshopID = components[1]
        let shaderFile = components[3]
        return "zcompat/scene/shaders/\(workshopID)/\(shaderFile)"
    }

    private func replacingExtension(of path: String, with ext: String) -> String {
        ((path as NSString).deletingPathExtension as NSString).appendingPathExtension(ext) ?? path
    }
}
