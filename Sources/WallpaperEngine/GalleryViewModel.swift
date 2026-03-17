import Foundation
import AppKit

/// Scans a directory for Wallpaper Engine projects and provides
/// filtering for the gallery UI.
class GalleryViewModel: ObservableObject {
    @Published var wallpapers: [WallpaperProject] = []
    @Published var allTags: [String] = []
    @Published var selectedTags: Set<String> = []
    @Published var searchText: String = ""
    @Published var isScanning = false

    let onSelect: (URL) -> Void

    var filteredWallpapers: [WallpaperProject] {
        wallpapers.filter { wp in
            let matchesSearch = searchText.isEmpty ||
                wp.title.localizedCaseInsensitiveContains(searchText)

            let matchesTags = selectedTags.isEmpty ||
                !(wp.tags ?? []).filter({ selectedTags.contains($0) }).isEmpty

            return matchesSearch && matchesTags
        }
    }

    init(onSelect: @escaping (URL) -> Void) {
        self.onSelect = onSelect
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

            projects.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

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

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
}
