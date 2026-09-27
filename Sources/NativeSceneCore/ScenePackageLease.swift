import Foundation

/// Shared by the parser and all copies of its scene description, keeping
/// extracted assets alive until the last scene consumer releases them.
final class ScenePackageLease: @unchecked Sendable {
    private let roots: [URL]

    init(roots: [URL]) { self.roots = roots }

    deinit {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
}
