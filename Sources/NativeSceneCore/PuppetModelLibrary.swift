import Foundation

/// A scene's runtime and renderer share decoded skeletal assets, including
/// failed lookups, so attachment evaluation does not decode a second copy.
public final class PuppetModelLibrary: @unchecked Sendable {
    private let assetRoots: [URL]
    private let lock = NSLock()
    private var models: [String: PuppetModel?] = [:]

    public init(assetRoots: [URL]) {
        self.assetRoots = assetRoots
    }

    public func model(for path: String) -> PuppetModel? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = models[path] { return cached }
        let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : assetRoots.map { $0.appendingPathComponent(path) }
        var model: PuppetModel?
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            do { model = try PuppetModelDecoder.decode(Data(contentsOf: url)) }
            catch { print("[PuppetModelLibrary] Puppet decode failed for \(path): \(error.localizedDescription)") }
        }
        models[path] = .some(model)
        return model
    }
}
