import Foundation
import Observation

/// Keeps the signed-in account's Workshop subscriptions downloaded, through a
/// short-lived `SteamWorkshopHelper` session: start it, ask Steam for every
/// subscription that is missing, stale or out of date, follow the downloads,
/// then end the session once nothing is left so Steam stops showing the user
/// as playing Wallpaper Engine.
@MainActor
@Observable
public final class WorkshopSync {
    public enum Problem: Error, Equatable, Sendable {
        /// This build has no helper (built without the Steamworks SDK).
        case helperMissing
        /// `libsteam_api.dylib` isn't at the expected path.
        case sdkMissing(path: String)
        case steamNotRunning
        case notOwned
        case failed(String)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case syncing
        case problem(Problem)
    }

    public enum DownloadStatus: Equatable, Sendable {
        case queued
        case downloading(downloaded: UInt64, total: UInt64)
        /// Removed, private or otherwise refused by Steam; not retried
        /// automatically.
        case unavailable
    }

    public struct Download: Identifiable, Equatable, Sendable {
        public let id: String
        public var title: String?
        public var previewURL: URL?
        public var size: UInt64?
        public var status: DownloadStatus
    }

    public typealias Launcher = @MainActor (
        _ onEvent: @escaping @MainActor (WorkshopHelperEvent) -> Void,
        _ onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> WorkshopHelperConnection

    public private(set) var phase: Phase = .idle
    /// Items being fetched, in the order they were requested, followed by
    /// unavailable ones.
    public private(set) var downloads: [Download] = []
    public private(set) var lastSync: Date?
    public private(set) var unavailableIDs: Set<String>

    /// The signed-in account's subscriptions, as of the session's last report.
    public private(set) var subscribedIDs: Set<String> = []
    /// Subscribe or unsubscribe requests Steam hasn't answered yet.
    public private(set) var pendingSubscriptionChanges: Set<String> = []
    /// Shown when Steam refuses a subscribe or unsubscribe.
    public private(set) var lastSubscriptionError: String?
    public private(set) var browse = BrowseState()
    /// When false, sessions only download what the user asks for here
    /// (e.g. subscribing in the browser), not every missing subscription.
    public var downloadsSubscriptions = true

    public var activeDownloads: [Download] { downloads.filter { $0.status != .unavailable } }
    public var isRunning: Bool { connection != nil }

    @ObservationIgnored private let launcher: Launcher
    @ObservationIgnored private let folderExists: (String) -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let idleTimeout: Duration
    @ObservationIgnored private var connection: WorkshopHelperConnection?
    @ObservationIgnored private var receivedSubscriptions = false
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var browsingClients = 0
    @ObservationIgnored private var browseRequest = 0

    static let unavailableKey = "WorkshopUnavailableItems"
    /// Steam answers at most this many items per details query.
    static let detailsBatch = 50

    public init(launcher: @escaping Launcher,
                folderExists: @escaping (String) -> Bool = { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                },
                defaults: UserDefaults = .standard,
                idleTimeout: Duration = .seconds(20)) {
        self.launcher = launcher
        self.folderExists = folderExists
        self.defaults = defaults
        self.idleTimeout = idleTimeout
        unavailableIDs = Set(defaults.stringArray(forKey: Self.unavailableKey) ?? [])
    }

    /// Start a sync, or ask a running session to check again.
    public func sync() {
        if let connection {
            connection.send("refresh")
            return
        }
        receivedSubscriptions = false
        quitting = false
        do {
            connection = try launcher(
                { [weak self] event in self?.handle(event) },
                { [weak self] status in self?.helperExited(status: status) }
            )
            phase = .syncing
        } catch let problem as Problem {
            phase = .problem(problem)
        } catch {
            phase = .problem(.failed(error.localizedDescription))
        }
    }

    /// Ask Steam for these items now, starting a session if needed.
    public func download(_ ids: [String]) {
        let wanted = ids.filter { !unavailableIDs.contains($0) }
        guard !wanted.isEmpty else { return }
        enqueue(wanted)
        if connection == nil {
            sync()
        } else {
            request(wanted)
        }
    }

    // MARK: - Browsing and subscriptions

    /// Keep the session open while a browser is on screen.
    public func beginBrowsing() {
        browsingClients += 1
        idleTask?.cancel()
    }

    public func endBrowsing() {
        browsingClients = max(0, browsingClients - 1)
        scheduleIdleQuit()
    }

    /// Run a new catalogue query, replacing the current results.
    public func search(_ query: WorkshopQuery) {
        browse = BrowseState(query: query, isLoading: true)
        requestPage(1)
    }

    public func loadMore() {
        guard !browse.isLoading, browse.items.count < browse.total else { return }
        browse.isLoading = true
        requestPage(browse.nextPage)
    }

    private func requestPage(_ page: Int) {
        browseRequest += 1
        browse.error = nil
        ensureSession()
        connection?.send(browse.query.command(request: browseRequest, page: page))
    }

    public func subscribe(_ id: String) {
        changeSubscription(id, verb: "subscribe")
    }

    public func unsubscribe(_ id: String) {
        changeSubscription(id, verb: "unsubscribe")
    }

    private func changeSubscription(_ id: String, verb: String) {
        lastSubscriptionError = nil
        pendingSubscriptionChanges.insert(id)
        ensureSession()
        connection?.send("\(verb) \(id)")
    }

    private func ensureSession() {
        idleTask?.cancel()
        if connection == nil { sync() }
    }

    /// End the session now, e.g. when syncing is turned off.
    public func stop() {
        idleTask?.cancel()
        guard let connection else { return }
        quitting = true
        connection.quit()
    }

    /// Forget which items were unavailable so the next sync tries them again.
    public func retryUnavailable() {
        unavailableIDs.removeAll()
        defaults.removeObject(forKey: Self.unavailableKey)
        downloads.removeAll { $0.status == .unavailable }
    }

    // MARK: - Events

    func handle(_ event: WorkshopHelperEvent) {
        switch event {
        case .ready:
            phase = .syncing
        case .error(let code, let message):
            switch code {
            case "steamNotRunning": phase = .problem(.steamNotRunning)
            case "notOwned": phase = .problem(.notOwned)
            case "sdkMissing": phase = .problem(.sdkMissing(path: message))
            default: phase = .problem(.failed(message))
            }
        case .subscriptions(let settled, let items):
            receivedSubscriptions = true
            if settled || !items.isEmpty { subscribedIDs = Set(items.map(\.id)) }
            guard downloadsSubscriptions else { break }
            let needed = items.filter(needsDownload).map(\.id)
            // Steam has these after all (e.g. the author restored them).
            let present = Set(items.filter { !needsDownload($0) }.map(\.id))
            for id in unavailableIDs.intersection(present) { markAvailable(id) }
            let wanted = needed.filter { !unavailableIDs.contains($0) }
            for id in needed where unavailableIDs.contains(id) { upsert(id) { $0.status = .unavailable } }
            enqueue(wanted)
            request(wanted)
        case .progress(let id, let state, let downloaded, let total):
            let flags = WorkshopItemState(rawValue: state)
            if flags.contains(.installed), flags.isDisjoint(with: [.needsUpdate, .downloading, .downloadPending]) {
                finish(id)
            } else if total > 0 {
                update(id) { $0.status = .downloading(downloaded: downloaded, total: total) }
            }
        case .downloadStarted(let id, let ok):
            if !ok { finish(id) }
        case .downloadResult(let id, let result):
            if SteamResult.isPermanentFailure(result) {
                markUnavailable(id)
            } else {
                finish(id)
            }
        case .installed(let item):
            finish(item.id)
        case .subscribed(let id):
            subscribedIDs.insert(id)
            if downloadsSubscriptions, !unavailableIDs.contains(id) {
                enqueue([id])
                request([id])
            }
        case .unsubscribed(let id):
            subscribedIDs.remove(id)
            downloads.removeAll { $0.id == id }
        case .details(let items):
            for item in items {
                update(item.id) {
                    if !item.title.isEmpty { $0.title = item.title }
                    if !item.preview.isEmpty { $0.previewURL = URL(string: item.preview) }
                    if item.fileSize > 0 { $0.size = item.fileSize }
                }
                if SteamResult.isPermanentFailure(item.result) { markUnavailable(item.id) }
            }
        case .subscribeResult(let id, let result):
            pendingSubscriptionChanges.remove(id)
            if result == SteamResult.ok {
                subscribedIDs.insert(id)
                // Asked for explicitly, so fetch it even when automatic sync is off.
                if !unavailableIDs.contains(id) {
                    enqueue([id])
                    request([id])
                }
            } else {
                lastSubscriptionError = "Steam couldn’t subscribe to this item (error \(result))."
            }
        case .unsubscribeResult(let id, let result):
            pendingSubscriptionChanges.remove(id)
            if result == SteamResult.ok {
                subscribedIDs.remove(id)
                downloads.removeAll { $0.id == id }
            } else {
                lastSubscriptionError = "Steam couldn’t unsubscribe from this item (error \(result))."
            }
        case .browseResults(let request, let result, let total, let items):
            guard request == browseRequest else { break }
            browse.isLoading = false
            if result == SteamResult.ok {
                let known = Set(browse.items.map(\.id))
                browse.items += items.filter { !known.contains($0.id) }
                browse.total = total
                browse.nextPage += 1
                for item in items where WorkshopItemState(rawValue: item.state).contains(.subscribed) {
                    subscribedIDs.insert(item.id)
                }
            } else {
                browse.error = "Steam couldn’t load the Workshop (error \(result))."
            }
        }
        scheduleIdleQuit()
    }

    private func needsDownload(_ item: WorkshopHelperEvent.Item) -> Bool {
        item.flags.contains(.needsUpdate) || item.folder.isEmpty || !folderExists(item.folder)
    }

    private func enqueue(_ ids: [String]) {
        for id in ids where !downloads.contains(where: { $0.id == id && $0.status != .unavailable }) {
            downloads.removeAll { $0.id == id }
            let firstUnavailable = downloads.firstIndex { $0.status == .unavailable } ?? downloads.endIndex
            downloads.insert(Download(id: id, status: .queued), at: firstUnavailable)
        }
    }

    private func request(_ ids: [String]) {
        guard let connection, !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: Self.detailsBatch) {
            let batch = ids[start..<min(start + Self.detailsBatch, ids.count)]
            connection.send("details " + batch.joined(separator: " "))
        }
        connection.send("download " + ids.joined(separator: " "))
    }

