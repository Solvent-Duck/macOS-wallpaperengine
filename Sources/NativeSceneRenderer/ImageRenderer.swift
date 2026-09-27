import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime

final class ImageRenderer {
    struct SceneGeometry {
        let positions: MTLBuffer
        let texCoords: MTLBuffer
        let vertexCount: Int
    }

    /// Decoded puppet model plus the affine fit mapping bind-pose mesh
    /// coordinates onto the unit quad (derived from the mesh UVs, which are
    /// authored to drape exactly over the material texture).
    private struct PuppetEntry {
        let model: PuppetModel
        let mapScale: SIMD2<Float>
        let mapOffset: SIMD2<Float>
    }

    private let assetRoots: [URL]
    private let puppetModels: PuppetModelLibrary
    private var geometryCache: [String: SceneGeometry] = [:]
    private var puppetCache: [String: PuppetEntry?] = [:]

    init(assetRoots: [URL], puppetModels: PuppetModelLibrary? = nil) {
        self.assetRoots = assetRoots
        self.puppetModels = puppetModels ?? PuppetModelLibrary(assetRoots: assetRoots)
    }

    func resolvedSize(
        for nodeDescriptor: NodeDescriptor,
        scene: SceneDescription,
        viewportSize: CGSize
    ) -> CGSize? {
        guard let image = nodeDescriptor.image else {
            return nil
        }

        return resolvedSize(for: image, scene: scene, viewportSize: viewportSize)
    }

    func makeSceneGeometry(
        for nodeDescriptor: NodeDescriptor,
        scene: SceneDescription,
        viewportSize: CGSize,
        device: MTLDevice,
        elapsedTime: Double = 0,
        animationLayers: [AnimationLayerFrame] = [],
        alignment: String? = nil
    ) -> SceneGeometry? {
        guard let image = nodeDescriptor.image else {
            return nil
        }

        let size = resolvedSize(for: image, scene: scene, viewportSize: viewportSize)
        let anchorOffset = alignmentOffset(alignment ?? image.alignment, size: size)
        if let model = image.model {
            if let puppetPath = model.puppet,
               let entry = puppetEntry(for: puppetPath),
               let geometry = makePuppetGeometry(
                entry: entry,
                size: size,
                anchorOffset: anchorOffset,
                elapsedTime: elapsedTime,
                animationLayers: animationLayers,
                device: device
               ) {
                return geometry
            }

            if let geometry = loadModelGeometry(model: model, anchorOffset: anchorOffset, device: device) {
                return geometry
            }
        }

        return makeGeometry(
            positions: quadPositions(width: size.width, height: size.height),
            texCoords: quadTexCoords(),
            device: device,
            offset: anchorOffset
        )
    }

    func alignmentOffset(_ alignment: String, size: CGSize) -> SIMD2<Float> {
        let alignment = alignment.lowercased()
        // Shift local geometry before the layer transform, so its authored
        // origin remains the anchor while scaling and rotation pivot around it.
        return SIMD2(
            alignment.contains("left") ? Float(size.width / 2) : alignment.contains("right") ? -Float(size.width / 2) : 0,
            alignment.contains("bottom") ? Float(size.height / 2) : alignment.contains("top") ? -Float(size.height / 2) : 0
        )
    }

    private func puppetEntry(for path: String) -> PuppetEntry? {
        if let cached = puppetCache[path] {
            return cached
        }

        var entry: PuppetEntry?
        if let model = puppetModels.model(for: path), !model.vertices.isEmpty, !model.triangles.isEmpty {
            let (scale, offset) = Self.fitBindPoseToUnitQuad(model: model)
            entry = PuppetEntry(model: model, mapScale: scale, mapOffset: offset)
        }
        puppetCache[path] = entry
        return entry
    }

    /// Least-squares per-axis fit of bind-pose vertex positions onto the
    /// UV-derived unit quad ((u,v) - 0.5). Handles either Y direction and any
    /// coordinate offset the authoring tool used.
    private static func fitBindPoseToUnitQuad(model: PuppetModel) -> (SIMD2<Float>, SIMD2<Float>) {
        var sumPos = SIMD2<Float>(0, 0)
        var sumTarget = SIMD2<Float>(0, 0)
        let count = Float(model.vertices.count)
        for vertex in model.vertices {
            sumPos += vertex.position
            sumTarget += vertex.uv - SIMD2<Float>(0.5, 0.5)
        }
        let meanPos = sumPos / count
        let meanTarget = sumTarget / count

        var covariance = SIMD2<Float>(0, 0)
        var variance = SIMD2<Float>(0, 0)
        for vertex in model.vertices {
            let dp = vertex.position - meanPos
            let dt = (vertex.uv - SIMD2<Float>(0.5, 0.5)) - meanTarget
            covariance += dp * dt
            variance += dp * dp
        }

        var scale = SIMD2<Float>(1, 1)
        for axis in 0..<2 {
            scale[axis] = variance[axis] > 1e-6 ? covariance[axis] / variance[axis] : 0
        }
        let offset = meanTarget - meanPos * scale
        return (scale, offset)
    }

