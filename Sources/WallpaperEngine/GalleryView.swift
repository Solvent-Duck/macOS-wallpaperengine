import ImageIO
import SwiftUI

/// Main gallery view displaying a grid of installed wallpapers
/// with search, tag filtering, type filtering, and sort controls.
struct GalleryView: View {
    @ObservedObject var viewModel: GalleryViewModel

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar (type chips + tag chips)
            if !viewModel.allTags.isEmpty || viewModel.availableTypes.count > 1 {
                filterBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                Divider()
            }

            // Wallpaper grid
            if viewModel.isScanning {
                Spacer()
                ProgressView("Scanning wallpapers…")
                Spacer()
            } else if viewModel.wallpapers.isEmpty {
                emptyLibrary
            } else if viewModel.filteredWallpapers.isEmpty {
                Spacer()
                Text("No wallpapers match filters")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.filteredWallpapers, id: \.directoryURL) { wallpaper in
                            WallpaperCard(
                                wallpaper: wallpaper,
                                isLoading: wallpaper.directoryURL != nil && viewModel.loadingURL == wallpaper.directoryURL
                            ) {
                                if let dirURL = wallpaper.directoryURL {
                                    viewModel.select(dirURL)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search wallpapers")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                sortMenu
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.onChooseFolder?()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .help(folderHelp)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var folderHelp: String {
        let paths = viewModel.scannedDirectories.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        return paths.isEmpty ? "Choose wallpaper folder" : "Scanning: " + paths.joined(separator: ", ")
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No wallpapers found")
                .font(.title3)
            Group {
                if viewModel.scannedDirectories.isEmpty {
                    Text("Neither ~/Wallpaper Projects nor the Steam Workshop folder exists.")
                } else {
                    Text("Looked in " + viewModel.scannedDirectories
                        .map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: " and "))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button("Choose Folder…") { viewModel.onChooseFolder?() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            ForEach(GallerySortOrder.allCases, id: \.self) { order in
                Button {
                    viewModel.sortOrder = order
                } label: {
                    if viewModel.sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Type chips (only when more than one type is present)
            if viewModel.availableTypes.count > 1 {
                typeFilterRow
            }

            // Tag chips
            if !viewModel.allTags.isEmpty {
                tagChipRow
            }

            // AND/OR toggle + Clear button
            if !viewModel.selectedTags.isEmpty || viewModel.hasActiveFilters {
                HStack(spacing: 8) {
                    if !viewModel.selectedTags.isEmpty {
                        Picker("", selection: $viewModel.tagFilterMode) {
                            Text("Any tag").tag(TagFilterMode.any)
                            Text("All tags").tag(TagFilterMode.all)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    Spacer()

                    if viewModel.hasActiveFilters {
                        Button("Clear") { viewModel.clearFilters() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var typeFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([WallpaperType.video, .web, .scene], id: \.self) { type in
                    if viewModel.availableTypes.contains(type) {
                        TagChip(
                            tag: type.rawValue.capitalized,
                            count: nil,
                            isSelected: viewModel.selectedTypes.contains(type)
                        ) {
                            viewModel.toggleType(type)
                        }
                    }
                }
            }
        }
    }

    private var tagChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.allTags, id: \.self) { tag in
                    TagChip(
                        tag: tag,
                        count: viewModel.tagCount(for: tag),
                        isSelected: viewModel.selectedTags.contains(tag)
                    ) {
                        viewModel.toggleTag(tag)
                    }
                }
            }
        }
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let tag: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(tag)
                    .font(.caption)

                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Wallpaper Card

private struct WallpaperCard: View {
    let wallpaper: WallpaperProject
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                // Preview image
                previewImage
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        typeBadge
                    }
                    .overlay {
                        if isLoading {
                            ZStack {
                                Color.black.opacity(0.35)
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(wallpaper.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let tags = wallpaper.tags, !tags.isEmpty {
                        Text(tags.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovered ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var previewImage: some View {
        PreviewThumbnail(url: wallpaper.previewURL)
    }

    private var typeBadge: some View {
        Text(wallpaper.type.rawValue.capitalized)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(6)
    }
}

// MARK: - Preview Thumbnail

/// Decodes previews off the main thread at card size, so scrolling a large
/// library doesn't decode full-resolution images (or whole GIFs) in `body`.
struct PreviewThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.2))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { failed = true; return }
            if let cached = ThumbnailCache.shared.object(forKey: url as NSURL) {
                image = cached
                return
            }
            let cgImage = await Task.detached(priority: .utility) {
                ThumbnailCache.decode(url)
            }.value
            guard !Task.isCancelled else { return }
            if let cgImage {
                let decoded = NSImage(cgImage: cgImage, size: .zero)
                ThumbnailCache.shared.setObject(decoded, forKey: url as NSURL)
                image = decoded
            } else {
                failed = true
            }
        }
    }
}

private enum ThumbnailCache {
    @MainActor static let shared: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    /// First frame, downscaled to fit the largest card at 2x.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
