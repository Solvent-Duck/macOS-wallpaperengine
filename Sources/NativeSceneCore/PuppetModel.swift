import Foundation
import simd

/// Wallpaper Engine puppet-warp model (`*_puppet.mdl`): a 2D skinned mesh with
/// bone-frame animations, played back with CPU skinning.
///
/// Format knowledge: MDLV0013 structure adapted from the MIT-licensed
/// workshop-wallpaper-bridge project (© 2026 3xhaust); the MDLV0014–0023
/// variants (typed vertex-block tags, u16/u8/80-byte vertex layouts, bone
/// name strings, submesh footer tables, animation separators) were
/// reverse-engineered against the local 346-model workshop corpus.
public struct PuppetVertex: Sendable {
    public init(position: SIMD2<Float>, uv: SIMD2<Float>, boneIndices: SIMD4<Int32>, weights: SIMD4<Float>, depth: Float = 0) {
        self.position = position; self.uv = uv; self.boneIndices = boneIndices; self.weights = weights; self.depth = depth
    }

    public let position: SIMD2<Float>
    public let uv: SIMD2<Float>
    public let boneIndices: SIMD4<Int32>
    public let weights: SIMD4<Float>
    public var depth: Float = 0
}

public struct PuppetBone: Sendable {
    public init(parent: Int, bindTransform: simd_float4x4 = matrix_identity_float4x4) {
        self.parent = parent; self.bindTransform = bindTransform
    }

    public let parent: Int
    public var bindTransform: simd_float4x4 = matrix_identity_float4x4
}

public struct PuppetPose: Sendable {
    public init(x: Float, y: Float, rotation: Float, z: Float = 0, rotationX: Float = 0, rotationY: Float = 0, scale: SIMD3<Float> = SIMD3(repeating: 1)) {
        self.x = x; self.y = y; self.rotation = rotation; self.z = z
        self.rotationX = rotationX; self.rotationY = rotationY; self.scale = scale
    }

    public let x: Float
    public let y: Float
    public let rotation: Float
    public var z: Float = 0
    public var rotationX: Float = 0
    public var rotationY: Float = 0
    public var scale: SIMD3<Float> = SIMD3(repeating: 1)

    public static let identity = PuppetPose(x: 0, y: 0, rotation: 0)

    public var orientation: simd_quatf {
        simd_quatf(angle: rotation, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: rotationY, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: rotationX, axis: SIMD3(1, 0, 0))
    }

    public var transform: simd_float4x4 {
        Self.transform(position: SIMD3(x, y, z), orientation: orientation, scale: scale)
    }

    public static func transform(position: SIMD3<Float>, orientation: simd_quatf, scale: SIMD3<Float>) -> simd_float4x4 {
        var matrix = simd_float4x4(orientation)
        matrix.columns.0 *= scale.x
        matrix.columns.1 *= scale.y
        matrix.columns.2 *= scale.z
        matrix.columns.3 = SIMD4(position, 1)
        return matrix
    }

    public func interpolated(to end: PuppetPose, amount: Float) -> PuppetPose {
        PuppetPose(x: x + (end.x - x) * amount,
                   y: y + (end.y - y) * amount,
                   rotation: rotation + (end.rotation - rotation) * amount,
                   z: z + (end.z - z) * amount,
                   rotationX: rotationX + (end.rotationX - rotationX) * amount,
                   rotationY: rotationY + (end.rotationY - rotationY) * amount,
                   scale: scale + (end.scale - scale) * amount)
    }
}

public struct PuppetAnimation: Sendable {
    public enum PlaybackMode: String, Sendable { case loop, mirror, single }

    public init(id: Int, name: String, mirrors: Bool, fps: Float, frames: [[PuppetPose]], mode: PlaybackMode? = nil) {
        self.id = id; self.name = name; self.mode = mode ?? (mirrors ? .mirror : .loop)
        self.fps = fps; self.frames = frames
    }

    public let id: Int
    public let name: String
    public let mode: PlaybackMode
    public var mirrors: Bool { mode == .mirror }
    public let fps: Float
    /// frames[frame][bone]
    public let frames: [[PuppetPose]]
    /// MDLA tracks include a sample at both frame zero and the declared end.
    public var frameCount: Int { max(0, frames.count - 1) }
    public var duration: Double { fps > 0 ? Double(frameCount) / Double(fps) : 0 }

