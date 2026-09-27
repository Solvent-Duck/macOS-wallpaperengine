import Foundation
import simd
import NativeSceneCore
import Testing
@testable import NativeSceneRenderer

struct PuppetModelTests {
    @Test(arguments: [0.0, 0.5, 1.0])
    func authoredBindPoseAndAnimatedScalesAreIndependentOfTheFirstClipFrame(blend: Double) throws {
        let vertex = PuppetVertex(position: SIMD2(12, 0), uv: .zero,
                                  boneIndices: SIMD4(repeating: 0), weights: SIMD4(1, 0, 0, 0))
        let bind = PuppetPose(x: 10, y: 0, rotation: 0, scale: SIMD3(2, 1, 1))
        let first = PuppetPose(x: 12, y: 0, rotation: 0, scale: SIMD3(4, 1, 1))
        let last = PuppetPose(x: 14, y: 0, rotation: 0, scale: SIMD3(6, 1, 1))
        let animation = PuppetAnimation(id: 1, name: "stretch", mirrors: false, fps: 1, frames: [[first], [last]])
        let model = PuppetModel(vertices: [vertex], triangles: [],
            bones: [PuppetBone(parent: -1, bindTransform: bind.transform)], animations: [animation])
        let skins = try #require(model.skinTransforms(at: 0.5, animationID: 1, rate: 1, blend: blend))
        let position = try #require(model.deformedPositions(skins: skins).first)
        #expect(abs(position.x - Float(12 + 6 * blend)) < 0.00001)
        #expect(abs(position.y) < 0.00001)
        let start = try #require(model.skinTransforms(at: 0, animationID: 1, rate: 1))
        #expect(abs(model.deformedPositions(skins: start)[0].x - 16) < 0.00001)
    }

    @Test func parentRotationCarriesChildDepthTranslationIntoTheImagePlane() throws {
        let parent = PuppetPose(x: 10, y: 0, rotation: 0, rotationY: .pi / 2)
        let childBind = PuppetPose(x: 0, y: 0, rotation: 0, z: 2)
        let childAnimated = PuppetPose(x: 0, y: 0, rotation: 0, z: 4)
        let vertex = PuppetVertex(position: SIMD2(12, 1), uv: .zero,
                                  boneIndices: SIMD4(repeating: 1), weights: SIMD4(1, 0, 0, 0))
        let animation = PuppetAnimation(id: 1, name: "depth", mirrors: false, fps: 1, frames: [[parent, childAnimated]])
        let model = PuppetModel(vertices: [vertex], triangles: [], bones: [
            PuppetBone(parent: -1, bindTransform: parent.transform),
            PuppetBone(parent: 0, bindTransform: childBind.transform),
        ], animations: [animation])
        let skins = try #require(model.skinTransforms(at: 0, animationID: 1, rate: 1))
        let position = try #require(model.deformedPositions(skins: skins).first)
        #expect(abs(position.x - 14) < 0.00001)
        #expect(abs(position.y - 1) < 0.00001)
    }

    @Test(arguments: [Float(0), 1, -1])
    func rotationAndSignedScaleIncludeVertexDepth(scale: Float) throws {
        let vertex = PuppetVertex(position: SIMD2(1, 2), uv: .zero,
                                  boneIndices: SIMD4(repeating: 0), weights: SIMD4(1, 0, 0, 0), depth: 3)
        let pose = PuppetPose(x: 0, y: 0, rotation: 0, rotationX: .pi / 2, scale: SIMD3(1, 1, scale))
        let animation = PuppetAnimation(id: 1, name: "turn", mirrors: false, fps: 1, frames: [[pose]])
        let model = PuppetModel(vertices: [vertex], triangles: [], bones: [PuppetBone(parent: -1)], animations: [animation])
        let skins = try #require(model.skinTransforms(at: 0, animationID: 1, rate: 1))
        let position = try #require(model.deformedPositions(skins: skins).first)
        #expect(abs(position.x - 1) < 0.00001)
        #expect(abs(position.y + 3 * scale) < 0.00001)
        let half = try #require(model.skinTransforms(at: 0, animationID: 1, rate: 1, blend: 0.5))
        let halfPosition = model.deformedPositions(skins: half)[0]
        #expect(abs(halfPosition.y - sqrt(0.5) * (2 - 3 * (1 + scale) / 2)) < 0.00001)
    }

    @Test func fractionalAnimationBlendInterpolatesTheBonePoseBeforeSkinning() throws {
        let vertex = PuppetVertex(position: SIMD2(1, 0), uv: .zero,
                                  boneIndices: SIMD4(repeating: 0), weights: SIMD4(1, 0, 0, 0))
        let animation = PuppetAnimation(id: 1, name: "turn", mirrors: false, fps: 1,
            frames: [[.identity], [PuppetPose(x: 0, y: 0, rotation: .pi)]])
        let model = PuppetModel(vertices: [vertex], triangles: [], bones: [PuppetBone(parent: -1)], animations: [animation])
        let skins = try #require(model.skinTransforms(at: 0.5, animationID: 1, rate: 1, blend: 0.5))
        let position = try #require(model.deformedPositions(skins: skins).first)
        // Half of a quarter-turn remains on the unit circle. Blending the
        // already skinned vertices would incorrectly shrink the mesh.
        #expect(abs(position.x - sqrt(0.5)) < 0.00001)
        #expect(abs(position.y - sqrt(0.5)) < 0.00001)
    }

    @Test func extendedVerticesUseAllFourUInt32BoneIndices() throws {
        // MDLV0021 records in GreatWhite/Waves contain normal + tangent data,
        // then four uint32 indices at byte 40 (not four bytes at byte 52).
        var data = Data("MDLV0021\0".utf8)
        func uint(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { uint(value.bitPattern) }
        uint(0x0180_000F); uint(1); uint(1)
        data.append(Data("materials/mesh.json\0".utf8))
        uint(0)
        for value: Float in [0, 0, 0, 100, 100, 100] { scalar(value) }
        uint(0x0180_000F); uint(3 * 80)
        for uv: SIMD2<Float> in [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)] {
            for value: Float in [10, 20, 30, 0, 0, 1, 1, 0, 0, -1] { scalar(value) }
            for index: UInt32 in [1, 2, 3, 0] { uint(index) }
            for weight: Float in [0.25, 0.75, 0, 0] { scalar(weight) }
            scalar(uv.x); scalar(uv.y)
        }
        uint(6)
        data.append(contentsOf: [0, 0, 1, 0, 2, 0, 0, 0])
        let model = try PuppetModelDecoder.decode(data)
        #expect(model.vertices.count == 3)
        #expect(model.triangles == [0, 1, 2])
        #expect(model.vertices[0].boneIndices == SIMD4(1, 2, 3, 0))
        #expect(model.vertices[0].weights == SIMD4(0.25, 0.75, 0, 0))
        #expect(model.vertices[0].depth == 30)
        let positions = model.deformedPositions(skins: [
            matrix_identity_float4x4, PuppetPose(x: 20, y: 0, rotation: 0).transform,
            PuppetPose(x: 0, y: 40, rotation: 0).transform, matrix_identity_float4x4,
        ])
        #expect(positions.allSatisfy { $0 == SIMD2(15, 50) })
    }
}
