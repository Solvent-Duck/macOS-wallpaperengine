import CoreServices
import Foundation

/// A Workshop item folder appearing, changing or disappearing.
public struct WorkshopChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case added, updated, removed }
    public let kind: Kind
    /// The item's folder, `<content>/<workshop id>`.
    public let folder: URL
    public var id: String { folder.lastPathComponent }
}

/// Subscription counts for the signed-in account, from Steam's files.
public struct WorkshopStatus: Equatable, Sendable {
    /// Nil when the subscriptions file couldn't be read.
    public var subscribed: Int?
    public var installed: Int
    /// Subscribed items with no installed folder in any library.
    public var notDownloaded: Int?

    public init(subscribed: Int?, installed: Int, notDownloaded: Int?) {
        self.subscribed = subscribed
        self.installed = installed
        self.notDownloaded = notDownloaded
    }
}

/// What's installed across the Workshop libraries, keyed by item folder path.
public struct WorkshopSnapshot: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// The manifest's revision time; nil until Steam records the item.
        public var timeUpdated: UInt64?
        /// `project.json`'s modification time, which catches edits the manifest misses.
        public var projectModified: Date?
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// Read the libraries' content folders. A folder counts once it has a
    /// `project.json`. While Steam stages an item in `downloads/`, its previous
    /// entry is carried over unchanged, so an update in progress is neither a
    /// removal nor a half-written change.
    public static func read(_ libraries: [WorkshopLibrary], previous: WorkshopSnapshot = WorkshopSnapshot()) -> WorkshopSnapshot {
        let fm = FileManager.default
        var entries: [String: Entry] = [:]
        for library in libraries {
            let manifest = WorkshopManifest.load(from: library.manifestURL)
            let folders = (try? fm.contentsOfDirectory(
                at: library.contentDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            var staged = Set((try? fm.contentsOfDirectory(atPath: library.downloadsDirectory.path)) ?? [])
            for folder in folders {
                let id = folder.lastPathComponent
                let key = folder.standardizedFileURL.path
                if staged.remove(id) != nil {
                    if let old = previous.entries[key] { entries[key] = old }
                    continue
                }
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let project = folder.appendingPathComponent("project.json")
                guard let attributes = try? fm.attributesOfItem(atPath: project.path) else { continue }
                entries[key] = Entry(
                    timeUpdated: manifest.items[id]?.timeUpdated,
                    projectModified: attributes[.modificationDate] as? Date
                )
            }
        }
        return WorkshopSnapshot(entries: entries)
    }

    /// Changes from `old` to `self`, sorted by folder path.
    public func changes(since old: WorkshopSnapshot) -> [WorkshopChange] {
        var changes: [WorkshopChange] = []
        for (path, entry) in entries {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            if let previous = old.entries[path] {
                if previous != entry { changes.append(WorkshopChange(kind: .updated, folder: folder)) }
            } else {
                changes.append(WorkshopChange(kind: .added, folder: folder))
            }
        }
        for path in old.entries.keys where entries[path] == nil {
            changes.append(WorkshopChange(kind: .removed, folder: URL(fileURLWithPath: path, isDirectory: true)))
        }
        return changes.sorted { $0.folder.path < $1.folder.path }
    }

    /// Installed item IDs across all libraries.
    public var installedIDs: Set<String> {
        Set(entries.keys.map { URL(fileURLWithPath: $0).lastPathComponent })
    }
}

/// Watches Steam's Workshop folders with FSEvents and reports item folders
/// that were added, updated or removed, plus subscription counts. Events are
/// coalesced, so a download that touches thousands of files reports once.
public final class WorkshopFolderWatcher: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable ([WorkshopChange], WorkshopStatus) -> Void

    private let locator: SteamLibraryLocator
    private let appID: String
    private let settleDelay: TimeInterval
    private let queue = DispatchQueue(label: "WorkshopFolderWatcher")
    // Everything below is touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var snapshot = WorkshopSnapshot()
    private var lastStatus: WorkshopStatus?
    private var pendingRescan: DispatchWorkItem?
    private var handler: Handler?

    public init(locator: SteamLibraryLocator = SteamLibraryLocator(), appID: String = wallpaperEngineAppID, settleDelay: TimeInterval = 2) {
        self.locator = locator
        self.appID = appID
        self.settleDelay = settleDelay
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Take the initial snapshot (reported only as status, not as changes)
    /// and start watching. `handler` runs on the main actor.
    public func start(_ handler: @escaping Handler) {
        queue.async { [self] in
            guard stream == nil else { return }
            self.handler = handler
            snapshot = WorkshopSnapshot.read(locator.workshopLibraries(appID: appID))
            deliver([], status: status())
            startStream()
        }
    }

    public func stop() {
        queue.sync {
            pendingRescan?.cancel()
            pendingRescan = nil
            handler = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Rescan now, e.g. after the library folders changed.
    public func rescan() {
        queue.async { [self] in rescanNow() }
    }

    private func status() -> WorkshopStatus {
        let installed = snapshot.installedIDs
        let subscriptions = locator.subscriptionsURL(appID: appID).flatMap(WorkshopSubscriptions.load(from:))
        return WorkshopStatus(
            subscribed: subscriptions?.ids.count,
            installed: installed.count,
            notDownloaded: subscriptions.map { $0.ids.filter { !installed.contains($0) }.count }
        )
    }

    private func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescanNow() }
        pendingRescan = work
        queue.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    private func rescanNow() {
        pendingRescan = nil
        let next = WorkshopSnapshot.read(locator.workshopLibraries(appID: appID), previous: snapshot)
        let changes = next.changes(since: snapshot)
        snapshot = next
        let status = status()
        guard !changes.isEmpty || status != lastStatus else { return }
        deliver(changes, status: status)
    }

    private func deliver(_ changes: [WorkshopChange], status: WorkshopStatus) {
        lastStatus = status
        guard let handler else { return }
        Task { @MainActor in handler(changes, status) }
    }

    /// Watch each library's `steamapps` folder (so a Workshop folder created
    /// later is still seen) and the account's `ugc` folder for subscriptions.
    private func startStream() {
        var paths = locator.libraryFolders().map { $0.appendingPathComponent("steamapps").path }
        if let subscriptions = locator.subscriptionsURL(appID: appID) {
            paths.append(subscriptions.deletingLastPathComponent().path)
        }
        paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkshopFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if paths.prefix(count).contains(where: watcher.isRelevant) { watcher.scheduleRescan() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Only Workshop and subscription changes matter; game installs elsewhere
    /// under `steamapps` are ignored.
    private func isRelevant(_ path: String) -> Bool {
        path.contains("/workshop/") || path.hasSuffix("/workshop") || path.contains("/ugc")
    }
}
