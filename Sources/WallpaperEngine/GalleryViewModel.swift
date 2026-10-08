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
    /// Workshop subscriptions being downloaded (not wallpapers yet).
    case downloads
    /// The Steam Workshop catalogue.
    case browse
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
    /// Workshop ID of the catalogue item shown in the inspector while browsing.
    @Published var selectedWorkshopID: String?
    /// Favorites are keyed by folder name, like saved properties, so copies share them.
    @Published private(set) var favorites: Set<String>

    @Published var sortOrder: GallerySortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "gallery.sortOrder") }
    }

    private var tagCounts: [String: Int] = [:]
    private var typeCounts: [WallpaperType: Int] = [:]
    private var scanGeneration = 0
    private var changedDuringScan = Set<String>()

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
            case .downloads, .browse: return false
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

    /// The library wallpaper whose folder is named `name` (a Workshop ID for
    /// Workshop items), if any.
    func wallpaper(inFolderNamed name: String) -> WallpaperProject? {
        wallpapers.first { $0.directoryURL?.lastPathComponent == name }
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

            wallpapers = projects
            recount()
            isScanning = false
            // Folders that changed on disk while the scan ran may have been
            // read before the change.
            let changed = changedDuringScan
            changedDuringScan.removeAll()
            for name in changed { refreshFolder(named: name) }
        }
    }

    /// Re-resolve one wallpaper folder name after it was added, changed or
    /// removed on disk: the earliest scanned directory holding a loadable
    /// project by that name wins, as in a full scan.
    func refreshFolder(named name: String) {
        guard hasScanned else { return }
        if isScanning {
            changedDuringScan.insert(name)
            return
        }
        let winner = scannedDirectories.lazy.compactMap { directory in
            Self.loadProject(at: directory.appendingPathComponent(name, isDirectory: true), tags: Self.sidecarTags(in: directory))
        }.first
        let index = wallpapers.firstIndex { $0.directoryURL?.lastPathComponent == name }
        switch (index, winner) {
        case let (index?, winner?):
            if selectedPath == wallpapers[index].libraryPath { selectedPath = winner.libraryPath }
            wallpapers[index] = winner
        case let (nil, winner?):
            wallpapers.append(winner)
        case let (index?, nil):
            if selectedPath == wallpapers[index].libraryPath { selectedPath = nil }
            wallpapers.remove(at: index)
        case (nil, nil):
            return
        }
        recount()
    }

    private func recount() {
        var tagCounts: [String: Int] = [:]
        var typeCounts: [WallpaperType: Int] = [:]
        for project in wallpapers {
            typeCounts[project.type, default: 0] += 1
            for tag in Set(project.tags ?? []) { tagCounts[tag, default: 0] += 1 }
        }
        self.tagCounts = tagCounts
        self.typeCounts = typeCounts
        allTags = tagCounts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func scanProjects(in directory: URL, skipping seenNames: inout Set<String>) -> [WallpaperProject] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let tags = sidecarTags(in: directory)
        var projects: [WallpaperProject] = []
        for itemURL in contents {
            guard !seenNames.contains(itemURL.lastPathComponent),
                  let project = loadProject(at: itemURL, tags: tags) else { continue }
            seenNames.insert(itemURL.lastPathComponent)
            projects.append(project)
        }
        return projects
    }

    /// Load one wallpaper folder's metadata, or nil if it isn't a wallpaper.
    nonisolated static func loadProject(at folder: URL, tags: [String: [String]]?) -> WallpaperProject? {
        let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir, var project = try? WallpaperLoader.load(from: folder, metadataOnly: true) else { return nil }
        if let merged = tags?[folder.lastPathComponent] { project.tags = merged }
        return project
    }

    /// Tags from a directory's `tags.json` sidecar, keyed by folder name. When
    /// present it is the sole tag source for this build; project.json tags are
    /// the fallback only when it does not exist.
    nonisolated static func sidecarTags(in directory: URL) -> [String: [String]]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("tags.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        return json.compactMapValues { $0["merged_tags"] as? [String] }
    }
}