    private func makePuppetGeometry(
        entry: PuppetEntry,
        size: CGSize,
        anchorOffset: SIMD2<Float>,
        elapsedTime: Double,
        animationLayers: [AnimationLayerFrame],
        device: MTLDevice
    ) -> SceneGeometry? {
        let model = entry.model
        let layer = animationLayers.first(where: { $0.visible && $0.blend > 0 })
        let animationID = layer?.animation
        let rate = layer?.rate ?? 1

        let positions: [SIMD2<Float>]
        if (animationLayers.isEmpty || layer != nil),
           let skins = model.skinTransforms(at: elapsedTime, animationID: animationID, rate: rate,
                                           blend: layer?.blend ?? 1, frame: layer?.sampleFrame) {
            positions = model.deformedPositions(skins: skins)
        } else {
            // An authored list with no active layer keeps the bind mesh.
            // Falling back to its first entry played explicitly hidden clips.
            positions = model.vertices.map(\.position)
        }

        let width = Float(size.width)
        let height = Float(size.height)
        var trianglePositions: [Float] = []
        var triangleTexCoords: [Float] = []
        trianglePositions.reserveCapacity(model.triangles.count * 3)
        triangleTexCoords.reserveCapacity(model.triangles.count * 2)

        for index in model.triangles {
            let i = Int(index)
            guard i < positions.count else {
                continue
            }
            let mapped = positions[i] * entry.mapScale + entry.mapOffset
            trianglePositions.append(mapped.x * width)
            trianglePositions.append(-mapped.y * height)
            trianglePositions.append(0)
            let uv = model.vertices[i].uv
            triangleTexCoords.append(uv.x)
            triangleTexCoords.append(uv.y)
        }

        return makeGeometry(
            positions: trianglePositions,
            texCoords: triangleTexCoords,
            device: device,
            offset: anchorOffset
        )
    }

    func makeOffscreenCopyGeometry(
        size: CGSize,
        device: MTLDevice
    ) -> SceneGeometry? {
        let positions = [
            Float(0), Float(size.height), Float(0),
            Float(0), Float(0), Float(0),
            Float(size.width), Float(size.height), Float(0),
            Float(size.width), Float(size.height), Float(0),
            Float(0), Float(0), Float(0),
            Float(size.width), Float(0), Float(0),
        ]
        return makeGeometry(positions: positions, texCoords: quadTexCoords(), device: device)
    }

    func makeOffscreenPassGeometry(
        device: MTLDevice
    ) -> SceneGeometry? {
        let positions = [
            Float(-1), Float(1), Float(0),
            Float(-1), Float(-1), Float(0),
            Float(1), Float(1), Float(0),
            Float(1), Float(1), Float(0),
            Float(-1), Float(-1), Float(0),
            Float(1), Float(-1), Float(0),
        ]
        return makeGeometry(positions: positions, texCoords: quadTexCoords(), device: device)
    }

    private func resolvedSize(for image: ImageDescriptor, scene: SceneDescription, viewportSize: CGSize) -> CGSize {
        if let model = image.model {
            if model.fullscreen {
                let projection = scene.scene?.camera.projection
                let width = projection.map { $0.isAuto || $0.width <= 0 ? Int(viewportSize.width) : $0.width } ?? Int(viewportSize.width)
                let height = projection.map { $0.isAuto || $0.height <= 0 ? Int(viewportSize.height) : $0.height } ?? Int(viewportSize.height)
                return CGSize(width: max(width, 1), height: max(height, 1))
            }

            if let width = model.width, let height = model.height {
                return CGSize(width: width, height: height)
            }
        }

        if image.size.count >= 2, image.size[0] >= 0, image.size[1] >= 0 {
            return CGSize(width: image.size[0], height: image.size[1])
        }

        return CGSize(width: 256, height: 256)
    }

    private func quadPositions(width: CGFloat, height: CGFloat) -> [Float] {
        let halfWidth = Float(width / 2)
        let halfHeight = Float(height / 2)
        return [
            -halfWidth, halfHeight, 0,
            -halfWidth, -halfHeight, 0,
            halfWidth, halfHeight, 0,
            halfWidth, halfHeight, 0,
            -halfWidth, -halfHeight, 0,
            halfWidth, -halfHeight, 0,
        ]
    }

    private func quadTexCoords() -> [Float] {
        [
            0, 0,
            0, 1,
            1, 0,
            1, 0,
            0, 1,
            1, 1,
        ]
    }

    private func makeGeometry(
        positions: [Float],
        texCoords: [Float],
        device: MTLDevice,
        offset: SIMD2<Float> = .zero
    ) -> SceneGeometry? {
        let vertexCount = positions.count / 3
        var positions = positions
        if offset != .zero {
            for index in stride(from: 0, to: vertexCount * 3, by: 3) {
                positions[index] += offset.x
                positions[index + 1] += offset.y
            }
        }
        guard vertexCount > 0, texCoords.count / 2 == vertexCount,
              let positionBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<Float>.stride * positions.count),
              let texCoordBuffer = device.makeBuffer(bytes: texCoords, length: MemoryLayout<Float>.stride * texCoords.count) else {
            return nil
        }

