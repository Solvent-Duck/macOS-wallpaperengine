import Foundation
import SteamLibrary

/// Where Workshop sync finds its helper and the user's Steamworks SDK, and
/// whether it is on. The SDK can't be bundled, so it is loaded from the
/// folder the user downloaded it to.
@MainActor
enum WorkshopSyncSettings {
    private static let enabledKey = "workshopSyncEnabled"
    private static let sdkFolderKey = "steamworksSDKFolder"
    private static let ratingLevelKey = "workshopRatingLevel"

    /// 0 = Everyone, 1 = adds Questionable, 2 = adds Mature.
    static var ratingLevel: Int {
        get { min(max(UserDefaults.standard.integer(forKey: ratingLevelKey), 0), WorkshopCatalog.ratings.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: ratingLevelKey) }
    }

    static var allowedRatings: [String] { Array(WorkshopCatalog.ratings.prefix(ratingLevel + 1)) }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var sdkFolder: URL {
        get {
            UserDefaults.standard.string(forKey: sdkFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sdk", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: sdkFolderKey) }
    }

    static var steamAPILibrary: URL {
        sdkFolder.appendingPathComponent("redistributable_bin/osx/libsteam_api.dylib")
    }

    /// Built next to the app's executable when the SDK was present at build time.
    static var helperExecutable: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SteamWorkshopHelper")
    }

    static func launchHelper(
        onEvent: @escaping @MainActor (WorkshopHelperEvent) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> WorkshopHelperConnection {
        guard let helper = helperExecutable, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw WorkshopSync.Problem.helperMissing
        }
        let library = steamAPILibrary
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw WorkshopSync.Problem.sdkMissing(path: library.path)
        }
        return try WorkshopHelperProcess(helper: helper, steamAPI: library, onEvent: onEvent, onExit: onExit)
    }
}
