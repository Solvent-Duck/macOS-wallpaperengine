import CoreGraphics
import Foundation
import Metal
import MetalKit
import NativeSceneCore
import NativeSceneRuntime
import simd

struct ParticleRenderer {
    private struct Uniforms {
        var modelViewProjectionMatrix: simd_float4x4
    }

    private struct Geometry {
        let positions: MTLBuffer
        let texCoords: MTLBuffer
        let colors: MTLBuffer
        let vertexCount: Int
    }

    private let device: MTLDevice
    private let textureResolver: TextureResolver
    private let samplerState: MTLSamplerState
    private let fallbackTexture: MTLTexture
    private var pipelineStates: [Int: MTLRenderPipelineState] = [:]

    init(device: MTLDevice, assetRoots: [URL], colorPixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.textureResolver = TextureResolver(device: device, roots: assetRoots)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to create particle sampler state")
        }
        self.samplerState = samplerState
        self.fallbackTexture = try Self.makeFallbackTexture(device: device)
        self.pipelineStates = try Self.buildPipelineStates(device: device, colorPixelFormat: colorPixelFormat)
    }

    func render(
        system: FrameParticleSystem,
        frameNode: FrameNode,
        pass: FrameMaterialPass,
        scene: SceneDescription,
        viewportSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) throws {
        guard system.visible, system.emissionEnabled,
              let geometry = makeGeometry(
                system: system,
                scene: scene,
                viewportSize: viewportSize,
                opacity: Float(frameNode.opacity ?? 1)
              ) else {
            return
        }

        let pipelineState = pipelineStates[pass.blending] ?? pipelineStates[2]!
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(geometry.positions, offset: 0, index: 0)
        encoder.setVertexBuffer(geometry.texCoords, offset: 0, index: 1)
        encoder.setVertexBuffer(geometry.colors, offset: 0, index: 2)

        let modelMatrix = simd_mul(
            sceneCoordinateConversion(scene: scene, viewportSize: viewportSize),
            frameNode.worldTransform.simdValue
        )
        var uniforms = Uniforms(
            modelViewProjectionMatrix: simd_mul(
                projectionMatrix(scene: scene, viewportSize: viewportSize),
                modelMatrix
            )
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)

        let texture = try resolveTexture(for: pass) ?? fallbackTexture
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
    }

    private func resolveTexture(for pass: FrameMaterialPass) throws -> MTLTexture? {
        guard let path = pass.textures.first?.path ?? pass.userTextures.first?.path else {
            return fallbackTexture
        }
        return try textureResolver.resolveTexture(named: path) ?? fallbackTexture
    }

    private func makeGeometry(
        system: FrameParticleSystem,
        scene: SceneDescription,
        viewportSize: CGSize,
        opacity: Float
    ) -> Geometry? {
        guard !system.instances.isEmpty else {
            return nil
        }

        let projection = scene.scene?.camera.projection
        let sizeScale: Float = (projection?.isAuto ?? true) ? Float(viewportSize.height) * 320 : 1

        var positions: [Float] = []
        var texCoords: [Float] = []
        var colors: [Float] = []
        positions.reserveCapacity(system.instances.count * 18)
        texCoords.reserveCapacity(system.instances.count * 12)
        colors.reserveCapacity(system.instances.count * 24)

        for instance in system.instances {
            let scaledSize = instance.size * sizeScale
            let halfWidth = scaledSize * 0.5
            let halfHeight = scaledSize * 0.5
            let sinAngle = sin(instance.rotation.z)
            let cosAngle = cos(instance.rotation.z)
            let alpha = min(max(instance.color.w * opacity, 0), 1)
            let color = SIMD4<Float>(1, 1, 1, alpha)

            let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
                (SIMD2<Float>(-halfWidth, -halfHeight), SIMD2<Float>(0, 0)),
                (SIMD2<Float>(-halfWidth, halfHeight), SIMD2<Float>(0, 1)),
                (SIMD2<Float>(halfWidth, -halfHeight), SIMD2<Float>(1, 0)),
                (SIMD2<Float>(halfWidth, -halfHeight), SIMD2<Float>(1, 0)),
                (SIMD2<Float>(-halfWidth, halfHeight), SIMD2<Float>(0, 1)),
                (SIMD2<Float>(halfWidth, halfHeight), SIMD2<Float>(1, 1)),
            ]

            for (corner, uv) in corners {
                let rotated = SIMD2<Float>(
                    corner.x * cosAngle - corner.y * sinAngle,
                    corner.x * sinAngle + corner.y * cosAngle
                )
                positions.append(contentsOf: [
                    instance.position.x + rotated.x,
                    instance.position.y + rotated.y,
                    0
                ])
                texCoords.append(contentsOf: [uv.x, uv.y])
                colors.append(contentsOf: [color.x, color.y, color.z, color.w])
            }
        }

        guard let positionBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<Float>.stride * positions.count),
              let texCoordBuffer = device.makeBuffer(bytes: texCoords, length: MemoryLayout<Float>.stride * texCoords.count),
              let colorBuffer = device.makeBuffer(bytes: colors, length: MemoryLayout<Float>.stride * colors.count) else {
            return nil
        }

        return Geometry(
            positions: positionBuffer,
            texCoords: texCoordBuffer,
            colors: colorBuffer,
            vertexCount: positions.count / 3
        )
    }

    private func projectionMatrix(scene: SceneDescription, viewportSize: CGSize) -> simd_float4x4 {
        let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
        let width = Float(projectionSize.width)
        let height = Float(projectionSize.height)
        let nearZ = Float(scene.scene?.camera.projection.nearZ ?? -1)
        let farZ = Float(scene.scene?.camera.projection.farZ ?? 1)
        return simd_float4x4(
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1 / max(farZ - nearZ, 0.0001), 0),
            SIMD4<Float>(0, 0, -nearZ / max(farZ - nearZ, 0.0001), 1)
        )
    }

    private func sceneCoordinateConversion(scene: SceneDescription, viewportSize: CGSize) -> simd_float4x4 {
        let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
        let width = Float(projectionSize.width)
        let height = Float(projectionSize.height)
        let translate = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-width / 2, height / 2, 0, 1)
        )
        let flip = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        return simd_mul(translate, flip)
    }

    private func resolvedProjectionSize(scene: SceneDescription, viewportSize: CGSize) -> CGSize {
        let projection = scene.scene?.camera.projection
        let width = projection.map { $0.isAuto || $0.width <= 0 ? Int(viewportSize.width) : $0.width } ?? Int(viewportSize.width)
        let height = projection.map { $0.isAuto || $0.height <= 0 ? Int(viewportSize.height) : $0.height } ?? Int(viewportSize.height)
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    private static func buildPipelineStates(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat
    ) throws -> [Int: MTLRenderPipelineState] {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct ParticleUniforms {
            float4x4 modelViewProjectionMatrix;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
            float4 color;
        };

        vertex VertexOut particle_vert(
            const device float3* positions [[buffer(0)]],
            const device float2* texCoords [[buffer(1)]],
            const device float4* colors [[buffer(2)]],
            constant ParticleUniforms& uniforms [[buffer(3)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = uniforms.modelViewProjectionMatrix * float4(positions[vertexID], 1.0);
            out.uv = texCoords[vertexID];
            out.color = colors[vertexID];
            return out;
        }

        fragment float4 particle_frag(
            VertexOut in [[stage_in]],
            texture2d<float> tex [[texture(0)]],
            sampler particleSampler [[sampler(0)]]
        ) {
            const float4 sampled = tex.sample(particleSampler, in.uv);
            return sampled * in.color;
        }
        """

        let library = try device.makeLibrary(source: source, options: nil)
        let vertexFunction = library.makeFunction(name: "particle_vert")
        let fragmentFunction = library.makeFunction(name: "particle_frag")

        func makeState(blending: Int) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            let attachment = descriptor.colorAttachments[0]!
            switch blending {
            case 3:
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            case 2:
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            default:
                attachment.isBlendingEnabled = false
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        return [
            1: try makeState(blending: 1),
            2: try makeState(blending: 2),
            3: try makeState(blending: 3),
        ]
    }

    private static func makeFallbackTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate fallback particle texture")
        }

        var pixel: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return texture
    }
}

private final class TextureResolver {
    private let loader: MTKTextureLoader
    private let roots: [URL]
    private var cache: [String: MTLTexture] = [:]

    init(device: MTLDevice, roots: [URL]) {
        self.loader = MTKTextureLoader(device: device)
        self.roots = roots
    }

    func resolveTexture(named path: String) throws -> MTLTexture? {
        if let cached = cache[path] {
            return cached
        }

        let fileManager = FileManager.default
        for candidate in candidateURLs(for: path) where fileManager.fileExists(atPath: candidate.path) {
            do {
                let texture = try loader.newTexture(
                    URL: candidate,
                    options: [
                        .SRGB: false,
                        .generateMipmaps: false,
                    ]
                )
                cache[path] = texture
                return texture
            } catch {
                continue
            }
        }

        return nil
    }

    private func candidateURLs(for path: String) -> [URL] {
        let ext = URL(fileURLWithPath: path).pathExtension
        let baseNames = ext.isEmpty ? [path, "materials/\(path)"] : [path, "materials/\(path)"]
        let extensions = ext.isEmpty ? ["png", "tga", "jpg", "jpeg"] : [ext]

        var urls: [URL] = []
        for root in roots {
            for baseName in baseNames {
                if ext.isEmpty {
                    for ext in extensions {
                        urls.append(root.appendingPathComponent(baseName).appendingPathExtension(ext))
                    }
                } else {
                    urls.append(root.appendingPathComponent(baseName))
                }
            }
        }
        return urls
    }
}
