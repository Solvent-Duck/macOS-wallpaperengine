import Foundation
import NativeSceneCore

public enum SceneDescriptionAdapterError: Error, LocalizedError {
    case loadingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .loadingFailed(let message):
            return "Failed to load scene description: \(message)"
        }
    }
}

public enum SceneDescriptionAdapter {
    public static func loadSceneDescription(
        wallpaperPath: String,
        assetsPath: String
    ) throws -> SceneDescription {
        do {
            return try SceneDescriptionLoader.loadSceneDescription(
                wallpaperPath: wallpaperPath,
                assetsPath: assetsPath
            )
        } catch {
            throw SceneDescriptionAdapterError.loadingFailed(error.localizedDescription)
        }
    }
}