        return SceneGeometry(
            positions: positionBuffer,
            texCoords: texCoordBuffer,
            vertexCount: vertexCount
        )
    }

    private func loadModelGeometry(
        model: ModelDescriptor,
        anchorOffset: SIMD2<Float>,
        device: MTLDevice
    ) -> SceneGeometry? {
        guard let modelURL = resolveModelURL(for: model.filename) else {
            return nil
        }

        let cacheKey = "\(modelURL.path)#anchor:\(anchorOffset.x),\(anchorOffset.y)"
        if let cached = geometryCache[cacheKey] {
            return cached
        }

        guard let objectURL = resolvedObjectURL(for: modelURL),
              let source = try? String(contentsOf: objectURL, encoding: .utf8),
              let mesh = parseOBJ(source) else {
            return nil
        }

        let geometry = makeGeometry(
            positions: mesh.positions,
            texCoords: mesh.texCoords,
            device: device,
            offset: anchorOffset
        )
        if let geometry {
            geometryCache[cacheKey] = geometry
        }
        return geometry
    }

    private func resolveModelURL(for path: String) -> URL? {
        let fileManager = FileManager.default
        for root in assetRoots {
            let candidate = root.appendingPathComponent(path)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func resolvedObjectURL(for modelURL: URL) -> URL? {
        let fileManager = FileManager.default
        if modelURL.pathExtension.lowercased() == "obj" {
            return fileManager.fileExists(atPath: modelURL.path) ? modelURL : nil
        }

        let siblingOBJ = modelURL.deletingPathExtension().appendingPathExtension("obj")
        if fileManager.fileExists(atPath: siblingOBJ.path) {
            return siblingOBJ
        }

        return nil
    }

    private func parseOBJ(_ source: String) -> ParsedMesh? {
        var positions: [SIMD3<Float>] = []
        var texCoords: [SIMD2<Float>] = []
        var trianglePositions: [Float] = []
        var triangleTexCoords: [Float] = []

        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            if line.hasPrefix("v ") {
                let values = line.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Float($0) }
                guard values.count >= 3 else { continue }
                positions.append(SIMD3(values[0], values[1], values[2]))
                continue
            }

            if line.hasPrefix("vt ") {
                let values = line.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Float($0) }
                guard values.count >= 2 else { continue }
                texCoords.append(SIMD2(values[0], values[1]))
                continue
            }

            if line.hasPrefix("f ") {
                let vertices = line.split(whereSeparator: \.isWhitespace).dropFirst()
                guard vertices.count >= 3 else { continue }
                let decoded = vertices.compactMap(decodeFaceVertex)
                guard decoded.count == vertices.count else { continue }
                for index in 1..<(decoded.count - 1) {
                    appendFaceVertex(decoded[0], positions: positions, texCoords: texCoords, trianglePositions: &trianglePositions, triangleTexCoords: &triangleTexCoords)
                    appendFaceVertex(decoded[index], positions: positions, texCoords: texCoords, trianglePositions: &trianglePositions, triangleTexCoords: &triangleTexCoords)
                    appendFaceVertex(decoded[index + 1], positions: positions, texCoords: texCoords, trianglePositions: &trianglePositions, triangleTexCoords: &triangleTexCoords)
                }
            }
        }

        guard !trianglePositions.isEmpty, trianglePositions.count / 3 == triangleTexCoords.count / 2 else {
            return nil
        }

        return ParsedMesh(positions: trianglePositions, texCoords: triangleTexCoords)
    }

    private func decodeFaceVertex(_ token: Substring) -> OBJFaceVertex? {
        let components = token.split(separator: "/", omittingEmptySubsequences: false)
        guard let positionIndex = decodeOBJIndex(components[safe: 0]) else {
            return nil
        }
        let texCoordIndex = decodeOBJIndex(components[safe: 1])
        return OBJFaceVertex(positionIndex: positionIndex, texCoordIndex: texCoordIndex)
    }

    private func decodeOBJIndex(_ token: Substring?) -> Int? {
        guard let token, !token.isEmpty, let raw = Int(token), raw > 0 else {
            return nil
        }
        return raw - 1
    }

    private func appendFaceVertex(
        _ faceVertex: OBJFaceVertex,
        positions: [SIMD3<Float>],
        texCoords: [SIMD2<Float>],
        trianglePositions: inout [Float],
        triangleTexCoords: inout [Float]
    ) {
        guard let position = positions[safe: faceVertex.positionIndex] else {
            return
        }

        trianglePositions.append(position.x)
        trianglePositions.append(position.y)
        trianglePositions.append(position.z)

        let texCoord = faceVertex.texCoordIndex.flatMap { texCoords[safe: $0] } ?? SIMD2<Float>(0, 0)
        triangleTexCoords.append(texCoord.x)
        triangleTexCoords.append(texCoord.y)
    }
}

private struct ParsedMesh {
    let positions: [Float]
    let texCoords: [Float]
}

private struct OBJFaceVertex {
    let positionIndex: Int
    let texCoordIndex: Int?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
