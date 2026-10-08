import AppKit
import SteamLibrary
import SwiftUI

/// Opening Workshop pages: in the Steam client when it's running (signed
/// in, with Subscribe and comments), otherwise in the browser.
@MainActor
enum WorkshopLinks {
    static func pageURL(for id: String, steamRunning: Bool = isSteamRunning) -> URL {
        steamRunning
            ? URL(string: "steam://url/CommunityFilePage/\(id)")!
            : URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
    }

    static var isSteamRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty
    }

    static func openPage(for id: String) {
        NSWorkspace.shared.open(pageURL(for: id))
    }
}

extension WallpaperProject {
    /// The Workshop ID when this is Steam's own copy (inside a Workshop
    /// content folder), which unsubscribing would remove.
    var steamWorkshopID: String? {
        guard let folder = directoryURL, folder.lastPathComponent.allSatisfy(\.isNumber), !folder.lastPathComponent.isEmpty,
              folder.deletingLastPathComponent().path.hasSuffix("/workshop/content/\(wallpaperEngineAppID)") else { return nil }
        return folder.lastPathComponent
    }
}

/// Ask before unsubscribing, since Steam deletes the files.
@MainActor
func confirmUnsubscribe(title: String, isActive: Bool) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Unsubscribe from “\(title)”?"
    alert.informativeText = isActive
        ? "Steam removes its files, and the desktop wallpaper is cleared."
        : "Steam removes its files from this Mac."
    alert.addButton(withTitle: "Unsubscribe")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}

/// Vote and Workshop-favorite buttons for an item. The account's current
/// vote and favorites load only when a Steam session is already open;
/// pressing a button opens one.
struct WorkshopFeedbackControls: View {
    let id: String
    let sync: WorkshopSync

    private var vote: WorkshopVote? { sync.votes[id] }
    private var isFavorite: Bool { sync.favoriteIDs?.contains(id) ?? false }
    private var isPending: Bool { sync.pendingFeedback.contains(id) }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                sync.vote(id, up: true)
            } label: {
                Label("Vote Up", systemImage: vote == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .help(vote == .up ? "You voted this up" : "Vote up on the Workshop")
            Button {
                sync.vote(id, up: false)
            } label: {
                Label("Vote Down", systemImage: vote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .help(vote == .down ? "You voted this down" : "Vote down on the Workshop")
            Button {
                sync.setFavorite(id, !isFavorite)
            } label: {
                Label(isFavorite ? "Remove from Workshop Favorites" : "Add to Workshop Favorites",
                      systemImage: isFavorite ? "star.fill" : "star")
            }
            .help(isFavorite ? "Remove from your Steam Workshop favorites" : "Add to your Steam Workshop favorites")
            .disabled(sync.favoriteIDs == nil && sync.isRunning)
            if isPending { ProgressView().controlSize(.small) }
            Spacer()
            Button("Workshop Page") { WorkshopLinks.openPage(for: id) }
                .help(WorkshopLinks.isSteamRunning ? "Open in Steam" : "Open in your browser")
        }
        .labelStyle(.iconOnly)
        .disabled(isPending)
        .onAppear { sync.loadFeedback(for: id) }
        .onChange(of: sync.isRunning) { _, running in
            if running { sync.loadFeedback(for: id) }
        }
    }
}
