import Foundation

struct RecentWallpaper: Codable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let previewPath: String?

    var url: URL { URL(fileURLWithPath: path) }
    var previewURL: URL? { previewPath.map { URL(fileURLWithPath: $0) } }
}

/// Most-recently-applied wallpapers, newest first, plus the one to restore on launch.
struct RecentWallpapers {
    static let limit = 8
    private static let listKey = "RecentWallpapers"
    private static let lastKey = "LastWallpaperPath"
    private static let restoreKey = "RestoreLastWallpaper"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Entries whose folder or file still exists.
    var items: [RecentWallpaper] {
        guard let data = defaults.data(forKey: Self.listKey),
              let items = try? JSONDecoder().decode([RecentWallpaper].self, from: data) else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func record(_ project: WallpaperProject, loadedFrom url: URL) {
        let entry = RecentWallpaper(
            path: url.standardizedFileURL.path,
            title: project.resolvedTitle,
            previewPath: project.previewURL?.path
        )
        let updated = [entry] + items.filter { $0.path != entry.path }
        if let data = try? JSONEncoder().encode(Array(updated.prefix(Self.limit))) {
            defaults.set(data, forKey: Self.listKey)
        }
        defaults.set(entry.path, forKey: Self.lastKey)
    }

    /// Clearing the wallpaper means "show my normal desktop" after the next launch too.
    func forgetLast() {
        defaults.removeObject(forKey: Self.lastKey)
    }

    var restoresOnLaunch: Bool {
        get { defaults.object(forKey: Self.restoreKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.restoreKey) }
    }

    /// The wallpaper to load at launch, if restoring is on and it still exists.
    var wallpaperToRestore: URL? {
        guard restoresOnLaunch, let path = defaults.string(forKey: Self.lastKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
