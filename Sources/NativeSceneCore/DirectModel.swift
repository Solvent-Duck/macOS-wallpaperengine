import Foundation
import simd

/// Geometry shared by static and skinned 3D MDLV model sections. Unlike image
/// puppets, these positions stay in model space and are not fitted to a quad.
public struct DirectModelVertex: Sendable {
    public let position: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let tangent: SIMD4<Float>
    public let uv: SIMD2<Float>
    public let boneIndices: SIMD4<UInt32>
    public let weights: SIMD4<Float>
}

public struct DirectModelMesh: Sendable {
    public let material: String
    public let vertices: [DirectModelVertex]
    public let indices: [UInt16]
    public let skinned: Bool
}

public enum DirectModelError: Error, LocalizedError {
    case malformed(String)
    public var errorDescription: String? {
        switch self { case .malformed(let reason): return "Invalid 3D model: \(reason)" }
    }
}

public enum DirectModelDecoder {
    /// MDLV0014 stores its vertex layout in the file header. Later versions
    /// add bounds and a layout to each material's mesh section.
    public static func decode(_ data: Data) throws -> [DirectModelMesh] {
        var reader = Reader(data: [UInt8](data))
        let magic = try reader.string()
        guard ["MDLV0014", "MDLV0019", "MDLV0021", "MDLV0023"].contains(magic),
              let version = Int(magic.suffix(4)) else { throw DirectModelError.malformed("unsupported version \(magic)") }
        let fileLayout = try reader.uint32()
        _ = try reader.uint32()
        let count = Int(try reader.uint32())
        guard count > 0, count <= 4096 else { throw DirectModelError.malformed("mesh count \(count)") }
        var meshes: [DirectModelMesh] = []
        for _ in 0..<count {
            let material = try reader.string()
            guard !material.isEmpty else { throw DirectModelError.malformed("missing material") }
            _ = try reader.uint32()
            let layout: UInt32
            if version == 14 {
                layout = fileLayout
            } else {
                for _ in 0..<6 { _ = try reader.float() } // Model-space bounds.
                layout = try reader.uint32()
            }
            guard layout == 0xF || layout == 0x0180_000F else {
                throw DirectModelError.malformed("unsupported vertex layout \(layout)")
            }
            let skinned = layout == 0x0180_000F
            let stride = skinned ? 80 : 48
            let bytes = Int(try reader.uint32())
            guard bytes > 0, bytes % stride == 0, bytes <= reader.remaining else {
                throw DirectModelError.malformed("vertex buffer length")
            }
            var vertices: [DirectModelVertex] = []
            vertices.reserveCapacity(bytes / stride)
            for _ in 0..<bytes / stride {
                let position = try reader.vector3()
                let normal = try reader.vector3()
                let tangent = try reader.vector4()
                let bones = skinned ? try SIMD4(reader.uint32(), reader.uint32(), reader.uint32(), reader.uint32()) : .zero
                let weights = skinned ? try reader.vector4() : .zero
                let uv = try SIMD2(reader.float(), reader.float())
                vertices.append(DirectModelVertex(position: position, normal: normal, tangent: tangent,
                                                  uv: uv, boneIndices: bones, weights: weights))
            }
            let indexBytes = Int(try reader.uint32())
            guard indexBytes > 0, indexBytes % 6 == 0, indexBytes <= reader.remaining else {
                throw DirectModelError.malformed("triangle index buffer length")
            }
            var indices: [UInt16] = []
            indices.reserveCapacity(indexBytes / 2)
            for _ in 0..<indexBytes / 2 {
                let index = try reader.uint16()
                guard Int(index) < vertices.count else { throw DirectModelError.malformed("vertex index out of range") }
                indices.append(index)
            }
            // Empty optional mesh metadata in all ten eligible direct models.
            // Do not mistake nonempty metadata for a following material path.
            for _ in 0..<(version == 23 ? 6 : version == 21 ? 2 : 0) {
                guard try reader.byte() == 0 else { throw DirectModelError.malformed("unsupported mesh metadata") }
            }
            meshes.append(DirectModelMesh(material: material, vertices: vertices, indices: indices, skinned: skinned))
        }
        return meshes
    }

    private struct Reader {
        let data: [UInt8]
        var offset = 0
        var remaining: Int { data.count - offset }
        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw DirectModelError.malformed("truncated buffer") }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func uint16() throws -> UInt16 { try UInt16(byte()) | UInt16(byte()) << 8 }
        mutating func uint32() throws -> UInt32 { try UInt32(uint16()) | UInt32(uint16()) << 16 }
        mutating func float() throws -> Float {
            let value = Float(bitPattern: try uint32())
            guard value.isFinite else { throw DirectModelError.malformed("non-finite vertex or bounds") }
            return value
        }
        mutating func vector3() throws -> SIMD3<Float> { try SIMD3(float(), float(), float()) }
        mutating func vector4() throws -> SIMD4<Float> { try SIMD4(float(), float(), float(), float()) }
        mutating func string() throws -> String {
            guard let end = data[offset...].firstIndex(of: 0), end - offset <= 16_384,
                  let value = String(bytes: data[offset..<end], encoding: .utf8) else {
                throw DirectModelError.malformed("unterminated or invalid string")
            }
            offset = end + 1
            return value
        }
    }
}
