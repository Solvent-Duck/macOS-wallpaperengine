import Foundation
import NativeSceneCore
import simd

public struct NodeTransformState: Sendable {
    public let localTransform: Matrix4x4f
    public let worldTransform: Matrix4x4f
    public let origin: RuntimeVector3
    public let scale: RuntimeVector3
    public let angles: RuntimeVector3
}

public enum TransformEvaluator {
    public static func evaluationOrder(for nodes: [NodeDescriptor], parents: [NodeID: NodeID]? = nil) -> [NodeDescriptor] {
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var visited = Set<NodeID>()
        var visiting = Set<NodeID>()
        var ordered: [NodeDescriptor] = []

        func visit(_ node: NodeDescriptor) {
            if visited.contains(node.id) || visiting.contains(node.id) {
                return
            }

            visiting.insert(node.id)
            let parentID = parents.map { $0[node.id] } ?? node.parentId
            if let parentID, let parent = nodesByID[parentID] {
                visit(parent)
            }
            visiting.remove(node.id)
            visited.insert(node.id)
            ordered.append(node)
        }

        // Preserve authored scene order (paint order); parents are hoisted
        // ahead of their children only when required.
        for node in nodes {
            visit(node)
        }

        return ordered
    }

    public static func evaluate(
        scene: SceneDescription,
        propertyEvaluator: PropertyEvaluator,
        parallaxDisplacement: RuntimeVector2 = .zero,
        cameraShakeDisplacement: RuntimeVector2 = .zero,
        attachmentTransforms: [NodeID: Matrix4x4f] = [:]
    ) -> [NodeID: NodeTransformState] {
        let parents = resolvedParents(scene: scene, scriptHost: propertyEvaluator.context.scriptHost)
        let orderedNodes = evaluationOrder(for: scene.nodes, parents: parents)
        let nodesByID = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
        var states: [NodeID: NodeTransformState] = [:]

        for node in orderedNodes {
            let origin = propertyEvaluator.vector3Value(for: node.origin, default: .zero)
            let scale = nodeScale(for: node, propertyEvaluator: propertyEvaluator)
            let angles = nodeAngles(for: node, propertyEvaluator: propertyEvaluator)
            let shookOrigin = RuntimeVector3(
                x: origin.x + cameraShakeDisplacement.x,
                y: origin.y + cameraShakeDisplacement.y,
                z: origin.z
            )
            let parallaxAdjustedOrigin = applyingParallax(
                for: node,
                origin: shookOrigin,
                scene: scene,
                propertyEvaluator: propertyEvaluator,
                parallaxDisplacement: parallaxDisplacement
            )
            let local = localTransform(origin: parallaxAdjustedOrigin, scale: scale, angles: angles)

            let parentWorld = parents[node.id].flatMap { parentID in
                states[parentID]?.worldTransform.simdValue ?? nodesByID[parentID].map { _ in matrix_identity_float4x4 }
            } ?? matrix_identity_float4x4

            let attachment = attachmentTransforms[node.id]?.simdValue ?? matrix_identity_float4x4
            let world = parentWorld * attachment * local
            states[node.id] = NodeTransformState(
                localTransform: Matrix4x4f(local),
                worldTransform: Matrix4x4f(world),
                origin: origin,
                scale: scale,
                angles: angles
            )
        }

        return states
    }

    static func resolvedParents(scene: SceneDescription, scriptHost: ScriptHost?) -> [NodeID: NodeID] {
        var parents: [NodeID: NodeID] = [:]
        for node in scene.nodes {
            parents[node.id] = scriptHost.map { $0.parentID(for: node) } ?? node.parentId
        }
        return parents
    }

    private static func applyingParallax(
        for node: NodeDescriptor,
        origin: RuntimeVector3,
        scene: SceneDescription,
        propertyEvaluator: PropertyEvaluator,
        parallaxDisplacement: RuntimeVector2
    ) -> RuntimeVector3 {
        guard let camera = scene.scene?.camera,
              propertyEvaluator.boolValue(for: camera.parallax.enabled, default: false),
              let depth = parallaxDepth(for: node, propertyEvaluator: propertyEvaluator) else {
            return origin
        }

        let nodeExtent = parallaxExtent(for: node, propertyEvaluator: propertyEvaluator)
        let x = depth.x * parallaxDisplacement.x * nodeExtent
        let y = depth.y * parallaxDisplacement.y * nodeExtent
        return RuntimeVector3(
            x: origin.x + x,
            y: origin.y + y,
            z: origin.z
        )
    }

