import AppKit
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
        case advanced = "Advanced"
    }

    let model: AppModel
    @State var pane: Pane = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)

            switch pane {
            case .general: GeneralSettings(model: model)
            case .audioMedia: AudioMediaSettings(model: model)
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
            Section("Wallpaper Library") {
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
            }
        }
        .formStyle(.grouped)
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
