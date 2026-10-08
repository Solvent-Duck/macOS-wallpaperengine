import AppKit
import SteamLibrary
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Wallpaper Engine Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        AppActivation.windowDidOpen()
        model.beginLiveUpdates()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.endLiveUpdates()
        AppActivation.windowDidClose()
    }
}

struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general = "General"
        case audioMedia = "Audio & Media"
        case workshop = "Steam Workshop"
        case advanced = "Advanced"
    }

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.settingsPane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)

            switch model.settingsPane {
            case .general: GeneralSettings(model: model)
            case .audioMedia: AudioMediaSettings(model: model)
            case .workshop: WorkshopSettings(model: model, sync: model.workshopSync)
            case .advanced: AdvancedSettings(model: model)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Restore last wallpaper when the app starts", isOn: $model.restoresOnLaunch)
                Toggle(isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItemEnabled($0) })) {
                    Text("Open at login")
                    Text("Starts \(abbreviated(model.loginItemExecutablePath)). Rebuild in place to keep it working.")
                }
            }
            Section {
                LabeledContent("Multiple displays") {
                    Text("Not supported yet")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("With more than one display connected, the same wallpaper is shown on every display. Choosing a wallpaper per display isn’t available.")
            }
            Section {
                LabeledContent(model.usesCustomLibraryFolder ? "Folder" : "Folders") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if model.libraryFolders.isEmpty {
                            Text("None found").foregroundStyle(.secondary)
                        }
                        ForEach(model.libraryFolders, id: \.self) { url in
                            Text(abbreviated(url.path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(url.path)
                        }
                    }
                }
                HStack {
                    Spacer()
                    if model.usesCustomLibraryFolder {
                        Button("Use Default Folders") { model.useDefaultLibraryFolders() }
                    }
                    Button("Choose Folder…") { model.chooseLibraryFolder() }
                }
            } header: {
                Text("Wallpaper Library")
            }
        }
        .formStyle(.grouped)
    }
}

private struct WorkshopSettings: View {
    let model: AppModel
    let sync: WorkshopSync

    var body: some View {
        Form {
            Section {
                LabeledContent("Subscriptions") {
                    if let subscribed = model.workshopStatus?.subscribed {
                        Text(workshopSummary(subscribed: subscribed, notDownloaded: model.workshopItemsToDownload.count))
                    } else {
                        Text("Steam not found").foregroundStyle(.secondary)
                    }
                }
                Toggle("Download subscriptions automatically", isOn: Binding(
                    get: { model.workshopSyncEnabled },
                    set: { model.setWorkshopSyncEnabled($0) }
                ))
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if sync.isRunning { ProgressView().controlSize(.small) }
                        Text(workshopSyncStatus(sync, enabled: model.workshopSyncEnabled))
                            .foregroundStyle(isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .multilineTextAlignment(.trailing)
                    }
                }
                HStack {
                    Spacer()
                    if !sync.unavailableIDs.isEmpty {
                        Button("Retry Unavailable (\(sync.unavailableIDs.count))") { sync.retryUnavailable() }
                            .help("Items Steam refused, usually because they were removed or made private")
                    }
                    Button("Sync Now") { model.syncWorkshopNow() }
                        .disabled(!model.workshopSyncEnabled || sync.isRunning)
                }
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("Syncing starts a short Steam session as Wallpaper Engine, so Steam shows you as playing it until downloads finish.")
            }

            Section {
                Picker("Show in Browse", selection: Binding(
                    get: { model.workshopRatingLevel },
                    set: { model.workshopRatingLevel = $0 }
                )) {
                    Text("Everyone").tag(0)
                    Text("Everyone and Questionable").tag(1)
                    Text("Everything, including Mature").tag(2)
                }
            } header: {
                Text("Browsing")
            } footer: {
                Text("Uses the content rating authors give their wallpapers on the Workshop.")
            }

            Section {
                LabeledContent("Folder") {
                    Text(abbreviated(model.steamworksSDKFolder.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.steamworksSDKFolder.path)
                }
                HStack {
                    Spacer()
                    Button("Choose Folder…") { model.chooseSteamworksSDKFolder() }
                }
            } header: {
                Text("Steamworks SDK")
            } footer: {
                Text("Syncing uses Valve’s Steamworks SDK, which can’t be included with this app. Download it from partner.steamgames.com and choose the folder you unzipped it to.")
            }
        }
        .formStyle(.grouped)
    }

    private var isProblem: Bool {
        if case .problem = sync.phase { return true }
        return false
    }
}

private struct AudioMediaSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Listen to", selection: Binding(
                    get: { model.snapshot.audioSelection },
                    set: { model.selectAudioResponse($0) }
                )) {
                    ForEach(AudioResponseSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(model.snapshot.audioStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Audio Response")
            } footer: {
                Text("Audio-reactive wallpapers animate to this source. It is separate from muting the wallpaper’s own sound.")
            }
            Section {
                Picker("Source", selection: Binding(
                    get: { model.snapshot.mediaSelection },
                    set: { model.selectMediaSource($0) }
                )) {
                    ForEach(MediaSourceSelection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(model.snapshot.mediaStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    ForEach(MediaPlayer.allCases, id: \.self) { player in
                        Button("Connect \(player.name)…") { model.connect(player) }
                    }
                }
            } header: {
                Text("Now Playing")
            } footer: {
                Text("Wallpapers that show the current song read it from Music or Spotify.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Diagnostics") {
                    Button("Copy to Clipboard") { model.copyDiagnostics() }
                }
            } footer: {
                Text("Frame rate, renderer state and recent events, for bug reports.")
            }
        }
        .formStyle(.grouped)
    }
}

private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

func workshopSummary(subscribed: Int, notDownloaded: Int) -> String {
    let items = subscribed == 1 ? "1 subscription" : "\(subscribed) subscriptions"
    return notDownloaded == 0 ? items : "\(items), \(notDownloaded) not downloaded"
}

@MainActor
func workshopSyncStatus(_ sync: WorkshopSync, enabled: Bool) -> String {
    switch sync.phase {
    case .problem(let problem):
        return workshopProblemMessage(problem)
    case .syncing:
        let active = sync.activeDownloads
        guard !active.isEmpty else { return "Connected to Steam" }
        let done = active.reduce(UInt64(0)) { total, item in
            if case .downloading(let downloaded, _) = item.status { return total + downloaded }
            return total
        }
        let size = active.reduce(UInt64(0)) { total, item in
            if case .downloading(_, let bytes) = item.status { return total + bytes }
            return total + (item.size ?? 0)
        }
        let items = active.count == 1 ? "1 item" : "\(active.count) items"
        guard size > 0 else { return "Downloading \(items)…" }
        let format = ByteCountFormatter()
        return "Downloading \(items) · \(format.string(fromByteCount: Int64(done))) of \(format.string(fromByteCount: Int64(size)))"
    case .idle:
        guard enabled else { return "Off" }
        guard let last = sync.lastSync else { return "Not synced yet" }
        return "Up to date · synced \(last.formatted(.relative(presentation: .named)))"
    }
}
