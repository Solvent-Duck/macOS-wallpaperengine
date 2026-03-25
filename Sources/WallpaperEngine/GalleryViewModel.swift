import Foundation
import AppKit

enum GallerySortOrder: String, CaseIterable {
    case titleAscending  = "Title A–Z"
    case titleDescending = "Title Z–A"
    case type            = "Type"
    case tagCount        = "Most Tags"
}

enum TagFilterMode: String {
    case any  // OR — wallpaper must match at least one selected tag
    case all  // AND — wallpaper must match every selected tag
}

/// Scans a directory for Wallpaper Engine projects and provides
/// filtering for the gallery UI.
class GalleryViewModel: ObservableObject {
    @Published var wallpapers: [WallpaperProject] = []
    @Published var allTags: [String] = []
    @Published var selectedTags: Set<String> = []
    @Published var selectedTypes: Set<WallpaperType> = []
    @Published var searchText: String = ""
    @Published var isScanning = false

    @Published var sortOrder: GallerySortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "gallery.sortOrder") }
    }
    @Published var tagFilterMode: TagFilterMode {
        didSet { UserDefaults.standard.set(tagFilterMode.rawValue, forKey: "gallery.tagFilterMode") }
    }

    let onSelect: (URL) -> Void

    init(onSelect: @escaping (URL) -> Void) {
        self.onSelect = onSelect

        let savedSort = UserDefaults.standard.string(forKey: "gallery.sortOrder")
            .flatMap(GallerySortOrder.init(rawValue:)) ?? .titleAscending
        let savedMode = UserDefaults.standard.string(forKey: "gallery.tagFilterMode")
            .flatMap(TagFilterMode.init(rawValue:)) ?? .any

        self.sortOrder = savedSort
        self.tagFilterMode = savedMode
    }

    var filteredWallpapers: [WallpaperProject] {
        let filtered = wallpapers.filter { wp in
            let matchesSearch = searchText.isEmpty
                || wp.title.localizedCaseInsensitiveContains(searchText)

            let matchesType = selectedTypes.isEmpty
                || selectedTypes.contains(wp.type)

            let wpTags = wp.tags ?? []
            let matchesTags: Bool
            if selectedTags.isEmpty {
                matchesTags = true
            } else if tagFilterMode == .any {
                matchesTags = selectedTags.contains(where: wpTags.contains)
            } else {
                matchesTags = selectedTags.allSatisfy(wpTags.contains)
            }

            return matchesSearch && matchesType && matchesTags
        }

        return filtered.sorted { a, b in
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

    var availableTypes: Set<WallpaperType> {
        Set(wallpapers.map(\.type))
    }

    var hasActiveFilters: Bool {
        !selectedTags.isEmpty || !selectedTypes.isEmpty
    }

    func tagCount(for tag: String) -> Int {
        wallpapers.filter { $0.tags?.contains(tag) ?? false }.count
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    func toggleType(_ type: WallpaperType) {
        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
    }

    func clearFilters() {
        selectedTags.removeAll()
        selectedTypes.removeAll()
    }

    func scan(directory: URL) {
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var projects: [WallpaperProject] = []
            let fm = FileManager.default

            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                DispatchQueue.main.async {
                    self?.isScanning = false
                }
                return
            }

            for itemURL in contents {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }

                if let project = try? WallpaperLoader.load(from: itemURL) {
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

            var tagSet = Set<String>()
            for project in projects {
                for tag in project.tags ?? [] {
                    tagSet.insert(tag)
                }
            }

            DispatchQueue.main.async {
                self?.wallpapers = projects
                self?.allTags = tagSet.sorted()
                self?.isScanning = false
            }
        }
    }
}