    public func frame(atPhase phase: Double) -> Double {
        let span = Double(frameCount)
        guard span > 0, phase.isFinite else { return 0 }
        switch mode {
        case .single: return min(span, max(0, phase))
        case .loop: return Self.positiveRemainder(phase, span)
        case .mirror:
            let cycle = Self.positiveRemainder(phase, span * 2)
            return cycle <= span ? cycle : span * 2 - cycle
        }
    }

    /// Applies the authored playback mode when no runtime layer clock exists.
    public func poses(at time: Double, rate: Double) -> [PuppetPose] {
        poses(atFrame: frame(atPhase: time * Double(max(fps, 0.01)) * rate))
    }

    /// Samples an explicit runtime frame without wrapping a sought endpoint.
    public func poses(atFrame frame: Double) -> [PuppetPose] {
        guard let first = frames.first else {
            return []
        }
        guard frames.count > 1 else {
            return first
        }
        let position = frame.isFinite ? min(Double(frameCount), max(0, frame)) : 0
        let lower = min(Int(position), frames.count - 2)
        let upper = lower + 1
        let fraction = Float(position - Double(lower))
        return zip(frames[lower], frames[upper]).map { start, end in
            start.interpolated(to: end, amount: fraction)
        }
    }

    private static func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

public struct PuppetAttachment: Sendable {
    public let name: String
    public let bone: Int
    public let localTransform: simd_float4x4
}

public struct PuppetModel: Sendable {
    public init(vertices: [PuppetVertex], triangles: [UInt16], bones: [PuppetBone], animations: [PuppetAnimation], attachments: [PuppetAttachment] = []) {
        self.vertices = vertices; self.triangles = triangles; self.bones = bones; self.animations = animations; self.attachments = attachments
    }

    public let vertices: [PuppetVertex]
    public let triangles: [UInt16]
    public let bones: [PuppetBone]
    public let animations: [PuppetAnimation]
    public let attachments: [PuppetAttachment]

    public func animation(withID id: Int?) -> PuppetAnimation? {
        guard let id else {
            return animations.first
        }
        return animations.first { $0.id == id } ?? animations.first
    }

    /// World transforms follow the model's parent-ordered bone table.
    private func worldTransforms(for local: [simd_float4x4]) -> [simd_float4x4] {
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
        for index in bones.indices {
            let transform = index < local.count ? local[index] : bones[index].bindTransform
            let parent = bones[index].parent
            world[index] = parent >= 0 && parent < index ? world[parent] * transform : transform
        }
        return world
    }

    /// Blend local translation, rotation and scale before following parents.
    /// Matrix interpolation would shrink rotating limbs; using a clip's first
    /// frame as the bind pose would erase poses authored at its beginning.
    private func blend(_ animated: PuppetPose, from bind: simd_float4x4, amount: Float) -> simd_float4x4 {
        if amount <= 0 { return bind }
        if amount >= 1 { return animated.transform }
        func components(_ matrix: simd_float4x4) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>) {
            func xyz(_ value: SIMD4<Float>) -> SIMD3<Float> { SIMD3(value.x, value.y, value.z) }
            let x = xyz(matrix.columns.0), y = xyz(matrix.columns.1), z = xyz(matrix.columns.2)
            var scale = SIMD3(simd_length(x), simd_length(y), simd_length(z))
            if simd_dot(simd_cross(x, y), z) < 0 { scale.x = -scale.x }
            let rotation = simd_float3x3(columns: (
                abs(scale.x) > 1e-8 ? x / scale.x : SIMD3(1, 0, 0),
                abs(scale.y) > 1e-8 ? y / scale.y : SIMD3(0, 1, 0),
                abs(scale.z) > 1e-8 ? z / scale.z : SIMD3(0, 0, 1)))
            return (xyz(matrix.columns.3), simd_quatf(rotation), scale)
        }
        let (bindPosition, bindRotation, bindScale) = components(bind)
        let position = SIMD3(animated.x, animated.y, animated.z)
        return PuppetPose.transform(position: bindPosition + (position - bindPosition) * amount,
                                    orientation: simd_slerp(bindRotation, animated.orientation, amount),
                                    scale: bindScale + (animated.scale - bindScale) * amount)
    }

