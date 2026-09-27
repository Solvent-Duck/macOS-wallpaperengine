import Foundation
import NativeSceneCore

/// The runtime's current graph. JavaScript references and render packets use the
/// same monotonically allocated IDs; destruction is committed between frames.
final class SceneLayerCollection {
    private(set) var scene: SceneDescription
    private let initialScene: SceneDescription
    private(set) var revision: UInt64 = 0
    let assetRoots: [URL]
    private var nextID: Int
    private var configurations: [NodeID: Data] = [:]
    private var loadedInitialConfigurations = false
    private var pendingRemoval: Set<NodeID> = []

    init(scene: SceneDescription, assetRoots: [URL]) {
        self.scene = scene
        self.initialScene = scene
        self.assetRoots = assetRoots
        nextID = max(0, scene.nodes.map(\.id.rawValue).max() ?? 0)
    }

    struct PreparedLayer {
        let node: NodeDescriptor
        let configuration: Data
    }

    func prepare(_ configuration: Any, workshopID: String? = nil) throws -> PreparedLayer {
        guard scene.nodes.count < 16_384, nextID < Int.max else {
            throw ScriptHostError.evaluationFailed("Scene layer capacity exceeded")
        }
        let data = try JSONSerialization.data(withJSONObject: configuration, options: .fragmentsAllowed)
        guard data.count <= 8 * 1024 * 1024 else {
            throw ScriptHostError.evaluationFailed("Layer configuration is too large")
        }
        let id = NodeID(rawValue: nextID + 1)
        let parsed = try SceneDescriptionLoader.loadLayer(configurationJSON: data, nodeID: id,
            userProperties: scene.userProperties, assetRoots: assetRoots, workshopID: workshopID)
        nextID = id.rawValue
        return PreparedLayer(node: parsed.node, configuration: parsed.configuration)
    }

    func insert(_ layer: PreparedLayer) {
        configurations[layer.node.id] = layer.configuration
        scene = scene.replacingNodes(scene.nodes + [layer.node])
        revision &+= 1
    }

    func reset() {
        scene = initialScene
        configurations.removeAll()
        pendingRemoval.removeAll()
        loadedInitialConfigurations = false
        revision &+= 1
    }

    func initialConfiguration(for id: NodeID) throws -> Any? {
        guard scene.nodes.contains(where: { $0.id == id }) else { return nil }
        if let data = configurations[id] { return try JSONSerialization.jsonObject(with: data) }
        if !loadedInitialConfigurations {
            // Existing in-memory fixtures need no backing scene file unless a
            // script actually asks to clone one of their authored nodes.
            let originals = try SceneDescriptionLoader.loadInitialLayerConfigurations(
                sceneFile: scene.metadata.wallpaperFile, assetRoots: assetRoots)
            configurations.merge(originals, uniquingKeysWith: { current, _ in current })
            loadedInitialConfigurations = true
        }
        return try configurations[id].map { try JSONSerialization.jsonObject(with: $0) }
    }

    func sort(_ id: NodeID, at index: Int) -> Bool {
        var nodes = scene.nodes
        guard let old = nodes.firstIndex(where: { $0.id == id }) else { return false }
        let node = nodes.remove(at: old)
        nodes.insert(node, at: min(max(index, 0), nodes.count))
        scene = scene.replacingNodes(nodes)
        revision &+= 1
        return true
    }

    func destroy(_ id: NodeID) -> Bool {
        guard scene.nodes.contains(where: { $0.id == id }) else { return false }
        return pendingRemoval.insert(id).inserted
    }

    func commitRemovals() -> Set<NodeID> {
        let removed = pendingRemoval
        guard !removed.isEmpty else { return [] }
        pendingRemoval.removeAll()
        scene = scene.replacingNodes(scene.nodes.filter { !removed.contains($0.id) })
        revision &+= 1
        for id in removed { configurations[id] = nil }
        return removed
    }
}
