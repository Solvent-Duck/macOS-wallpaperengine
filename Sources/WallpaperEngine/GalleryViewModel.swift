import Foundation
import AppKit

enum GallerySortOrder: String, CaseIterable {
    case titleAscending  = "Title A–Z"
    case titleDescending = "Title Z–A"
    case type            = "Type"
    case tagCount        = "Most Tags"
}

/// What the library sidebar shows.
enum LibraryFilter: Hashable {
    case all, favorites, recent
    case type(WallpaperType)
    case tag(String)
}

/// Scans the library folders and provides filtering, favorites and selection
/// for the library window. Kept alive across window closes so reopening the
/// library doesn't rescan.
@MainActor
final class GalleryViewModel: ObservableObject {
    private static let favoritesKey = "FavoriteWallpapers"

    @Published private(set) var wallpapers: [WallpaperProject] = []
    @Published private(set) var allTags: [String] = []
    @Published private(set) var isScanning = false
    /// Folders included in the most recent scan; empty when none exist.
    @Published private(set) var scannedDirectories: [URL] = []
    @Published var filter: LibraryFilter = .all
    @Published var searchText: String = ""
    /// `libraryPath` of the wallpaper shown in the inspector.
    @Published var selectedPath: String?
    /// Favorites are keyed by folder name, like saved properties, so copies share them.
    @Published private(set) var favorites: Set<String>

    @Published var sortOrder: GallerySortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "gallery.sortOrder") }
    }

    private var tagCounts: [String: Int] = [:]
    private var typeCounts: [WallpaperType: Int] = [:]
    private var scanGeneration = 0

    /// Recently applied wallpaper paths, newest first.
    var recentPaths: () -> [String] = { [] }

    init() {
        sortOrder = UserDefaults.standard.string(forKey: "gallery.sortOrder")
            .flatMap(GallerySortOrder.init(rawValue:)) ?? .titleAscending
        favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [])
    }

    var hasScanned: Bool { !scannedDirectories.isEmpty || !wallpapers.isEmpty }

    var filteredWallpapers: [WallpaperProject] {
        let recents = recentPaths()
        let matching = wallpapers.filter { wallpaper in
            guard searchText.isEmpty || wallpaper.title.localizedCaseInsensitiveContains(searchText) else { return false }
            switch filter {
            case .all: return true
            case .favorites: return isFavorite(wallpaper)
            case .recent: return wallpaper.libraryPath.map(recents.contains) ?? false
            case .type(let type): return wallpaper.type == type
            case .tag(let tag): return wallpaper.tags?.contains(tag) ?? false
            }
        }
        if filter == .recent {
            let rank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return matching.sorted { (rank[$0.libraryPath ?? ""] ?? .max) < (rank[$1.libraryPath ?? ""] ?? .max) }
        }
        return matching.sorted { a, b in
            switch sortOrder {
            case .titleAscending:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .titleDescending:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedDescending
            case .type:
                if a.type.rawValue != b.type.rawValue { return a.type.rawValue < b.type.rawValue }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .tagCount:
                let ac = a.tags?.count ?? 0, bc = b.tags?.count ?? 0
                if ac != bc { return ac > bc }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Types present in the library, in a fixed display order.
    var availableTypes: [WallpaperType] {
        [.scene, .video, .web, .preset].filter { typeCounts[$0, default: 0] > 0 }
    }

    func count(for type: WallpaperType) -> Int { typeCounts[type, default: 0] }
    func tagCount(for tag: String) -> Int { tagCounts[tag, default: 0] }

    var selectedWallpaper: WallpaperProject? {
        guard let selectedPath else { return nil }
        return wallpapers.first { $0.libraryPath == selectedPath }
    }

    enum Move { case left, right, up, down }

    /// Move the selection through the visible grid, `columns` cards per row.
    /// With nothing selected, any move selects the first wallpaper.
    func moveSelection(_ move: Move, columns: Int) {
        let paths = filteredWallpapers.compactMap(\.libraryPath)
        guard !paths.isEmpty else { return }
        guard let current = selectedPath.flatMap(paths.firstIndex(of:)) else {
            selectedPath = paths[0]
            return
        }
        let step = max(1, columns)
        let target: Int
        switch move {
        case .left: target = current - 1
        case .right: target = current + 1
        case .up: target = current - step
        case .down: target = current + step
        }
        // Rows clamp at the ends; a partial last row is still reachable going down.
        selectedPath = paths[min(max(target, 0), paths.count - 1)]
    }

    func isFavorite(_ wallpaper: WallpaperProject) -> Bool {
        wallpaper.directoryURL.map { favorites.contains($0.lastPathComponent) } ?? false
    }

    func toggleFavorite(_ wallpaper: WallpaperProject) {
        guard let name = wallpaper.directoryURL?.lastPathComponent else { return }
        if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
        UserDefaults.standard.set(favorites.sorted(), forKey: Self.favoritesKey)
    }

    /// Scan each directory's immediate subfolders. A wallpaper folder name that
    /// appears in more than one directory is kept from the earliest directory.
    func scan(directories: [URL]) {
        isScanning = true
        scannedDirectories = directories
        scanGeneration += 1
        let generation = scanGeneration

        Task {
            let projects = await Task.detached(priority: .userInitiated) {
                var projects: [WallpaperProject] = []
                var seenNames = Set<String>()
                for directory in directories {
                    projects += Self.scanProjects(in: directory, skipping: &seenNames)
                }
                return projects
            }.value
            guard generation == scanGeneration else { return }

            var tagCounts: [String: Int] = [:]
            var typeCounts: [WallpaperType: Int] = [:]
            for project in projects {
                typeCounts[project.type, default: 0] += 1
                for tag in Set(project.tags ?? []) { tagCounts[tag, default: 0] += 1 }
            }
            self.tagCounts = tagCounts
            self.typeCounts = typeCounts
            wallpapers = projects
            allTags = tagCounts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            isScanning = false
        }
    }

    nonisolated static func scanProjects(in directory: URL, skipping seenNames: inout Set<String>) -> [WallpaperProject] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var projects: [WallpaperProject] = []
        for itemURL in contents {
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, !seenNames.contains(itemURL.lastPathComponent) else { continue }

            if let project = try? WallpaperLoader.load(from: itemURL, metadataOnly: true) {
                seenNames.insert(itemURL.lastPathComponent)
                projects.append(project)
            }
        }

        // Load tags.json sidecar if present; it is the sole tag source for this build.
        // Falls back to project.json tags only when tags.json does not exist.
        let sidecarURL = directory.appendingPathComponent("tags.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for i in projects.indices {
                let workshopId = projects[i].directoryURL?.lastPathComponent ?? ""
                if let merged = json[workshopId]?["merged_tags"] as? [String] {
                    projects[i].tags = merged
                }
            }
        }
        return projects
    }
}
