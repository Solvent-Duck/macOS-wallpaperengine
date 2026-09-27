import Foundation

enum WallpaperAssets {
    static var defaultAssetsPath: String {
        if let custom = UserDefaults.standard.string(forKey: "WEAssetsPath"), !custom.isEmpty {
            return custom
        }

        let candidates = [
            NSHomeDirectory() + "/wallpaper_engine/assets",
            NSHomeDirectory() + "/Library/Application Support/wallpaper_engine/assets",
            NSHomeDirectory() + "/.local/share/wallpaper_engine/assets",
            "/usr/local/share/wallpaper_engine/assets",
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }

        return candidates[0]
    }
}
