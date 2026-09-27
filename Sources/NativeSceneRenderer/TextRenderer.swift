import CoreGraphics
import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
import simd

final class TextRenderer {
    private let device: MTLDevice
    private let textLayouts: TextLayoutEngine
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private var textureCache: [NodeID: (key: String, texture: MTLTexture)] = [:]
    var cachedNodeCount: Int { textureCache.count }

    func remove(nodeIDs: Set<NodeID>) {
        for id in nodeIDs { textureCache[id] = nil }
    }

    init(device: MTLDevice, assetRoots: [URL], colorPixelFormat: MTLPixelFormat, textLayouts: TextLayoutEngine? = nil) throws {
        self.device = device
        self.textLayouts = textLayouts ?? TextLayoutEngine(assetRoots: assetRoots)

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut text_vert(
            const device packed_float2* positions [[buffer(0)]],
            const device packed_float2* uvs [[buffer(1)]],
            uint vid [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(float2(positions[vid]), 0.0, 1.0);
            out.uv = float2(uvs[vid]);
            return out;
        }

        fragment float4 text_frag(
            VertexOut in [[stage_in]],
            texture2d<float> tex [[texture(0)]],
            sampler samp [[sampler(0)]],
            constant float& opacity [[buffer(0)]]
        ) {
            float4 color = tex.sample(samp, in.uv);
            color.a *= opacity;
            return color;
        }
        """

        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "text_vert")
        descriptor.fragmentFunction = library.makeFunction(name: "text_frag")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        guard let state = device.makeSamplerState(descriptor: sampler) else {
            throw NativeSceneRendererError.unsupportedScene("failed to create text sampler state")
        }
        self.samplerState = state
    }

    /// Rasterizes a text node into its cached texture without drawing it.
    /// Used by the effect-chain path, which post-processes the texture
    /// before compositing.
    func rasterizedTexture(for text: FrameText, includeOpacity: Bool = true) throws -> MTLTexture? {
        let sanitized = text.content.replacingOccurrences(of: "\0", with: "")
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try texture(for: text, content: sanitized, glyphAlpha: includeOpacity ? text.color.w : 1)
    }

    /// Draws a single text quad with an explicit texture (the output of an
    /// effect chain) using the node's world transform.
    func renderQuad(
        text: FrameText,
        texture: MTLTexture,
        node: FrameNode,
        viewProjection: simd_float4x4,
        opacity: Float = 1,
        encoder: MTLRenderCommandEncoder
    ) throws {

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        var opacity = max(0, min(1, opacity))
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)

        let size = CGSize(width: texture.width, height: texture.height)
        let (positions, texCoords) = try makeGeometry(
            size: size,
            text: text,
            worldTransform: viewProjection * node.worldTransform.simdValue
        )

        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        encoder.setVertexBuffer(texCoords, offset: 0, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func render(
        texts: [FrameText],
        viewProjection: simd_float4x4,
        nodes: [FrameNode],
        encoder: MTLRenderCommandEncoder
    ) throws {
        guard !texts.isEmpty else {
            return
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        var opacity: Float = 1
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)

        for text in texts where text.visible {
            let sanitized = text.content.replacingOccurrences(of: "\0", with: "")
            guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let node = nodesByID[text.nodeID],
                  let texture = try texture(for: text, content: sanitized) else {
                continue
            }

            let size = CGSize(width: texture.width, height: texture.height)
            let (positions, texCoords) = try makeGeometry(
                size: size,
                text: text,
                worldTransform: viewProjection * node.worldTransform.simdValue
            )

            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(texCoords, offset: 0, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func makeGeometry(
        size: CGSize,
        text: FrameText,
        worldTransform: simd_float4x4
    ) throws -> (MTLBuffer, MTLBuffer) {
        let width = Float(size.width)
        let height = Float(size.height)
        // Alignment determines the content's pivot. Padding surrounds that
        // content and must not move its anchored edge.
        let padding = Float(max(text.padding, 0))
        let left: Float
        switch text.horizontalAlign.lowercased() {
        case "left": left = -padding
        case "right": left = -width + padding
        default: left = -width / 2
        }
        let bottom: Float
        switch text.verticalAlign.lowercased() {
        case "top": bottom = -height + padding
        case "bottom": bottom = -padding
        default: bottom = -height / 2
        }
        let right = left + width, top = bottom + height
        let sceneVertices = [
            transformPoint(worldTransform, x: left, y: top),
            transformPoint(worldTransform, x: left, y: bottom),
            transformPoint(worldTransform, x: right, y: top),
            transformPoint(worldTransform, x: right, y: top),
            transformPoint(worldTransform, x: left, y: bottom),
            transformPoint(worldTransform, x: right, y: bottom),
        ]
        let positions = sceneVertices.flatMap { [$0.x, $0.y] }
        let texCoords: [Float] = [
            0, 0,
            0, 1,
            1, 0,
            1, 0,
            0, 1,
            1, 1,
        ]

        guard let positionBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<Float>.stride * positions.count),
              let texCoordBuffer = device.makeBuffer(bytes: texCoords, length: MemoryLayout<Float>.stride * texCoords.count) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate text geometry buffers")
        }

        return (positionBuffer, texCoordBuffer)
    }

    private func transformPoint(_ matrix: simd_float4x4, x: Float, y: Float) -> SIMD2<Float> {
        let transformed = simd_mul(matrix, SIMD4<Float>(x, y, 0, 1))
        return SIMD2<Float>(transformed.x, transformed.y)
    }

    private func texture(for text: FrameText, content: String, glyphAlpha: Float? = nil) throws -> MTLTexture? {
        let glyphAlpha = glyphAlpha ?? text.color.w
        let key = [
            String(text.nodeID.rawValue),
            content,
            text.fontPath,
            String(text.pointSize),
            String(text.maxWidth),
            String(text.maxRows),
            String(text.padding),
            text.horizontalAlign,
            text.verticalAlign,
            String(text.limitWidth),
            String(text.limitRows),
            String(text.limitUseEllipsis),
            String(text.blockAlign),
            String(text.castShadow),
            String(text.color.x),
            String(text.color.y),
            String(text.color.z),
            String(glyphAlpha),
            String(text.opaqueBackground),
            String(text.backgroundColor.x),
            String(text.backgroundColor.y),
            String(text.backgroundColor.z),
            String(text.backgroundColor.w),
        ].joined(separator: "|")

        if let cached = textureCache[text.nodeID], cached.key == key {
            return cached.texture
        }

        guard let layout = try textLayouts.layout(for: text) else { return nil }
        let width = layout.width, height = layout.height
        let padding = max(text.padding, 0)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        if text.opaqueBackground || text.backgroundColor.w > 0 {
            context.setFillColor(
                CGColor(colorSpace: colorSpace, components: [
                    CGFloat(text.backgroundColor.x), CGFloat(text.backgroundColor.y), CGFloat(text.backgroundColor.z),
                    CGFloat(text.opaqueBackground ? 1 : text.backgroundColor.w)
                ])!
            )
            context.fill(fullRect)
        } else {
            context.clear(fullRect)
        }

        let available = fullRect.insetBy(dx: CGFloat(padding), dy: CGFloat(padding))
        let verticalOffset = verticalOffset(
            for: layout.contentHeight,
            availableHeight: available.height,
            alignment: text.verticalAlign
        )
        let origin = CGPoint(x: available.minX, y: available.minY + verticalOffset)

        context.setFillColor(CGColor(colorSpace: colorSpace, components: [
            CGFloat(text.color.x), CGFloat(text.color.y), CGFloat(text.color.z), CGFloat(glyphAlpha)
        ])!)
        if text.castShadow {
            layout.draw(in: context, origin: origin.applying(CGAffineTransform(translationX: 1, y: -1)), shadow: true)
        }

        layout.draw(in: context, origin: origin, shadow: false)

        // Core Graphics produces premultiplied pixels. Scene effects and the
        // final text blend consume straight color, like authored image textures.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )
        // Clocks and animated text replace their previous texture instead of
        // retaining a new allocation for every value for the life of the scene.
        textureCache[text.nodeID] = (key, texture)
        return texture
    }

    private func verticalOffset(for contentHeight: CGFloat, availableHeight: CGFloat, alignment: String) -> CGFloat {
        let remaining = max(availableHeight - contentHeight, 0)
        switch alignment.lowercased() {
        case "top":
            return remaining
        case "bottom":
            return 0
        default:
            return remaining / 2
        }
    }

}
