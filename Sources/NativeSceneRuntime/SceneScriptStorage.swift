import CryptoKit
import Foundation

/// JSON storage belongs to a wallpaper, with a separate namespace per display.
/// Tools and tests use an in-memory instance unless they explicitly supply a root.
public final class SceneScriptStorage: @unchecked Sendable {
    public static let byteLimit = 100 * 1024
    private let backend: Backend
    private let screenID: String

    public static func wallpaperIdentity(workshopID: String?, directory: URL) -> String {
        if let workshopID, let number = UInt64(workshopID), number > 0 { return "workshop:\(number)" }
        return "path:\(directory.standardizedFileURL.resolvingSymlinksInPath().path)"
    }

    public init(directory: URL? = nil, wallpaperID: String = "", screenID: String = "default") throws {
        self.screenID = screenID
        if let directory {
            let digest = SHA256.hash(data: Data(wallpaperID.utf8)).map { String(format: "%02x", $0) }.joined()
            self.backend = try Backend.shared(at: directory.appendingPathComponent(digest + ".json"))
        } else {
            self.backend = Backend()
        }
    }

    private init(backend: Backend, screenID: String) {
        self.backend = backend
        self.screenID = screenID
    }

    public func forScreen(_ screenID: String) -> SceneScriptStorage {
        SceneScriptStorage(backend: backend, screenID: screenID)
    }

    /// Settings reset clears every display and the wallpaper's global namespace.
    public func reset() throws { try backend.reset() }

    func request(_ json: String) throws -> String? {
        guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let operation = request["operation"] as? String else {
            throw StorageError.invalidRequest
        }
        let location = request["location"] as? String ?? "screen"
        guard location == "screen" || location == "global" else { throw StorageError.invalidLocation }
        let scope = location == "global" ? "global" : "screen:" + screenID
        return try backend.request(operation: operation, scope: scope, key: request["key"] as? String, value: request["value"])
    }

    private enum StorageError: LocalizedError {
        case invalidRequest, invalidLocation, quotaExceeded, invalidFile
        var errorDescription: String? {
            switch self {
            case .invalidRequest: return "Invalid SceneScript localStorage request"
            case .invalidLocation: return "Invalid SceneScript localStorage location"
            case .quotaExceeded: return "SceneScript localStorage exceeds 100 KB per wallpaper"
            case .invalidFile: return "SceneScript localStorage file has an invalid format"
            }
        }
    }

    private final class Backend: @unchecked Sendable {
        private final class WeakEntry { weak var value: Backend?; init(_ value: Backend) { self.value = value } }
        private static let registryLock = NSLock()
        nonisolated(unsafe) private static var registry: [String: WeakEntry] = [:]
        private let lock = NSLock()
        private var scopes: [String: [String: Any]] = [:]
        private let fileURL: URL?

        init() { fileURL = nil }

        private init(fileURL: URL) throws {
            self.fileURL = fileURL
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                guard let scopes = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                    throw StorageError.invalidFile
                }
                self.scopes = scopes
            }
        }

        static func shared(at url: URL) throws -> Backend {
            registryLock.lock()
            defer { registryLock.unlock() }
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            if let backend = registry[url.path]?.value { return backend }
            let backend = try Backend(fileURL: url)
            registry = registry.filter { $0.value.value != nil }
            registry[url.path] = WeakEntry(backend)
            return backend
        }

        func request(operation: String, scope: String, key: String?, value: Any?) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            if operation == "get" {
                guard let key else { throw StorageError.invalidRequest }
                return try scopes[scope]?[key].map { String(decoding: try encode($0), as: UTF8.self) }
            }
            var next = scopes
            var result: String?
            switch operation {
            case "set":
                guard let key, let value else { throw StorageError.invalidRequest }
                next[scope, default: [:]][key] = value
            case "delete":
                guard let key else { throw StorageError.invalidRequest }
                result = next[scope]?.removeValue(forKey: key) == nil ? "false" : "true"
            case "clear": next.removeValue(forKey: scope)
            default: throw StorageError.invalidRequest
            }
            next = next.filter { !$0.value.isEmpty }
            try persist(next)
            return result
        }

        func reset() throws {
            lock.lock()
            defer { lock.unlock() }
            try persist([:])
        }

        private func encode(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }

        private func persist(_ next: [String: [String: Any]]) throws {
            let data = try encode(next)
            guard data.count <= SceneScriptStorage.byteLimit else { throw StorageError.quotaExceeded }
            guard data != (try encode(scopes)) else { return }
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            }
            scopes = next
        }
    }
}