    private static func nodeScale(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator
    ) -> RuntimeVector3 {
        if let group = node.group {
            return propertyEvaluator.vector3Value(for: group.scale, default: .one)
        }
        if let image = node.image {
            return propertyEvaluator.vector3Value(for: image.scale, default: .one)
        }
        if let light = node.light {
            return propertyEvaluator.vector3Value(for: light.scale, default: .one)
        }
        if let particle = node.particle {
            return propertyEvaluator.vector3Value(for: particle.scale, default: .one)
        }
        if let text = node.text {
            return propertyEvaluator.vector3Value(for: text.scale, default: .one)
        }
        return .one
    }

    private static func nodeAngles(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator
    ) -> RuntimeVector3 {
        if let group = node.group {
            return propertyEvaluator.vector3Value(for: group.angles, default: .zero)
        }
        if let image = node.image {
            return propertyEvaluator.vector3Value(for: image.angles, default: .zero)
        }
        if let light = node.light {
            return propertyEvaluator.vector3Value(for: light.angles, default: .zero)
        }
        if let particle = node.particle {
            return propertyEvaluator.vector3Value(for: particle.angles, default: .zero)
        }
        if let text = node.text {
            return propertyEvaluator.vector3Value(for: text.angles, default: .zero)
        }
        return .zero
    }

    private static func parallaxDepth(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator
    ) -> RuntimeVector2? {
        if let image = node.image {
            return propertyEvaluator.vector2Value(for: image.parallaxDepth, default: .zero)
        }
        if let text = node.text {
            return propertyEvaluator.vector2Value(for: text.parallaxDepth, default: .zero)
        }
        if let particle = node.particle {
            return propertyEvaluator.vector2Value(for: particle.parallaxDepth, default: .zero)
        }
        return nil
    }

    private static func parallaxExtent(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator
    ) -> Float {
        if let image = node.image {
            return max(Float(image.size.first ?? 1), 1)
        }
        if let text = node.text {
            let size = RuntimeVector2(text.size, default: RuntimeVector2(x: 1, y: 1))
            return max(size.x, 1)
        }
        if let particle = node.particle {
            let scale = propertyEvaluator.vector3Value(for: particle.scale, default: .one)
            return max(scale.x, 1)
        }
        return 1
    }

    private static func localTransform(
        origin: RuntimeVector3,
        scale: RuntimeVector3,
        angles: RuntimeVector3
    ) -> simd_float4x4 {
        translationMatrix(origin)
        * rotationMatrix(angles)
        * scaleMatrix(scale)
    }

    private static func translationMatrix(_ vector: RuntimeVector3) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(vector.x, vector.y, vector.z, 1)
        )
    }

    private static func scaleMatrix(_ vector: RuntimeVector3) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(vector.x, 0, 0, 0),
            SIMD4(0, vector.y, 0, 0),
            SIMD4(0, 0, vector.z, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    private static func rotationMatrix(_ angles: RuntimeVector3) -> simd_float4x4 {
        // Scene JSON stores angles in radians. Keep the authored Y-up basis;
        // texture-row orientation belongs to the geometry, not the transform.
        let radians = SIMD3(angles.x, angles.y, angles.z)

        let x = simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, cos(radians.x), sin(radians.x), 0),
            SIMD4(0, -sin(radians.x), cos(radians.x), 0),
            SIMD4(0, 0, 0, 1)
        )
        let y = simd_float4x4(
            SIMD4(cos(radians.y), 0, -sin(radians.y), 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(sin(radians.y), 0, cos(radians.y), 0),
            SIMD4(0, 0, 0, 1)
        )
        let z = simd_float4x4(
            SIMD4(cos(radians.z), sin(radians.z), 0, 0),
            SIMD4(-sin(radians.z), cos(radians.z), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        )

        return z * y * x
    }
}
