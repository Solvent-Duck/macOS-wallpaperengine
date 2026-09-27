import NativeSceneCore
import NativeSceneRuntime
@testable import NativeSceneRenderer
import Testing

struct PassGraphTests {
    @Test func hiddenProducersKeepTheirAuthoredPositionBeforeLaterSceneLayers() {
        func node(_ id: Int, visible: Bool = true, dependencies: [Int] = []) -> FrameNode {
            FrameNode(nodeID: NodeID(rawValue: id), name: "layer \(id)", kind: .image,
                      parentID: nil, dependencyIDs: dependencies.map { NodeID(rawValue: $0) },
                      localTransform: .identity, worldTransform: .identity, worldPosition: .zero,
                      visible: visible, opacity: nil, renderItemReferences: [], imageEffects: [], animationLayers: [])
        }
        let nodes = [node(1), node(2, visible: false), node(3), node(4, dependencies: [2]),
                     node(5, visible: false)]
        #expect(PassGraph().nodesInRenderOrder(nodes).map(\.nodeID.rawValue) == [1, 2, 3, 4])
    }

    @Test func dependenciesAreOrderedOnceWithoutActivatingUnrelatedHiddenLayers() {
        func node(_ id: Int, visible: Bool = true, dependencies: [Int] = []) -> FrameNode {
            FrameNode(nodeID: NodeID(rawValue: id), name: "layer \(id)", kind: .image,
                      parentID: nil, dependencyIDs: dependencies.map { NodeID(rawValue: $0) },
                      localTransform: .identity, worldTransform: .identity, worldPosition: .zero,
                      visible: visible, opacity: nil, renderItemReferences: [], imageEffects: [], animationLayers: [])
        }
        let nodes = [node(1, dependencies: [3, 99]), node(2), node(3, visible: false, dependencies: [4]),
                     node(4, visible: false, dependencies: [3, 4]), node(5, visible: false),
                     node(6, dependencies: [3])]
        let ordered = PassGraph().nodesInRenderOrder(nodes)
        #expect(ordered.map(\.nodeID.rawValue) == [4, 3, 1, 2, 6])
        #expect(ordered.filter { !$0.visible }.map(\.nodeID.rawValue) == [4, 3])
    }
}
