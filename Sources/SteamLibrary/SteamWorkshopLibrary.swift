import Foundation

/// Wallpaper Engine's Steam app ID; its Workshop items live under this ID.
public let wallpaperEngineAppID = "431960"

/// One Steam library folder's Workshop locations for an app.
public struct WorkshopLibrary: Equatable, Sendable {
    /// `<library>/steamapps/workshop`, which holds the manifest and the
    /// content and downloads folders.
    public let workshopDirectory: URL
    public let appID: String

    public init(workshopDirectory: URL, appID: String = wallpaperEngineAppID) {
        self.workshopDirectory = workshopDirectory
        self.appID = appID
    }

    /// Installed items, one folder per Workshop ID.
    public var contentDirectory: URL {
        workshopDirectory.appendingPathComponent("content/\(appID)", isDirectory: true)
    }

    /// Where Steam stages items while downloading them.
    public var downloadsDirectory: URL {
        workshopDirectory.appendingPathComponent("downloads/\(appID)", isDirectory: true)
    }

    /// `appworkshop_<appid>.acf`, Steam's record of installed items.
    public var manifestURL: URL {
        workshopDirectory.appendingPathComponent("appworkshop_\(appID).acf")
    }
}

/// Finds Steam's library folders, the Workshop content in them and the
/// signed-in account's subscriptions, by reading Steam's own files. Needs no
/// Steamworks SDK and doesn't require Steam to be running.
public struct SteamLibraryLocator: Sendable {
    public let steamRoot: URL

    public static var defaultSteamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    public init(steamRoot: URL = SteamLibraryLocator.defaultSteamRoot) {
        self.steamRoot = steamRoot
    }

    /// Every Steam library folder: Steam's own folder first, then the others
    /// listed in `libraryfolders.vdf`, without duplicates.
    public func libraryFolders() -> [URL] {
        var folders = [steamRoot.standardizedFileURL]
        let listURL = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let list = try? VDF.parse(contentsOf: listURL) {
            for (_, entry) in list["libraryfolders"]?.entries ?? [] {
                guard let path = entry["path"]?.string, !path.isEmpty else { continue }
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                if !folders.contains(url) { folders.append(url) }
            }
        }
        return folders
    }

    /// Workshop locations in every library folder, whether or not they exist yet.
    public func workshopLibraries(appID: String = wallpaperEngineAppID) -> [WorkshopLibrary] {
        libraryFolders().map {
            WorkshopLibrary(workshopDirectory: $0.appendingPathComponent("steamapps/workshop", isDirectory: true), appID: appID)
        }
    }

    /// Content folders that exist, in library order.
    public func contentDirectories(appID: String = wallpaperEngineAppID) -> [URL] {
        workshopLibraries(appID: appID).map(\.contentDirectory).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// The signed-in (most recent) account's 32-bit account ID, which names
    /// its `userdata` folder. Falls back to the only account when none is
    /// marked most recent.
    public func currentAccountID() -> UInt64? {
        let url = steamRoot.appendingPathComponent("config/loginusers.vdf")
        guard let users = (try? VDF.parse(contentsOf: url))?["users"]?.entries, !users.isEmpty else { return nil }
        let chosen = users.first { $0.value["MostRecent"]?.string == "1" } ?? (users.count == 1 ? users[0] : nil)
        guard let key = chosen?.key, let steamID = UInt64(key) else { return nil }
        return SteamID.accountID(fromSteamID64: steamID)
    }

    /// `userdata/<account>/ugc/<appid>_subscriptions.vdf` for the signed-in account.
    public func subscriptionsURL(appID: String = wallpaperEngineAppID) -> URL? {
        guard let account = currentAccountID() else { return nil }
        return steamRoot.appendingPathComponent("userdata/\(account)/ugc/\(appID)_subscriptions.vdf")
    }
}

public enum SteamID {
    /// SteamID64 of individual account 0; account IDs are offsets from it.
    static let individualBase: UInt64 = 76_561_197_960_265_728

    public static func accountID(fromSteamID64 steamID: UInt64) -> UInt64? {
        steamID > individualBase ? steamID - individualBase : nil
    }
}

/// Steam's record of installed Workshop items (`appworkshop_<appid>.acf`).
public struct WorkshopManifest: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let id: String
        public let size: UInt64
        /// Unix time of the installed revision; changes when Steam updates the item.
        public let timeUpdated: UInt64
    }

    public let items: [String: Item]

    public init(items: [String: Item]) { self.items = items }

    public init(vdf: VDF) {
        var items: [String: Item] = [:]
        for (id, entry) in vdf["AppWorkshop"]?["WorkshopItemsInstalled"]?.entries ?? [] {
            items[id] = Item(
                id: id,
                size: entry["size"]?.string.flatMap { UInt64($0) } ?? 0,
                timeUpdated: entry["timeupdated"]?.string.flatMap { UInt64($0) } ?? 0
            )
        }
        self.items = items
    }

    /// An empty manifest when the file is missing or unreadable.
    public static func load(from url: URL) -> WorkshopManifest {
        guard let vdf = try? VDF.parse(contentsOf: url) else { return WorkshopManifest(items: [:]) }
        return WorkshopManifest(vdf: vdf)
    }
}

/// The signed-in account's Workshop subscriptions for one app
/// (`userdata/<account>/ugc/<appid>_subscriptions.vdf`).
public struct WorkshopSubscriptions: Equatable, Sendable {
    /// Subscribed item IDs in file order, excluding items disabled locally.
    public let ids: [String]

    public init(ids: [String]) { self.ids = ids }

    public init(vdf: VDF) {
        ids = (vdf["subscribedfiles"]?.entries ?? []).compactMap { _, entry in
            guard let id = entry["publishedfileid"]?.string, !id.isEmpty,
                  entry["disabled_locally"]?.string != "1" else { return nil }
            return id
        }
    }

    /// Nil when the file is missing or unreadable, which is different from
    /// "subscribed to nothing".
    public static func load(from url: URL) -> WorkshopSubscriptions? {
        guard let vdf = try? VDF.parse(contentsOf: url) else { return nil }
        return WorkshopSubscriptions(vdf: vdf)
    }
}