    private func update(_ id: String, _ change: (inout Download) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[index])
    }

    private func upsert(_ id: String, _ change: (inout Download) -> Void) {
        if !downloads.contains(where: { $0.id == id }) { downloads.append(Download(id: id, status: .queued)) }
        update(id, change)
    }

    private func finish(_ id: String) {
        downloads.removeAll { $0.id == id && $0.status != .unavailable }
    }

    private func markUnavailable(_ id: String) {
        unavailableIDs.insert(id)
        defaults.set(unavailableIDs.sorted(), forKey: Self.unavailableKey)
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            var item = downloads.remove(at: index)
            item.status = .unavailable
            downloads.append(item)
        } else {
            downloads.append(Download(id: id, status: .unavailable))
        }
    }

    private func markAvailable(_ id: String) {
        unavailableIDs.remove(id)
        defaults.set(unavailableIDs.sorted(), forKey: Self.unavailableKey)
        downloads.removeAll { $0.id == id && $0.status == .unavailable }
    }

    /// End the session once the subscription list arrived and nothing is
    /// left to download, after a grace period for late callbacks.
    private func scheduleIdleQuit() {
        idleTask?.cancel()
        guard connection != nil, receivedSubscriptions, activeDownloads.isEmpty, !quitting,
              browsingClients == 0, pendingSubscriptionChanges.isEmpty, !browse.isLoading else { return }
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.activeDownloads.isEmpty, self.browsingClients == 0 else { return }
            self.stop()
        }
    }

    func helperExited(status: Int32) {
        idleTask?.cancel()
        connection = nil
        // Whatever was still in flight is picked up again by the next sync.
        downloads.removeAll { $0.status != .unavailable }
        pendingSubscriptionChanges.removeAll()
        browse.isLoading = false
        if case .problem = phase { return }
        if quitting && status == 0 {
            phase = .idle
            lastSync = Date()
        } else {
            phase = .problem(.failed("The Steam Workshop helper stopped unexpectedly (status \(status))."))
        }
    }
}

