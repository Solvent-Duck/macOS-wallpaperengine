import Foundation
import NativeSceneCore
import NativeSceneRuntime

public struct RenderPassCommand: Sendable {
    public let nodeID: NodeID
    public let materialID: String
    public let pass: FrameMaterialPass
}

public struct PassGraph: Sendable {
    public init() {}

    /// Hidden layers can still supply textures to visible dependents. Visit
    /// those producers first while retaining authored order for unrelated nodes.
    func nodesInRenderOrder(_ nodes: [FrameNode]) -> [FrameNode] {
        let nodesByID = Dictionary(nodes.map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
        var required = Set<NodeID>()
        func require(_ node: FrameNode) {
            guard required.insert(node.nodeID).inserted else { return }
            for dependency in node.dependencyIDs {
                if let producer = nodesByID[dependency] { require(producer) }
            }
        }
        for node in nodes where node.visible { require(node) }

        var visited = Set<NodeID>()
        var ordered: [FrameNode] = []
        func visit(_ node: FrameNode) {
            // Mark before descending so self references and cycles terminate.
            guard visited.insert(node.nodeID).inserted else { return }
            for dependency in node.dependencyIDs {
                if let producer = nodesByID[dependency] { visit(producer) }
            }
            ordered.append(node)
        }
        // A hidden composition layer captures the scene at its authored
        // position. Deferring it until its first consumer would also capture
        // intervening layers and contaminate the consumer's texture.
        for node in nodes where required.contains(node.nodeID) { visit(node) }
        return ordered
    }

    public func build(packet: FramePacket) -> [RenderPassCommand] {
        let materialsByID = Dictionary(packet.materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var commands: [RenderPassCommand] = []

        for node in nodesInRenderOrder(packet.nodes) where node.visible || node.kind == .image {
            for materialID in node.renderItemReferences {
                guard let material = materialsByID[materialID] else {
                    continue
                }

                for orderedPassIndex in material.passOrdering {
                    guard let pass = material.passes.first(where: { $0.index == orderedPassIndex }) else {
                        continue
                    }

                    commands.append(
                        RenderPassCommand(
                            nodeID: node.nodeID,
                            materialID: material.id,
                            pass: pass
                        )
                    )
                }
            }
        }

        return commands
    }
}
