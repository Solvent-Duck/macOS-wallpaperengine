import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
import simd

struct PostProcessPass {
    private let device: MTLDevice
    private let copyVertexBuffer: MTLBuffer
    private let copyTexCoordBuffer: MTLBuffer
    private let samplerState: MTLSamplerState
    private var pipelineCache: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) throws {
        self.device = device

        let positions: [Float] = [
            -1, 1, 0,
            -1, -1, 0,
            1, 1, 0,
            1, 1, 0,
            -1, -1, 0,
            1, -1, 0,
        ]
        // NDC (-1, 1) is the top of the render target and texture v=0 is the
        // top of the scene texture — the copy must not flip.
        let texCoords: [Float] = [
            0, 0,
            0, 1,
            1, 0,
            1, 0,
            0, 1,
            1, 1,
        ]

        guard let copyVertexBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<Float>.stride * positions.count),
              let copyTexCoordBuffer = device.makeBuffer(bytes: texCoords, length: MemoryLayout<Float>.stride * texCoords.count) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate post-process geometry")
        }
        self.copyVertexBuffer = copyVertexBuffer
        self.copyTexCoordBuffer = copyTexCoordBuffer

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate post-process sampler")
        }
        self.samplerState = samplerState
    }

    mutating func finalize(
        packet: FramePacket,
        scene: SceneDescription,
        currentSceneTexture: MTLTexture,
        targetTexture: MTLTexture,
        materialBinder: MaterialBinder,
        imageRenderer: ImageRenderer,
        commandBuffer: MTLCommandBuffer
    ) throws {
        if let bloom = packet.cameraBloom, bloom.enabled {
            try renderBloom(
                bloom: bloom,
                packet: packet,
                scene: scene,
                currentSceneTexture: currentSceneTexture,
                targetTexture: targetTexture,
                materialBinder: materialBinder,
                imageRenderer: imageRenderer,
                commandBuffer: commandBuffer
            )
            return
        }

        try copyTexture(
            source: currentSceneTexture,
            destination: targetTexture,
            commandBuffer: commandBuffer
        )
    }

    private mutating func renderBloom(
        bloom: FrameCameraBloom,
        packet: FramePacket,
        scene: SceneDescription,
        currentSceneTexture: MTLTexture,
        targetTexture: MTLTexture,
        materialBinder: MaterialBinder,
        imageRenderer: ImageRenderer,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let quarterTexture = try makeRenderTexture(
            width: max(targetTexture.width / 4, 1),
            height: max(targetTexture.height / 4, 1)
        )
        let eighthTexture = try makeRenderTexture(
            width: max(targetTexture.width / 8, 1),
            height: max(targetTexture.height / 8, 1)
        )
        let bloomTexture = try makeRenderTexture(
            width: max(targetTexture.width / 8, 1),
            height: max(targetTexture.height / 8, 1)
        )
        guard let geometry = imageRenderer.makeOffscreenPassGeometry(device: device) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate bloom geometry")
        }

        let nodeDescriptor: NodeDescriptor
        let frameNode: FrameNode
        if let nd = scene.nodes.first(where: { $0.image != nil }),
           let fn = packet.nodes.first(where: { $0.nodeID == nd.id && $0.visible }) {
            nodeDescriptor = nd
            frameNode = fn
        } else if let nd = scene.nodes.first,
                  let fn = packet.nodes.first(where: { $0.nodeID == nd.id }) {
            nodeDescriptor = nd
            frameNode = fn
        } else {
            try copyTexture(source: currentSceneTexture, destination: targetTexture, commandBuffer: commandBuffer)
            return
        }

        let sharedConstants: [String: FrameValue] = [
            "bloomstrength": .double(bloom.strength),
            "bloomthreshold": .double(bloom.threshold),
        ]

        try renderMaterial(
            scene: scene,
            shaderPath: "downsample_quarter_bloom",
            constants: sharedConstants,
            textureOverridesBySlot: [0: currentSceneTexture],
            textureOverridesByName: ["_rt_FullFrameBuffer": currentSceneTexture],
            viewportSize: CGSize(width: quarterTexture.width, height: quarterTexture.height),
            destinationTexture: quarterTexture,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            packet: packet,
            geometry: geometry,
            materialBinder: materialBinder,
            commandBuffer: commandBuffer
        )

        try renderMaterial(
            scene: scene,
            shaderPath: "downsample_eighth_blur_v",
            constants: sharedConstants,
            textureOverridesBySlot: [0: quarterTexture],
            textureOverridesByName: ["_rt_4FrameBuffer": quarterTexture],
            viewportSize: CGSize(width: eighthTexture.width, height: eighthTexture.height),
            destinationTexture: eighthTexture,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            packet: packet,
            geometry: geometry,
            materialBinder: materialBinder,
            commandBuffer: commandBuffer
        )

        try renderMaterial(
            scene: scene,
            shaderPath: "blur_h_bloom",
            constants: sharedConstants,
            textureOverridesBySlot: [0: eighthTexture],
            textureOverridesByName: ["_rt_8FrameBuffer": eighthTexture],
            viewportSize: CGSize(width: bloomTexture.width, height: bloomTexture.height),
            destinationTexture: bloomTexture,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            packet: packet,
            geometry: geometry,
            materialBinder: materialBinder,
            commandBuffer: commandBuffer
        )

        try renderMaterial(
            scene: scene,
            shaderPath: "combine",
            constants: sharedConstants,
            textureOverridesBySlot: [0: currentSceneTexture, 1: bloomTexture],
            textureOverridesByName: [
                "_rt_FullFrameBuffer": currentSceneTexture,
                "_rt_Bloom": bloomTexture,
                "_rt_imageLayerComposite_-1_a": currentSceneTexture,
            ],
            viewportSize: CGSize(width: targetTexture.width, height: targetTexture.height),
            destinationTexture: targetTexture,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            packet: packet,
            geometry: geometry,
            materialBinder: materialBinder,
            commandBuffer: commandBuffer
        )
    }

    private func renderMaterial(
        scene: SceneDescription,
        shaderPath: String,
        constants: [String: FrameValue],
        textureOverridesBySlot: [Int: MTLTexture],
        textureOverridesByName: [String: MTLTexture],
        viewportSize: CGSize,
        destinationTexture: MTLTexture,
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        packet: FramePacket,
        geometry: ImageRenderer.SceneGeometry,
        materialBinder: MaterialBinder,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let material = FrameMaterial(
            id: "__postprocess__:\(shaderPath)",
            sourceNodeID: NodeID(rawValue: -1),
            sourceFile: shaderPath,
            passOrdering: [0],
            passes: [
                FrameMaterialPass(
                    index: 0,
                    shaderPath: shaderPath,
                    blending: 0,
                    culling: 0,
                    depthTest: 0,
                    depthWrite: 0,
                    textures: [],
                    userTextures: [],
                    constants: constants,
                    combos: [:]
                ),
            ]
        )

        guard let pass = material.passes.first else {
            return
        }
        let preparedPass = try materialBinder.preparePass(material: material, pass: pass,
            colorAttachmentPixelFormat: destinationTexture.pixelFormat)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destinationTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        defer { encoder.endEncoding() }

        try materialBinder.bind(
            preparedPass: preparedPass,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            scene: scene,
            packet: packet,
            positions: geometry.positions,
            texCoords: geometry.texCoords,
            vertexCount: geometry.vertexCount,
            encoder: encoder,
            bindingContext: MaterialBindingContext(
                viewportSize: viewportSize,
                textureOverridesBySlot: textureOverridesBySlot,
                textureOverridesByName: textureOverridesByName,
                uniformOverrides: fullscreenUniformOverrides()
            )
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
    }

    mutating func copyTexture(
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        region: MTLSize? = nil
    ) throws {
        let pipelineState = try pipelineState(for: destination.pixelFormat)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = region == nil ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        defer { encoder.endEncoding() }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(copyTexCoordBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        var sourceUVScale = SIMD2<Float>(repeating: 1)
        if let region {
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                width: Double(region.width), height: Double(region.height), znear: 0, zfar: 1))
            sourceUVScale = SIMD2(Float(region.width) / Float(source.width), Float(region.height) / Float(source.height))
        }
        encoder.setFragmentBytes(&sourceUVScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private mutating func pipelineState(for pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = pipelineCache[pixelFormat] {
            return cached
        }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut copy_vertex(
            const device packed_float3* positions [[buffer(0)]],
            const device float2* texCoords [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(float3(positions[vertexID]), 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 copy_fragment(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            sampler sourceSampler [[sampler(0)]],
            constant float2& sourceUVScale [[buffer(0)]]
        ) {
            return sourceTexture.sample(sourceSampler, in.texCoord * sourceUVScale);
        }
        """

        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "copy_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "copy_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelineCache[pixelFormat] = pipeline
        return pipeline
    }

    private func makeRenderTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate bloom texture")
        }
        return texture
    }
}

private func fullscreenUniformOverrides() -> [String: Data] {
    let identity4 = matrix_identity_float4x4
    let identity3 = simd_float3x3(
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
        SIMD3<Float>(0, 0, 1)
    )
    return [
        "g_ModelViewProjectionMatrix": localBytes(of: identity4),
        "g_ModelMatrix": localBytes(of: identity4),
        "g_AltModelMatrix": localBytes(of: identity4),
        "g_ViewProjectionMatrix": localBytes(of: identity4),
        "g_AltViewProjectionMatrix": localBytes(of: identity4),
        "g_NormalModelMatrix": localBytes(of: identity3),
        "g_AltNormalModelMatrix": localBytes(of: identity3),
    ]
}

private func localBytes<T>(of value: T) -> Data {
    withUnsafeBytes(of: value) { Data($0) }
}