    public var bindWorldTransforms: [simd_float4x4] {
        worldTransforms(for: bones.map(\.bindTransform))
    }

    /// Pose transforms in model coordinates, shared by skinning and attachments.
    public func boneTransforms(at time: Double, animationID: Int?, rate: Double, blend: Double = 1, frame: Double? = nil) -> [simd_float4x4] {
        guard let animation = animation(withID: animationID) else {
            return bindWorldTransforms
        }
        let amount = Float(min(max(blend, 0), 1))
        let sampled = frame.map { animation.poses(atFrame: $0) } ?? animation.poses(at: time, rate: rate)
        let local = bones.indices.map { index in
            let bind = bones[index].bindTransform
            guard index < sampled.count else { return bind }
            return self.blend(sampled[index], from: bind, amount: amount)
        }
        return worldTransforms(for: local)
    }

    /// Bone matrices map the stored mesh bind pose into the animated pose.
    public func skinTransforms(at time: Double, animationID: Int?, rate: Double, blend: Double = 1, frame: Double? = nil) -> [simd_float4x4]? {
        guard !bones.isEmpty else { return nil }
        return zip(boneTransforms(at: time, animationID: animationID, rate: rate, blend: blend, frame: frame), bindWorldTransforms).map { animated, bind in
            abs(simd_determinant(bind)) > 1e-12 ? animated * simd_inverse(bind) : matrix_identity_float4x4
        }
    }

    /// Applies CPU skinning, returning deformed positions per vertex.
    public func deformedPositions(skins: [simd_float4x4]) -> [SIMD2<Float>] {
        vertices.map { vertex in
            var accumulated = SIMD2<Float>(0, 0)
            var totalWeight: Float = 0
            for slot in 0..<4 {
                let weight = vertex.weights[slot]
                guard weight > 0.0001 else {
                    continue
                }
                let bone = Int(vertex.boneIndices[slot])
                guard bone >= 0, bone < skins.count else {
                    continue
                }
                let position = skins[bone] * SIMD4(vertex.position.x, vertex.position.y, vertex.depth, 1)
                accumulated += SIMD2(position.x, position.y) * weight
                totalWeight += weight
            }
            if totalWeight < 0.0001 {
                return vertex.position
            }
            return accumulated / totalWeight
        }
    }
}

public enum PuppetModelError: Error, LocalizedError {
    case unsupportedMagic(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMagic(let magic):
            return "Unsupported puppet container: \(magic)"
        case .malformed(let reason):
            return "Malformed puppet model: \(reason)"
        }
    }
}

public enum PuppetModelDecoder {
    private struct Reader {
        let data: [UInt8]
        var offset = 0

        init(_ data: Data) {
            self.data = [UInt8](data)
        }

        var remaining: Int { data.count - offset }

        mutating func skip(_ count: Int) throws {
            guard remaining >= count else {
                throw PuppetModelError.malformed("truncated at \(offset)")
            }
            offset += count
        }

        mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard remaining >= count else {
                throw PuppetModelError.malformed("truncated at \(offset)")
            }
            defer { offset += count }
            return data[offset..<offset + count]
        }

        func peekUInt32(at position: Int) -> UInt32? {
            guard position >= 0, position + 4 <= data.count else {
                return nil
            }
            return UInt32(data[position])
                | (UInt32(data[position + 1]) << 8)
                | (UInt32(data[position + 2]) << 16)
                | (UInt32(data[position + 3]) << 24)
        }

        mutating func uint32() throws -> UInt32 {
            guard let value = peekUInt32(at: offset) else {
                throw PuppetModelError.malformed("truncated u32 at \(offset)")
            }
            offset += 4
            return value
        }

        mutating func uint16() throws -> UInt16 {
            let value = try bytes(2)
            return UInt16(value[value.startIndex]) | (UInt16(value[value.startIndex + 1]) << 8)
        }

        mutating func int32() throws -> Int32 {
            Int32(bitPattern: try uint32())
        }

        mutating func float() throws -> Float {
            Float(bitPattern: try uint32())
        }

