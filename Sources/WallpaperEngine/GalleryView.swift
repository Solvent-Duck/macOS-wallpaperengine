import SwiftUI

/// Main gallery view displaying a grid of installed wallpapers
/// with search and tag filtering.
struct GalleryView: View {
    @ObservedObject var viewModel: GalleryViewModel

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            // Tag filter bar
            if !viewModel.allTags.isEmpty {
                tagFilterBar
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
            } else if viewModel.filteredWallpapers.isEmpty {
                Spacer()
                Text(viewModel.wallpapers.isEmpty ? "No wallpapers found" : "No wallpapers match filters")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(viewModel.filteredWallpapers.enumerated()), id: \.offset) { _, wallpaper in
                            WallpaperCard(wallpaper: wallpaper) {
                                if let dirURL = wallpaper.directoryURL {
                                    viewModel.onSelect(dirURL)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search wallpapers")
        .frame(minWidth: 500, minHeight: 400)
    }

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.allTags, id: \.self) { tag in
                    TagChip(
                        tag: tag,
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag)
                .font(.caption)
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

    @ViewBuilder
    private var previewImage: some View {
        if let previewURL = wallpaper.previewURL,
           let nsImage = NSImage(contentsOf: previewURL) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
        }
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
