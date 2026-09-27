import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
import simd

final class DirectModelRenderer {
    struct Geometry {
        let material: String
        let positions: MTLBuffer
        let texCoords: MTLBuffer
        let attributes: [String: MTLBuffer]
        let vertexCount: Int
        let center: SIMD3<Float>
    }

    private let roots: [URL]
    private let puppets: PuppetModelLibrary
    private var models: [String: [DirectModelMesh]] = [:]
    private var staticGeometry: [String: Geometry] = [:]

    init(assetRoots: [URL], puppetModels: PuppetModelLibrary) {
        roots = assetRoots
        puppets = puppetModels
    }

    func geometry(path: String, frame: FrameNode, time: Double, device: MTLDevice) throws -> [Geometry] {
        let meshes: [DirectModelMesh]
        if let cached = models[path] { meshes = cached }
        else {
            guard let url = roots.map({ $0.appendingPathComponent(path) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw NativeSceneRendererError.unsupportedScene("missing model \(path)")
            }
            meshes = try DirectModelDecoder.decode(Data(contentsOf: url))
            models[path] = meshes
        }
        let active = frame.animationLayers.first { $0.visible && $0.blend > 0 }
        let skins = meshes.contains(where: \.skinned) && (frame.animationLayers.isEmpty || active != nil)
            ? puppets.model(for: path)?.skinTransforms(at: time, animationID: active?.animation,
                rate: active?.rate ?? 1, blend: active?.blend ?? 1, frame: active?.sampleFrame) : nil
        return try meshes.enumerated().map { index, mesh in
            let key = "\(path):\(index)"
            if !mesh.skinned, let cached = staticGeometry[key] { return cached }
            var positions: [Float] = [], normals: [Float] = [], tangents: [Float] = [], uvs: [Float] = []
            var minimum = SIMD3<Float>(repeating: .infinity)
            var maximum = SIMD3<Float>(repeating: -.infinity)
            positions.reserveCapacity(mesh.indices.count * 3)
            normals.reserveCapacity(mesh.indices.count * 3)
            tangents.reserveCapacity(mesh.indices.count * 4)
            uvs.reserveCapacity(mesh.indices.count * 2)
            for index in mesh.indices {
                let vertex = mesh.vertices[Int(index)]
                var position = vertex.position, normal = vertex.normal
                var tangent = SIMD3(vertex.tangent.x, vertex.tangent.y, vertex.tangent.z)
                if mesh.skinned, let skins {
                    var weighted = matrix_identity_float4x4 * 0, total: Float = 0
                    for slot in 0..<4 {
                        let bone = Int(vertex.boneIndices[slot]), weight = vertex.weights[slot]
                        if weight > 0, bone < skins.count { weighted += skins[bone] * weight; total += weight }
                    }
                    if total > 0 {
                        weighted *= 1 / total
                        let transformed = weighted * SIMD4(position, 1)
                        position = SIMD3(transformed.x, transformed.y, transformed.z)
                        let basis = simd_float3x3(columns: (SIMD3(weighted.columns.0.x, weighted.columns.0.y, weighted.columns.0.z),
                            SIMD3(weighted.columns.1.x, weighted.columns.1.y, weighted.columns.1.z),
                            SIMD3(weighted.columns.2.x, weighted.columns.2.y, weighted.columns.2.z)))
                        if abs(simd_determinant(basis)) > 1e-10 { normal = simd_transpose(simd_inverse(basis)) * normal }
                        tangent = basis * tangent
                    }
                }
                if simd_length_squared(normal) > 1e-12 { normal = simd_normalize(normal) }
                if simd_length_squared(tangent) > 1e-12 { tangent = simd_normalize(tangent) }
                minimum = simd_min(minimum, position)
                maximum = simd_max(maximum, position)
                positions += [position.x, position.y, position.z]
                normals += [normal.x, normal.y, normal.z]
                tangents += [tangent.x, tangent.y, tangent.z, vertex.tangent.w]
                uvs += [vertex.uv.x, vertex.uv.y]
            }
            func buffer(_ values: [Float]) throws -> MTLBuffer {
                guard let buffer = device.makeBuffer(bytes: values, length: values.count * MemoryLayout<Float>.stride) else {
                    throw NativeSceneRendererError.unsupportedScene("could not allocate model geometry")
                }
                return buffer
            }
            let tangentBuffer = try buffer(tangents)
            let geometry = try Geometry(material: mesh.material, positions: buffer(positions), texCoords: buffer(uvs),
                attributes: ["a_Normal": buffer(normals), "a_Tangent": tangentBuffer, "a_Tangent4": tangentBuffer],
                vertexCount: mesh.indices.count, center: minimum * 0.5 + maximum * 0.5)
            if !mesh.skinned { staticGeometry[key] = geometry }
            return geometry
        }
    }

    static func cameraDepth(geometry: Geometry, frame: FrameNode, scene: SceneDescription) -> Float {
        guard let camera = scene.scene?.camera.configuration else { return 0 }
        let eye = RuntimeVector3(camera.eye).simdValue
        let forward = RuntimeVector3(camera.center).simdValue - eye
        let direction = simd_length_squared(forward) > 1e-12 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
        let world = frame.worldTransform.simdValue * SIMD4(geometry.center, 1)
        let depth = simd_dot(SIMD3(world.x, world.y, world.z) - eye, direction)
        return depth.isFinite ? depth : 0
    }

    /// Model coordinates use a right-handed camera and Metal's [0, 1] depth.
    /// A perspective layer in a 2D scene shares the pixel plane at z=0.
    static func uniforms(node: NodeDescriptor, frame: FrameNode, scene: SceneDescription, viewport: CGSize, cameraZoom: Float = 1) -> [String: Data] {
        let camera = scene.scene!.camera
        let projection = camera.projection
        let full3D = projection.isPerspective == true
        let perspective = node.image?.perspective ?? full3D
        let width = Float(projection.width > 0 ? projection.width : Int(viewport.width))
        let height = Float(projection.height > 0 ? projection.height : Int(viewport.height))
        let fov = Float(full3D ? projection.fov : projection.perspectiveOverrideFOV ?? projection.fov)
        let cotangent = 1 / tan(min(179, max(1, fov)) * .pi / 360)
        let planeDistance = full3D ? 0 : height * cotangent / 2
        let near = Float(max(0.0001, projection.nearZ))
        // The 2D camera is moved back to preserve pixel scale. Its far range
        // must include that offset, or large scene planes disappear at z=0.
        let far = max(near + 1, Float(projection.farZ) + planeDistance)
        func vector(_ values: [Double]) -> SIMD3<Float> { SIMD3(Float(values[0]), Float(values[1]), Float(values[2])) }
        let origin = full3D ? SIMD3<Float>.zero : SIMD3(width / 2, height / 2, planeDistance)
        let eye = vector(camera.configuration.eye) + origin
        let target = vector(camera.configuration.center) + origin
        let view = MaterialBinder.cameraViewMatrix(eye: eye, center: target, up: vector(camera.configuration.up))
        let zoom: Float = full3D ? 1 : cameraZoom
        let project: simd_float4x4
        if perspective {
            project = simd_float4x4(SIMD4(zoom * cotangent * height / width, 0, 0, 0), SIMD4(0, zoom * cotangent, 0, 0),
                SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0))
        } else {
            project = simd_float4x4(SIMD4(2 * zoom / width, 0, 0, 0), SIMD4(0, 2 * zoom / height, 0, 0),
                SIMD4(0, 0, 1 / (near - far), 0), SIMD4(0, 0, near / (near - far), 1))
        }
        // Embedded models share the 2D projection/view pair used by image
        // and particle layers. Full 3D cameras retain ordinary translation.
        var cameraOffset = matrix_identity_float4x4
        if !full3D { cameraOffset.columns.3 = SIMD4(vector(camera.configuration.eye), 1) }
        let model = frame.worldTransform.simdValue, viewProjection = project * cameraOffset * view, mvp = viewProjection * model
        let basis = simd_float3x3(columns: (SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z), SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)))
        let normal = abs(simd_determinant(basis)) > 1e-10 ? simd_transpose(simd_inverse(basis)) : matrix_identity_float3x3
        func bytes<T>(_ value: T) -> Data { var value = value; return withUnsafeBytes(of: &value) { Data($0) } }
        return ["g_ModelMatrix": bytes(model), "g_AltModelMatrix": bytes(model), "g_ModelMatrixInverse": bytes(simd_inverse(model)),
                "g_ModelViewProjectionMatrix": bytes(mvp), "g_ModelViewProjectionMatrixInverse": bytes(simd_inverse(mvp)),
                "g_ViewProjectionMatrix": bytes(viewProjection), "g_AltViewProjectionMatrix": bytes(viewProjection),
                "g_NormalModelMatrix": bytes(normal), "g_AltNormalModelMatrix": bytes(normal), "g_EyePosition": bytes(eye)]
    }
}
