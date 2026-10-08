import AppKit
import ImageIO
import SteamLibrary
import SwiftUI

/// The wallpaper library: sidebar filters, a grid of wallpapers and an
/// inspector with details, Apply and the selected wallpaper's properties.
struct GalleryView: View {
    @ObservedObject var library: GalleryViewModel
    let appModel: AppModel
    @State private var showsInspector = true
    @State private var gridWidth: CGFloat = 0
    @State private var isDropTargeted = false
    @FocusState private var gridFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: library, sync: appModel.workshopSync)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    library.selectedPath = url.standardizedFileURL.path
                    Task { await appModel.load(url) }
                    return true
                } isTargeted: { isDropTargeted = $0 }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                            .padding(8)
                            .overlay {
                                Label("Drop to apply this wallpaper", systemImage: "arrow.down.doc")
                                    .font(.headline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .allowsHitTesting(false)
                    }
                }
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
        .searchable(text: $library.searchText, prompt: library.filter == .browse ? "Search the Workshop" : "Search wallpapers")
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                sortMenu
                Button {
                    appModel.rescanLibrary()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan the library folders")
                .disabled(library.isScanning)
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(showsInspector ? "Hide details" : "Show details")
            }
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    private var title: String {
        switch library.filter {
        case .all: return "All Wallpapers"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .downloads: return "Downloads"
        case .browse: return "Steam Workshop"
        case .type(let type): return type.displayName
        case .tag(let tag): return tag.capitalized
        }
    }

    private var subtitle: String {
        if library.filter == .browse {
            return library.searchText.isEmpty ? "Browse" : "Search results"
        }
        if library.filter == .downloads {
            let count = appModel.workshopSync.activeDownloads.count
            return count == 1 ? "1 item" : "\(count) items"
        }
        if library.isScanning && library.wallpapers.isEmpty { return "Scanning…" }
        let count = library.filteredWallpapers.count
        return count == 1 ? "1 wallpaper" : "\(count) wallpapers"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let wallpapers = library.filteredWallpapers
        if library.filter == .browse {
            WorkshopBrowseView(sync: appModel.workshopSync, library: library, appModel: appModel)
        } else if library.filter == .downloads {
            WorkshopDownloadsView(sync: appModel.workshopSync)
        } else if library.isScanning && library.wallpapers.isEmpty {
            ProgressView("Scanning wallpapers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.wallpapers.isEmpty {
            emptyLibrary
        } else if wallpapers.isEmpty {
            ContentUnavailableView {
                Label(emptyFilterTitle, systemImage: emptyFilterIcon)
            } description: {
                Text(emptyFilterMessage)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(wallpapers, id: \.libraryPath) { wallpaper in
                            card(for: wallpaper)
                                .id(wallpaper.libraryPath)
                        }
                    }
                    .padding(16)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
                    handleKey(press.key, proxy: proxy)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// Cards per row, matching the adaptive grid (16 pt padding and spacing).
    private var columnCount: Int {
        max(1, Int((gridWidth - 32 + 16) / (190 + 16)))
    }

    private func handleKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        switch key {
        case .return:
            guard let wallpaper = library.selectedWallpaper else { return .ignored }
            apply(wallpaper)
            return .handled
        case .leftArrow: library.moveSelection(.left, columns: columnCount)
        case .rightArrow: library.moveSelection(.right, columns: columnCount)
        case .upArrow: library.moveSelection(.up, columns: columnCount)
        case .downArrow: library.moveSelection(.down, columns: columnCount)
        default: return .ignored
        }
        if let path = library.selectedPath {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path) }
        }
        return .handled
    }

    private func card(for wallpaper: WallpaperProject) -> some View {
        let path = wallpaper.libraryPath
        return WallpaperCard(
            wallpaper: wallpaper,
            isSelected: path != nil && path == library.selectedPath,
            isActive: path != nil && path == appModel.snapshot.directoryPath,
            isLoading: appModel.loadingName != nil && appModel.loadingName == wallpaper.directoryURL?.lastPathComponent,
            isFavorite: library.isFavorite(wallpaper),
            onSelect: {
                library.selectedPath = path
                gridFocused = true
            },
            onApply: { apply(wallpaper) },
            onToggleFavorite: { library.toggleFavorite(wallpaper) },
            onUnsubscribe: wallpaper.steamWorkshopID.map { id in
                {
                    if confirmUnsubscribe(title: wallpaper.title, isActive: path != nil && path == appModel.snapshot.directoryPath) {
                        appModel.workshopSync.unsubscribe(id)
                    }
                }
            }
        )
    }

    private func apply(_ wallpaper: WallpaperProject) {
        guard let url = wallpaper.directoryURL else { return }
        library.selectedPath = wallpaper.libraryPath
        Task { await appModel.load(url) }
    }

    private var emptyFilterTitle: String {
        if !library.searchText.isEmpty { return "No Results" }
        switch library.filter {
        case .favorites: return "No Favorites Yet"
        case .recent: return "Nothing Recent"
        default: return "No Wallpapers"
        }
    }

    private var emptyFilterIcon: String {
        switch library.filter {
        case .favorites: return "heart"
        case .recent: return "clock"
        default: return "magnifyingglass"
        }
    }

    private var emptyFilterMessage: String {
        if !library.searchText.isEmpty { return "No wallpapers here match “\(library.searchText)”." }
        switch library.filter {
        case .favorites: return "Click the heart on a wallpaper to keep it here."
        case .recent: return "Wallpapers you apply will show up here."
        default: return "Nothing in the library matches this filter."
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Wallpapers Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            VStack(spacing: 8) {
                if library.scannedDirectories.isEmpty {
                    Text("Neither ~/Wallpaper Projects nor the Steam Workshop folder exists.")
                } else {
                    Text("Looked in " + library.scannedDirectories
                        .map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        .joined(separator: " and ") + ".")
                }
                Text("Subscribe to wallpapers in Wallpaper Engine’s Steam Workshop, then copy their folders into ~/Wallpaper Projects — or choose the folder that already holds them. You can also drop a wallpaper folder or video here to apply it.")
            }
        } actions: {
            if appModel.canCreateDefaultLibraryFolder {
                Button("Create Wallpaper Projects Folder") { appModel.createDefaultLibraryFolder() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Folder…") { appModel.chooseLibraryFolder() }
            } else {
                Button("Choose Folder…") { appModel.chooseLibraryFolder() }
                    .buttonStyle(.borderedProminent)
                Button("Rescan") { appModel.rescanLibrary() }
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if library.filter == .browse {
            browseInspector
        } else if let wallpaper = selectedWallpaper {
            LibraryInspector(wallpaper: wallpaper, library: library, appModel: appModel)
                .id(wallpaper.libraryPath)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                   description: Text("Select a wallpaper to see its details and settings. Double-click to apply it."))
        }
    }

    /// A catalogue item already in the library gets the library inspector
    /// (Apply, properties), so one wallpaper never has two inspectors.
    @ViewBuilder
    private var browseInspector: some View {
        let sync = appModel.workshopSync
        if let id = library.selectedWorkshopID, let local = library.wallpaper(inFolderNamed: id) {
            LibraryInspector(wallpaper: local, library: library, appModel: appModel)
                .id(local.libraryPath)
        } else if let id = library.selectedWorkshopID, let item = sync.browse.items.first(where: { $0.id == id }) {
            WorkshopItemInspector(item: item, sync: sync, library: library)
                .id(item.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                   description: Text("Select a Workshop item to see its details. Double-click to subscribe."))
        }
    }

    /// The selected library item, or the active wallpaper when it was opened
    /// from outside the library folders.
    private var selectedWallpaper: WallpaperProject? {
        if let wallpaper = library.selectedWallpaper { return wallpaper }
        guard let path = library.selectedPath, path == appModel.snapshot.directoryPath else { return nil }
        return appModel.windowManager.currentProject
    }

    // MARK: Sort Menu

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $library.sortOrder) {
                ForEach(GallerySortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort wallpapers")
    }
}

extension WallpaperType {
    var displayName: String {
        switch self {
        case .scene: return "Scenes"
        case .video: return "Videos"
        case .web: return "Web"
        case .preset: return "Presets"
        case .application: return "Applications"
        }
    }

    var symbolName: String {
        switch self {
        case .scene: return "cube.transparent"
        case .video: return "film"
        case .web: return "globe"
        case .preset: return "slider.horizontal.below.square.filled.and.square"
        case .application: return "app"
        }
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @ObservedObject var library: GalleryViewModel
    let sync: WorkshopSync
    @State private var showsTags = true

    var body: some View {
        List(selection: Binding<LibraryFilter?>(
            get: { library.filter },
            set: { if let filter = $0 { library.filter = filter } }
        )) {
            Section("Library") {
                row("All Wallpapers", icon: "square.grid.2x2", filter: .all, count: library.wallpapers.count)
                row("Favorites", icon: "heart", filter: .favorites, count: nil)
                row("Recent", icon: "clock", filter: .recent, count: nil)
            }
            Section("Steam Workshop") {
                row("Browse", icon: "globe", filter: .browse, count: nil)
                if !sync.downloads.isEmpty || library.filter == .downloads {
                    row("Downloads", icon: "arrow.down.circle", filter: .downloads, count: sync.activeDownloads.count)
                }
            }
            if library.availableTypes.count > 1 {
                Section("Types") {
                    ForEach(library.availableTypes, id: \.self) { type in
                        row(type.displayName, icon: type.symbolName, filter: .type(type), count: library.count(for: type))
                    }
                }
            }
            if !library.allTags.isEmpty {
                Section("Tags", isExpanded: $showsTags) {
                    ForEach(library.allTags, id: \.self) { tag in
                        row(tag.capitalized, icon: "tag", filter: .tag(tag), count: library.tagCount(for: tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, icon: String, filter: LibraryFilter, count: Int?) -> some View {
        Label(title, systemImage: icon)
            .badge(count ?? 0)
            .tag(filter)
    }
}

// MARK: - Wallpaper Card

struct WallpaperCard: View {
    let wallpaper: WallpaperProject
    let isSelected: Bool
    let isActive: Bool
    let isLoading: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onToggleFavorite: () -> Void
    /// Set for Steam's own copies of Workshop items.
    var onUnsubscribe: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { PreviewThumbnail(url: wallpaper.previewURL) }
                .clipped()
                .overlay(alignment: .topLeading) { favoriteButton }
                .overlay(alignment: .topTrailing) { badges }
                .overlay {
                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.35)
                            ProgressView().controlSize(.small)
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.2 : 0.08),
                              lineWidth: isSelected ? 3 : 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 6 : 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onTapGesture(count: 2, perform: onApply)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu {
            Button(isActive ? "Reapply" : "Apply", action: onApply)
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            if let url = wallpaper.directoryURL {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let id = wallpaper.steamWorkshopID {
                Button("Open Workshop Page") { WorkshopLinks.openPage(for: id) }
                if let onUnsubscribe {
                    Divider()
                    Button("Unsubscribe on Steam…", action: onUnsubscribe)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wallpaper.title)
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Double-click or press Return to apply")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: isActive ? "Reapply" : "Apply", onApply)
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites", onToggleFavorite)
    }

    private var accessibilityStatus: String {
        var parts = [subtitle]
        if isActive { parts.append("Active") }
        if isFavorite { parts.append("Favorite") }
        if isLoading { parts.append("Loading") }
        return parts.joined(separator: ", ")
    }

    private var subtitle: String {
        let tags = (wallpaper.tags ?? []).prefix(3).map(\.capitalized).joined(separator: ", ")
        let type = wallpaper.type.rawValue.capitalized
        return tags.isEmpty ? type : "\(type) · \(tags)"
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if isFavorite || isHovered {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isFavorite ? Color.pink : Color.white)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    @ViewBuilder
    private var badges: some View {
        if isActive {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
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
            let cgImage: CGImage?
            if url.isFileURL {
                cgImage = await Task.detached(priority: .utility) { ThumbnailCache.decode(url) }.value
            } else {
                // Workshop previews for items not downloaded yet.
                let data = try? await URLSession.shared.data(from: url).0
                cgImage = await Task.detached(priority: .utility) { data.flatMap(ThumbnailCache.decode(data:)) }.value
            }
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
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(thumbnail)
    }

    nonisolated static func decode(data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(thumbnail)
    }

    private nonisolated static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