/// A Workshop catalogue query.
public struct WorkshopQuery: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        case trend, popular, recent, subscribed
    }

    public var sort: Sort = .trend
    /// Trend window in days, for `.trend`.
    public var trendDays = 7
    public var text = ""
    /// One of `WorkshopCatalog.types`, or nil for every type this app plays.
    public var type: String?
    public var tag: String?
    /// Allowed content ratings; an item needs one of them.
    public var ratings = ["Everyone"]

    public init(sort: Sort = .trend, text: String = "", type: String? = nil, tag: String? = nil, ratings: [String] = ["Everyone"]) {
        self.sort = sort
        self.text = text
        self.type = type
        self.tag = tag
        self.ratings = ratings
    }

    /// The helper's `browse` command line; values are percent-encoded so
    /// they can't break the space-separated format.
    func command(request: Int, page: Int) -> String {
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        var parts = ["browse", "request=\(request)", "sort=\(sort.rawValue)", "page=\(page)", "days=\(trendDays)",
                     "types=" + encoded((type.map { [$0] } ?? WorkshopCatalog.types).joined(separator: ",")),
                     "ratings=" + encoded(ratings.joined(separator: ","))]
        if let tag { parts.append("tag=" + encoded(tag)) }
        if !text.isEmpty { parts.append("text=" + encoded(text)) }
        return parts.joined(separator: " ")
    }
}

/// Results of the current catalogue query, accumulated page by page.
public struct BrowseState: Equatable, Sendable {
    public var query = WorkshopQuery()
    public var items: [WorkshopItem] = []
    public var total = 0
    public var nextPage = 1
    public var isLoading = false
    public var error: String?

    public init(query: WorkshopQuery = WorkshopQuery(), isLoading: Bool = false) {
        self.query = query
        self.isLoading = isLoading
    }

    public var canLoadMore: Bool { !isLoading && items.count < total }
}