        mutating func cString() throws -> String {
            guard let terminator = data[offset...].firstIndex(of: 0) else {
                throw PuppetModelError.malformed("unterminated string at \(offset)")
            }
            let value = String(decoding: data[offset..<terminator], as: UTF8.self)
            offset = terminator + 1
            return value
        }

        func peekByte() -> UInt8? {
            offset < data.count ? data[offset] : nil
        }

        func find(_ pattern: [UInt8], from: Int = 0) -> Int? {
            guard !pattern.isEmpty, data.count >= pattern.count else {
                return nil
            }
            var index = from
            while index <= data.count - pattern.count {
                if data[index] == pattern[0],
                   data[index..<index + pattern.count].elementsEqual(pattern) {
                    return index
                }
                index += 1
            }
            return nil
        }

        func isAnimationSection(at position: Int) -> Bool {
            guard position >= 0, position <= data.count - 17,
                  data[position..<position + 4].elementsEqual(Array("MDLA".utf8)),
                  data[position + 4..<position + 8].allSatisfy({ (48...57).contains($0) }),
                  data[position + 8] == 0,
                  let end = peekUInt32(at: position + 9),
                  end == 0 || (Int(end) >= position + 17 && Int(end) <= data.count),
                  let count = peekUInt32(at: position + 13), count <= 256 else { return false }
            return true
        }

        func findAnimationSection(from position: Int) -> Int? {
            var start = position
            while let candidate = find(Array("MDLA".utf8), from: start) {
                if isAnimationSection(at: candidate) { return candidate }
                start = candidate + 4
            }
            return nil
        }

        /// Clip trailers contain versioned metadata and optional channel data.
        /// Validate the entire following track table rather than mistaking an
        /// embedded integer/string for another clip or assuming a fixed trailer.
        func isAnimationClip(at position: Int, boneCount: Int, sectionEnd: Int) -> Bool {
            guard position >= 0, position + 8 < sectionEnd,
                  peekUInt32(at: position + 4) == 0 else { return false }
            var cursor = position + 8
            func string() -> String? {
                guard cursor < sectionEnd,
                      let end = data[cursor..<min(cursor + 1024, sectionEnd)].firstIndex(of: 0),
                      let value = String(bytes: data[cursor..<end], encoding: .utf8),
                      !value.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
                cursor = end + 1
                return value
            }
            guard string() != nil, let mode = string(),
                  ["", "loop", "mirror", "single"].contains(mode.lowercased()),
                  cursor + 16 <= sectionEnd,
                  let fpsBits = peekUInt32(at: cursor),
                  Float(bitPattern: fpsBits).isFinite,
                  Float(bitPattern: fpsBits) > 0,
                  let frames = peekUInt32(at: cursor + 4), frames <= 65_536,
                  peekUInt32(at: cursor + 12) == UInt32(boneCount) else { return false }
            cursor += 16
            for _ in 0..<boneCount {
                guard cursor + 8 <= sectionEnd,
                      let size = peekUInt32(at: cursor + 4),
                      size > 0, size % 36 == 0, size / 36 <= 65_536,
                      Int(size) <= sectionEnd - cursor - 8 else { return false }
                cursor += 8 + Int(size)
            }
            return true
        }

