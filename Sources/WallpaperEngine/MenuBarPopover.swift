import AppKit
import SwiftUI

/// The menu bar item: a popover with the current wallpaper, playback controls
/// and recent wallpapers. Replaces the old flat status menu.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Wallpaper Engine")
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(model: model, dismiss: { [weak self] in self?.popover.performClose(nil) })
        )
    }

    func remove() {
        popover.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        model.beginLiveUpdates()
    }

    func popoverDidClose(_ notification: Notification) {
        model.endLiveUpdates()
    }
}

struct MenuBarPopover: View {
    let model: AppModel
    let dismiss: () -> Void

    private var snapshot: AppModel.Snapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowPlaying
            if model.hasWallpaper {
                controls
                if snapshot.supportsAudio { volume }
            }
            if !model.recents.isEmpty { recents }
            library
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            ZStack {
                if model.hasWallpaper {
                    PreviewThumbnail(url: snapshot.previewURL)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title ?? "No wallpaper")
                    .font(.headline)
                    .lineLimit(2)
                statusLine
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let loading = model.loadingName {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading \(loading)…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if !model.hasWallpaper {
            Text("Choose one below to get started")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let reason = snapshot.pauseReason {
            Label(reason, systemImage: "pause.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label(snapshot.fps > 0 ? String(format: "Playing · %.0f fps", snapshot.fps) : "Playing",
                  systemImage: "play.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                model.togglePause()
            } label: {
                Label(snapshot.isManuallyPaused ? "Resume" : "Pause",
                      systemImage: snapshot.isManuallyPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            Button {
                model.toggleMute()
            } label: {
                Label(snapshot.isMuted ? "Unmute" : "Mute",
                      systemImage: snapshot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!snapshot.supportsAudio)
            Button {
                dismiss()
                model.customizeCurrentWallpaper()
            } label: {
                Label("Customize", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .labelStyle(VerticalLabelStyle())
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.isMuted ? "speaker.slash.fill" : "speaker.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(
                get: { snapshot.playback.volume },
                set: { volume in
                    var playback = snapshot.playback
                    playback.volume = volume
                    model.setPlayback(playback)
                }
            ), in: 0...1)
            .controlSize(.small)
            .disabled(snapshot.isMuted)
            .help(snapshot.isMuted ? "Unmute to change the volume" : "Wallpaper volume")
            .accessibilityLabel("Volume")
        }
    }

    // MARK: Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(model.recents.prefix(8)) { recent in
                    RecentTile(
                        recent: recent,
                        isCurrent: recent.path == snapshot.directoryPath
                    ) {
                        Task { await model.load(recent.url) }
                    }
                }
            }
        }
    }

    // MARK: Library

    private var library: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                model.openLibrary()
            } label: {
                Label("Browse Wallpapers…", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                dismiss()
                model.chooseWallpaperFile()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open a wallpaper file or folder…")
            .accessibilityLabel("Open Wallpaper File or Folder")
        }
        .controlSize(.large)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.hasWallpaper {
                Button("Clear Wallpaper") { model.clearWallpaper() }
            }
            Spacer()
            Button {
                dismiss()
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            .accessibilityLabel("Settings")
            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Wallpaper Engine")
            .accessibilityLabel("Quit Wallpaper Engine")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

private struct RecentTile: View {
    let recent: RecentWallpaper
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PreviewThumbnail(url: recent.previewURL) }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isCurrent ? Color.accentColor : (isHovered ? Color.secondary : .clear), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(recent.title)
        .accessibilityLabel(recent.title)
    }
}

private struct VerticalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon
            configuration.title.font(.caption)
        }
        .padding(.vertical, 2)
    }
}
