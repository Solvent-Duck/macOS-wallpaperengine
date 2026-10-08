import Foundation

/// Steam `EItemState` flags reported by the helper.
public struct WorkshopItemState: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let subscribed = WorkshopItemState(rawValue: 1)
    public static let installed = WorkshopItemState(rawValue: 4)
    public static let needsUpdate = WorkshopItemState(rawValue: 8)
    public static let downloading = WorkshopItemState(rawValue: 16)
    public static let downloadPending = WorkshopItemState(rawValue: 32)
}

/// Steam `EResult` codes the sync cares about.
public enum SteamResult {
    public static let ok = 1
    public static let fileNotFound = 9
    public static let accessDenied = 15

    /// Results meaning the item can't be downloaded until something changes
    /// on Steam's side (removed, private, banned).
    public static func isPermanentFailure(_ code: Int) -> Bool {
        code == fileNotFound || code == accessDenied
    }
}

/// One event line from `SteamWorkshopHelper`.
public enum WorkshopHelperEvent: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Decodable {
        public let id: String
        public let state: UInt32
        public let folder: String
        public let size: UInt64
        public let timeUpdated: UInt64

        public var flags: WorkshopItemState { WorkshopItemState(rawValue: state) }
    }

    public struct Details: Equatable, Sendable, Decodable {
        public let id: String
        public let result: Int
        public let title: String
        public let tags: String
        public let preview: String
        public let fileSize: UInt64
    }

    case ready(steamID: String)
    case error(code: String, message: String)
    case subscriptions(settled: Bool, items: [Item])
    case progress(id: String, state: UInt32, downloaded: UInt64, total: UInt64)
    case downloadStarted(id: String, ok: Bool)
    case downloadResult(id: String, result: Int)
    case installed(Item)
    case subscribed(id: String)
    case unsubscribed(id: String)
    case subscribeResult(id: String, result: Int)
    case unsubscribeResult(id: String, result: Int)
    case details([Details])

    /// Decode one JSON line; nil for anything unrecognised.
    public static func decode(_ line: String) -> WorkshopHelperEvent? {
        guard let data = line.data(using: .utf8),
              let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        let d = JSONDecoder()
        switch header.event {
        case "ready":
            return (try? d.decode(Ready.self, from: data)).map { .ready(steamID: $0.steamID) }
        case "error":
            return (try? d.decode(Failure.self, from: data)).map { .error(code: $0.code, message: $0.message) }
        case "subscriptions":
            return (try? d.decode(Subscriptions.self, from: data)).map { .subscriptions(settled: $0.settled, items: $0.items) }
        case "progress":
            return (try? d.decode(Progress.self, from: data)).map {
                .progress(id: $0.id, state: $0.state, downloaded: $0.downloaded, total: $0.total)
            }
        case "downloadStarted":
            return (try? d.decode(Started.self, from: data)).map { .downloadStarted(id: $0.id, ok: $0.ok) }
        case "downloadResult":
            return (try? d.decode(Result.self, from: data)).map { .downloadResult(id: $0.id, result: $0.result) }
        case "subscribeResult":
            return (try? d.decode(Result.self, from: data)).map { .subscribeResult(id: $0.id, result: $0.result) }
        case "unsubscribeResult":
            return (try? d.decode(Result.self, from: data)).map { .unsubscribeResult(id: $0.id, result: $0.result) }
        case "installed":
            return (try? d.decode(Installed.self, from: data)).map { .installed($0.item) }
        case "subscribed":
            return (try? d.decode(Identified.self, from: data)).map { .subscribed(id: $0.id) }
        case "unsubscribed":
            return (try? d.decode(Identified.self, from: data)).map { .unsubscribed(id: $0.id) }
        case "details":
            return (try? d.decode(DetailsList.self, from: data)).map { .details($0.items) }
        default:
            return nil
        }
    }

    private struct Header: Decodable { let event: String }
    private struct Ready: Decodable { let steamID: String }
    private struct Failure: Decodable { let code: String; let message: String }
    private struct Subscriptions: Decodable { let settled: Bool; let items: [Item] }
    private struct Progress: Decodable { let id: String; let state: UInt32; let downloaded: UInt64; let total: UInt64 }
    private struct Started: Decodable { let id: String; let ok: Bool }
    private struct Result: Decodable { let id: String; let result: Int }
    private struct Installed: Decodable { let item: Item }
    private struct Identified: Decodable { let id: String }
    private struct DetailsList: Decodable { let items: [Details] }
}

/// A running helper process, seen as lines in and events out.
@MainActor
public protocol WorkshopHelperConnection: AnyObject {
    func send(_ command: String)
    /// Ask the helper to end the Steam session and exit.
    func quit()
}

/// Starts `SteamWorkshopHelper` and relays its events to the main actor.
@MainActor
public final class WorkshopHelperProcess: WorkshopHelperConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    /// Launch the helper. `onEvent` and `onExit` run on the main actor;
    /// `onExit` gets the exit status once the process ends.
    public init(helper: URL, steamAPI: URL,
                onEvent: @escaping @MainActor (WorkshopHelperEvent) -> Void,
                onExit: @escaping @MainActor (Int32) -> Void) throws {
        process.executableURL = helper
        process.arguments = ["--steam-api", steamAPI.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) {
                guard let event = WorkshopHelperEvent.decode(line) else { continue }
                Task { @MainActor in onEvent(event) }
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            // Let the last output lines arrive before reporting the exit.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                onExit(status)
            }
        }
        try process.run()
    }

    public func send(_ command: String) {
        guard process.isRunning, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    public func quit() {
        send("quit")
        try? input.fileHandleForWriting.close()
    }
}

/// Splits a byte stream into lines; used from the pipe's reading queue only.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        return lines
    }
}