        func findAnimationClip(from position: Int, boneCount: Int, sectionEnd: Int) -> Int? {
            guard position < sectionEnd else { return nil }
            for candidate in position..<sectionEnd {
                if isAnimationClip(at: candidate, boneCount: boneCount, sectionEnd: sectionEnd) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// (stride, index element size in bytes, index offset, weight offset, uv offset)
    private static let vertexLayouts: [(stride: Int, indexBytes: Int, indexOffset: Int, weightOffset: Int, uvOffset: Int)] = [
        (52, 4, 12, 28, 44),
        (44, 2, 12, 20, 36),
        (40, 1, 12, 16, 32),
        // Position + normal + tangent/handedness occupy the first 40 bytes.
        // The four bone indices are uint32s, followed by weights and UVs.
        (80, 4, 40, 56, 72),
    ]

    public static func decode(_ data: Data) throws -> PuppetModel {
        var reader = Reader(data)
        let magicBytes = try reader.bytes(8)
        let magic = String(decoding: magicBytes, as: UTF8.self)
        guard magic.hasPrefix("MDLV") else {
            throw PuppetModelError.unsupportedMagic(magic)
        }
        try reader.skip(1)
        _ = try reader.uint32()   // type tag
        _ = try reader.uint32()   // flags
        _ = try reader.uint32()   // material count
        _ = try reader.cString()  // material path

        let mdlsOffset = reader.find(Array("MDLS".utf8))
        let dataCount = reader.data.count

        // Locate the vertex block: prefer offsets right after a typed tag,
        // fall back to a brute scan. Validate against the index block that
        // must land before the skeleton section.
        var candidates: [Int] = []
        let scanEnd = min(reader.offset + 160, dataCount - 8)
        var probe = reader.offset
        while probe < scanEnd {
            if let tag = reader.peekUInt32(at: probe), tag == 0x0180_0009 || tag == 0x0180_000F {
                candidates.append(probe + 4)
            }
            probe += 1
        }
        candidates.append(contentsOf: Array(reader.offset..<max(reader.offset, scanEnd)))

        var parsed: (vertices: [PuppetVertex], triangles: [UInt16])?
        var visited = Set<Int>()
        for candidate in candidates where !visited.contains(candidate) {
            visited.insert(candidate)
            guard let vertexBytes = reader.peekUInt32(at: candidate).map(Int.init),
                  vertexBytes > 0,
                  candidate + 4 + vertexBytes + 4 <= dataCount,
                  let indexBytes = reader.peekUInt32(at: candidate + 4 + vertexBytes).map(Int.init),
                  indexBytes % 2 == 0,
                  candidate + 8 + vertexBytes + indexBytes <= dataCount else {
                continue
            }
            if let mdlsOffset, candidate + 8 + vertexBytes + indexBytes > mdlsOffset {
                continue
            }
            if let result = tryParseVertices(
                reader: reader,
                start: candidate + 4,
                vertexBytes: vertexBytes,
                indexBytes: indexBytes
            ) {
                parsed = result
                break
            }
        }

        guard let parsed else {
            throw PuppetModelError.malformed("vertex block not found")
        }

        guard let mdlsOffset else {
            return PuppetModel(vertices: parsed.vertices, triangles: parsed.triangles, bones: [], animations: [])
        }

        // Skeleton (a submesh footer table may sit between indices and MDLS).
        reader.offset = mdlsOffset
        _ = try reader.bytes(8)   // MDLSxxxx
        try reader.skip(1)
        let skeletonEnd = Int(try reader.uint32())
        let boneCount = Int(try reader.uint32())
        guard boneCount >= 0, boneCount <= 1024 else {
            throw PuppetModelError.malformed("bone count \(boneCount)")
        }
        var bones: [PuppetBone] = []
        bones.reserveCapacity(boneCount)
        for _ in 0..<boneCount {
            _ = try reader.cString()          // bone name, usually empty
            _ = try reader.uint32()           // tag (1)
            let parent = Int(try reader.int32())
            let matrixBytes = Int(try reader.uint32())
            guard matrixBytes == 64 else {
                throw PuppetModelError.malformed("bone matrix bytes \(matrixBytes) at \(reader.offset)")
            }
            var matrix = matrix_identity_float4x4
            for column in 0..<4 {
                for row in 0..<4 { matrix[column][row] = try reader.float() }
            }
            _ = try reader.cString()          // per-bone constraint JSON
            bones.append(PuppetBone(parent: parent, bindTransform: matrix))
        }

        var attachments: [PuppetAttachment] = []
        let animationOffset = reader.findAnimationSection(from: reader.offset)
        if let offset = reader.find(Array("MDAT0001\0".utf8), from: reader.offset),
           offset < (animationOffset ?? dataCount) {
            var attachmentReader = reader
            attachmentReader.offset = offset + 9
            let end = Int(try attachmentReader.uint32())
            let count = Int(try attachmentReader.uint16())
            guard end >= attachmentReader.offset, end <= dataCount else {
                throw PuppetModelError.malformed("attachment section boundary")
            }
            for _ in 0..<count {
                let bone = Int(try attachmentReader.uint16())
                let name = try attachmentReader.cString()
                guard attachmentReader.offset + 64 <= end,
                      bone < boneCount || bone == Int(UInt16.max) else {
                    throw PuppetModelError.malformed("attachment bone or matrix")
                }
                var matrix = matrix_identity_float4x4
                for column in 0..<4 {
                    for row in 0..<4 { matrix[column][row] = try attachmentReader.float() }
                }
                attachments.append(PuppetAttachment(name: name, bone: bone, localTransform: matrix))
            }
        }

        var animations: [PuppetAnimation] = []
        // MDLV0023 can append bone controllers, constraints, and intervening
        // sections after the bone records. Prefer the declared boundary, then
        // locate a validated animation header beyond that metadata.
        if skeletonEnd >= reader.offset, reader.isAnimationSection(at: skeletonEnd) {
            reader.offset = skeletonEnd
        } else if let animationOffset = reader.findAnimationSection(from: reader.offset) {
            reader.offset = animationOffset
        }
        if reader.isAnimationSection(at: reader.offset) {
            let animMagic = String(decoding: try reader.bytes(8), as: UTF8.self)
            if animMagic.hasPrefix("MDLA") {
                let animationVersion = Int(animMagic.dropFirst(4)) ?? 0
                try reader.skip(1)
                let declaredEnd = Int(try reader.uint32())
                let sectionEnd = declaredEnd == 0 ? reader.data.count : declaredEnd
                let animationCount = Int(try reader.uint32())
                guard animationCount >= 0, animationCount <= 256 else {
                    throw PuppetModelError.malformed("animation count \(animationCount)")
                }
                for clipIndex in 0..<animationCount {
                    let id = Int(try reader.uint32())
                    _ = try reader.uint32()
                    let name = try reader.cString()
                    let mode = try reader.cString()
                    let fps = try reader.float()
                    _ = try reader.uint32()   // declared frame count
                    _ = try reader.uint32()
                    let trackCount = Int(try reader.uint32())
                    guard trackCount == boneCount else {
                        throw PuppetModelError.malformed("track count \(trackCount) != bones \(boneCount)")
                    }
                    var tracks: [[PuppetPose]] = []
                    tracks.reserveCapacity(trackCount)
                    for _ in 0..<trackCount {
                        _ = try reader.uint32()               // per-track tag
                        let trackBytes = Int(try reader.uint32())
                        guard trackBytes % 36 == 0, trackBytes / 36 <= 65_536,
                              trackBytes <= sectionEnd - reader.offset else {
                            throw PuppetModelError.malformed("track bytes \(trackBytes)")
                        }
                        var poses: [PuppetPose] = []
                        poses.reserveCapacity(trackBytes / 36)
                        for _ in 0..<(trackBytes / 36) {
                            let tx = try reader.float()
                            let ty = try reader.float()
                            let tz = try reader.float()
                            let rx = try reader.float()
                            let ry = try reader.float()
                            let rz = try reader.float()
                            let sx = try reader.float()
                            let sy = try reader.float()
                            let sz = try reader.float()
                            poses.append(PuppetPose(x: tx, y: ty, rotation: rz, z: tz,
                                                    rotationX: rx, rotationY: ry, scale: SIMD3(sx, sy, sz)))
                        }
                        tracks.append(poses)
                    }
                    if clipIndex + 1 < animationCount {
                        // Minimum records observed in MDLA0001–0006. Optional
                        // opacity/channel data and imported sequence metadata
                        // can extend them substantially (including >190KB).
                        let minimumTrailer: Int
                        switch animationVersion {
                        case 1, 2: minimumTrailer = 4
                        case 3: minimumTrailer = 9
                        case 4: minimumTrailer = 10
                        case 5: minimumTrailer = 34
                        case 6: minimumTrailer = 35
                        default: minimumTrailer = 0
                        }
                        guard let next = reader.findAnimationClip(from: reader.offset + minimumTrailer,
                                                                  boneCount: boneCount, sectionEnd: sectionEnd) else {
                            throw PuppetModelError.malformed("animation \(clipIndex + 1) header not found")
                        }
                        reader.offset = next
                    }
                    let frameCount = tracks.map(\.count).min() ?? 0
                    guard frameCount > 0 else {
                        continue
                    }
                    let frames = (0..<frameCount).map { frame in
                        tracks.map { $0[frame] }
                    }
                    animations.append(
                        PuppetAnimation(
                            id: id,
                            name: name,
                            mirrors: mode.lowercased() == "mirror",
                            fps: fps > 0 ? fps : 30,
                            frames: frames,
                            mode: PuppetAnimation.PlaybackMode(rawValue: mode.lowercased()) ?? .loop
                        )
                    )
                }
            }
        }

        return PuppetModel(
            vertices: parsed.vertices,
            triangles: parsed.triangles,
            bones: bones,
            animations: animations,
            attachments: attachments
        )
    }

    private static func tryParseVertices(
        reader: Reader,
        start: Int,
        vertexBytes: Int,
        indexBytes: Int
    ) -> (vertices: [PuppetVertex], triangles: [UInt16])? {
        var best: (quality: Double, vertices: [PuppetVertex], triangles: [UInt16])?

        for layout in vertexLayouts {
            guard vertexBytes % layout.stride == 0 else {
                continue
            }
            let vertexCount = vertexBytes / layout.stride
            guard vertexCount > 0, vertexCount <= 200_000 else {
                continue
            }

            let indexStart = start + vertexBytes + 4
            let indexCount = indexBytes / 2
            var triangles = [UInt16](repeating: 0, count: indexCount)
            var maxIndex: UInt16 = 0
            for i in 0..<indexCount {
                let position = indexStart + i * 2
                let value = UInt16(reader.data[position]) | (UInt16(reader.data[position + 1]) << 8)
                triangles[i] = value
                maxIndex = max(maxIndex, value)
            }
            if indexCount > 0, Int(maxIndex) >= vertexCount {
                continue
            }

            var vertices: [PuppetVertex] = []
            vertices.reserveCapacity(vertexCount)
            var score = 0
            var valid = true
            for i in 0..<vertexCount {
                let base = start + i * layout.stride
                guard let xBits = reader.peekUInt32(at: base),
                      let yBits = reader.peekUInt32(at: base + 4) else {
                    valid = false
                    break
                }
                let x = Float(bitPattern: xBits)
                let y = Float(bitPattern: yBits)
                guard abs(x) < 1e6, abs(y) < 1e6 else {
                    valid = false
                    break
                }

                var indices = SIMD4<Int32>(repeating: 0)
                for slot in 0..<4 {
                    let position = base + layout.indexOffset + slot * layout.indexBytes
                    switch layout.indexBytes {
                    case 4:
                        indices[slot] = Int32(bitPattern: reader.peekUInt32(at: position) ?? 0)
                    case 2:
                        indices[slot] = Int32(
                            UInt16(reader.data[position]) | (UInt16(reader.data[position + 1]) << 8)
                        )
                    default:
                        indices[slot] = Int32(reader.data[position])
                    }
                }

                var weights = SIMD4<Float>(repeating: 0)
                for slot in 0..<4 {
                    weights[slot] = Float(bitPattern: reader.peekUInt32(at: base + layout.weightOffset + slot * 4) ?? 0)
                }
                let u = Float(bitPattern: reader.peekUInt32(at: base + layout.uvOffset) ?? 0)
                let v = Float(bitPattern: reader.peekUInt32(at: base + layout.uvOffset + 4) ?? 0)

                let weightSum = weights.sum()
                if weightSum > 0.9, weightSum < 1.1 {
                    score += 1
                }
                if u >= -0.05, u <= 1.05, v >= -0.05, v <= 1.05 {
                    score += 1
                }

                vertices.append(
                    PuppetVertex(
                        position: SIMD2<Float>(x, y),
                        uv: SIMD2<Float>(u, v),
                        boneIndices: indices,
                        weights: weights,
                        depth: Float(bitPattern: reader.peekUInt32(at: base + 8) ?? 0)
                    )
                )
            }
            guard valid else {
                continue
            }
            let quality = Double(score) / Double(2 * vertexCount)
            if best == nil || quality > best!.quality {
                best = (quality, vertices, triangles)
            }
        }

        guard let best, best.quality > 0.5 else {
            return nil
        }
        return (best.vertices, best.triangles)
    }
}
