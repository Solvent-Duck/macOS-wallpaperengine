import AppKit
import SwiftUI

/// Details, Apply and properties for the selected library wallpaper.
///
/// The library lists metadata-only projects; the full project (with native
/// scene properties) is loaded here when a wallpaper is selected. Properties of
/// the active wallpaper apply live; for any other wallpaper they are saved and
/// take effect when it is applied.
struct LibraryInspector: View {
    let wallpaper: WallpaperProject
    @ObservedObject var library: GalleryViewModel
    let appModel: AppModel
    @State private var fullProject: WallpaperProject?

    private var isActive: Bool {
        wallpaper.libraryPath != nil && wallpaper.libraryPath == appModel.snapshot.directoryPath
    }

    private var isLoading: Bool {
        appModel.loadingName != nil && appModel.loadingName == wallpaper.directoryURL?.lastPathComponent
    }

    var body: some View {
        Form {
            Section { header }
            if let fullProject {
                InspectorPlayback(project: fullProject, isActive: isActive, appModel: appModel)
                    .id("playback|\(wallpaper.libraryPath ?? "")|\(isActive)")
                InspectorProperties(project: fullProject, isActive: isActive, appModel: appModel)
                    .id("\(wallpaper.libraryPath ?? "")|\(isActive)")
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: wallpaper.libraryPath) {
            fullProject = nil
            if isActive, let current = appModel.windowManager.currentProject {
                fullProject = current
                return
            }
            guard let url = wallpaper.directoryURL else { fullProject = wallpaper; return }
            let loaded = await Task.detached(priority: .userInitiated) {
                try? WallpaperLoader.load(from: url)
            }.value
            guard !Task.isCancelled else { return }
            fullProject = loaded ?? wallpaper
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PreviewThumbnail(url: wallpaper.previewURL) }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(wallpaper.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Label(wallpaper.type.rawValue.capitalized, systemImage: wallpaper.type.symbolName)
                    if let id = workshopID {
                        Text("·")
                        Link("Workshop \(id)", destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    guard let url = wallpaper.directoryURL else { return }
                    Task { await appModel.load(url) }
                } label: {
                    HStack(spacing: 6) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(isActive ? "Applied" : (isLoading ? "Applying…" : "Apply"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isActive || isLoading)

                Button {
                    library.toggleFavorite(wallpaper)
                } label: {
                    Image(systemName: library.isFavorite(wallpaper) ? "heart.fill" : "heart")
                        .foregroundStyle(library.isFavorite(wallpaper) ? Color.pink : Color.primary)
                }
                .controlSize(.large)
                .help(library.isFavorite(wallpaper) ? "Remove from Favorites" : "Add to Favorites")

                if let url = wallpaper.directoryURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .controlSize(.large)
                    .help("Show in Finder")
                }
            }

            if let tags = wallpaper.tags, !tags.isEmpty {
                Text(tags.map(\.capitalized).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let description = wallpaper.description.flatMap(PropertyLayout.labelText) {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var workshopID: String? {
        guard let name = wallpaper.directoryURL?.lastPathComponent,
              !name.isEmpty, name.allSatisfy(\.isNumber) else { return nil }
        return name
    }
}

private struct InspectorProperties: View {
    @StateObject private var store: PropertyStore

    init(project: WallpaperProject, isActive: Bool, appModel: AppModel) {
        _store = StateObject(wrappedValue: appModel.makePropertyStore(for: project, isActive: isActive))
    }

    var body: some View {
        if store.properties.isEmpty {
            Section {
                Text("This wallpaper has no settings.")
                    .foregroundStyle(.secondary)
            }
        } else {
            PropertySections(store: store)
            Section {
                HStack {
                    Spacer()
                    Button("Reset All") { store.resetToDefaults() }
                        .disabled(!store.hasEditableProperties && store.onReset == nil)
                }
            }
        }
    }
}

/// Volume, speed and scaling: Wallpaper Engine's per-wallpaper playback settings.
private struct InspectorPlayback: View {
    let project: WallpaperProject
    let isActive: Bool
    let appModel: AppModel
    @State private var settings: PlaybackSettings

    init(project: WallpaperProject, isActive: Bool, appModel: AppModel) {
        self.project = project
        self.isActive = isActive
        self.appModel = appModel
        _settings = State(initialValue: appModel.playbackSettings(for: project, isActive: isActive))
    }

    private var capabilities: PlaybackSettings.Capabilities {
        PlaybackSettings.Capabilities(type: project.resolvedType)
    }

    var body: some View {
        if !capabilities.isEmpty {
            Section("Playback") {
                if capabilities.volume {
                    LabeledContent("Volume") {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $settings.volume, in: 0...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 240)
                    }
                }
                if capabilities.rate {
                    Picker("Speed", selection: $settings.rate) {
                        ForEach(PlaybackSettings.rates, id: \.self) { rate in
                            Text(rate == 1 ? "Normal" : String(format: "%g×", rate)).tag(rate)
                        }
                    }
                }
                if capabilities.scaling {
                    Picker("Scaling", selection: $settings.scaling) {
                        ForEach(VideoScaling.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .onChange(of: settings) { _, newValue in
                appModel.setPlayback(newValue, for: project, isActive: isActive)
            }
        }
    }
}
