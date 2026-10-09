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
        nodeDescriptor: NodeDescriptor,
        packet: FramePacket,
        material: FrameMaterial,
        pass: FrameMaterialPass,
        materialBinder: MaterialBinder,
        sceneNamedTextures: [String: MTLTexture],
        scene: SceneDescription,
        viewportSize: CGSize,
        inheritedOpacity: Float,
        encoder: MTLRenderCommandEncoder
    ) throws {
        guard system.visible, !system.instances.isEmpty else {
            return
        }

        if system.rendererName == "sprite" || system.rendererName == "spritetrail" {
            try renderMaterial(system: system, frameNode: frameNode, nodeDescriptor: nodeDescriptor,
                               packet: packet, material: material, pass: pass, materialBinder: materialBinder,
                               sceneNamedTextures: sceneNamedTextures, scene: scene, viewportSize: viewportSize,
                               opacity: inheritedOpacity, encoder: encoder)
            return
        }

        let texture = try resolveTexture(for: pass) ?? fallbackTexture
        let textureRatio = texture.width > 0 ? Float(texture.height) / Float(texture.width) : 1

        guard let geometry = makeGeometry(
            system: system,
            scene: scene,
            viewportSize: viewportSize,
            opacity: inheritedOpacity,
            textureRatio: textureRatio
        ) else {
            return
        }

        let pipelineState = pipelineStates[pass.blending] ?? pipelineStates[2]!
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(geometry.positions, offset: 0, index: 0)
        encoder.setVertexBuffer(geometry.texCoords, offset: 0, index: 1)
        encoder.setVertexBuffer(geometry.colors, offset: 0, index: 2)

        var uniforms = Uniforms(
            modelViewProjectionMatrix: materialBinder.sceneViewProjection(
                scene: scene, viewportSize: viewportSize, cameraZoom: packet.cameraZoom
            ) * frameNode.worldTransform.simdValue
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)

        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
    }

    private func renderMaterial(
        system: FrameParticleSystem, frameNode: FrameNode, nodeDescriptor: NodeDescriptor,
        packet: FramePacket, material: FrameMaterial, pass: FrameMaterialPass,
        materialBinder: MaterialBinder, sceneNamedTextures: [String: MTLTexture],
        scene: SceneDescription, viewportSize: CGSize, opacity: Float, encoder: MTLRenderCommandEncoder
    ) throws {
        let (prepared, atlas) = try prepareMaterial(system: system, material: material, pass: pass,
            materialBinder: materialBinder, sceneNamedTextures: sceneNamedTextures, viewportSize: viewportSize)
        let usesParticleAttributes = prepared.compiledShader.metal.vertexAttributes.contains { $0.name == "a_TexCoordVec4" }
        let geometry: Geometry
        var attributeBuffers: [String: MTLBuffer]
        if usesParticleAttributes {
            guard let result = makeBillboardInputs(system: system, scene: scene, viewportSize: viewportSize,
                                                   opacity: opacity, atlas: atlas) else { return }
            geometry = result.0
            attributeBuffers = result.1
        } else {
            // Custom shaders using the ordinary image vertex layout receive
            // expanded geometry, while retaining their own fragment program.
            let texture = try resolveTexture(for: pass) ?? fallbackTexture
            guard let result = makeGeometry(system: system, scene: scene, viewportSize: viewportSize,
                opacity: opacity, textureRatio: Float(texture.height) / Float(texture.width)) else { return }
            geometry = result
            attributeBuffers = [:]
        }
        attributeBuffers["a_Color"] = geometry.colors
        func data<T>(_ value: T) -> Data { withUnsafeBytes(of: value) { Data($0) } }
        var uniforms: [String: Data] = [
            "g_OrientationRight": data(SIMD3<Float>(1, 0, 0)),
            "g_OrientationUp": data(SIMD3<Float>(0, 1, 0)),
            "g_OrientationForward": data(SIMD3<Float>(0, 0, 1)),
            "g_ViewRight": data(SIMD3<Float>(1, 0, 0)),
            "g_ViewUp": data(SIMD3<Float>(0, 1, 0)),
            "g_RenderVar0": data(SIMD4<Float>(Float(system.rendererParameters?.length ?? 0.05),
                                               Float(system.rendererParameters?.maxLength ?? 10),
                                               Float(system.rendererParameters?.minLength ?? 0), 0))
        ]
        if let atlas { uniforms["g_RenderVar1"] = data(atlas.renderUniform) }
        if system.rendererName == "spritetrail", (scene.scene?.camera.configuration.eye.dropFirst(2).first ?? 0) == 0 {
            // A 2D camera is stored at z=0. Trail billboards still need a
            // view direction perpendicular to that plane when taking a cross product.
            uniforms["g_EyePosition"] = data(SIMD3<Float>(0, 0, -max(Float(scene.scene?.camera.projection.farZ ?? 1000), 1)))
        }
        try materialBinder.bind(preparedPass: prepared, frameNode: frameNode, nodeDescriptor: nodeDescriptor,
            scene: scene, packet: packet, positions: geometry.positions, texCoords: geometry.texCoords,
            vertexCount: geometry.vertexCount, encoder: encoder,
            bindingContext: MaterialBindingContext(viewportSize: viewportSize,
                textureOverridesByName: sceneNamedTextures, uniformOverrides: uniforms),
            vertexAttributeBuffers: attributeBuffers)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
    }

    /// All passes and children share the scene as it existed before this
    /// particle layer. Check the complete tree before drawing any part of it.
    func samplesTexture(_ texture: MTLTexture, system: FrameParticleSystem,
                        materialsByID: [String: FrameMaterial], materialBinder: MaterialBinder,
                        sceneNamedTextures: [String: MTLTexture], viewportSize: CGSize) throws -> Bool {
        if system.visible, !system.instances.isEmpty,
           system.rendererName == "sprite" || system.rendererName == "spritetrail",
           let reference = system.materialReference, let material = materialsByID[reference] {
            let context = MaterialBindingContext(viewportSize: viewportSize, textureOverridesByName: sceneNamedTextures)
            for index in material.passOrdering {
                guard let pass = material.passes.first(where: { $0.index == index }) else { continue }
                let (prepared, _) = try prepareMaterial(system: system, material: material, pass: pass,
                    materialBinder: materialBinder, sceneNamedTextures: sceneNamedTextures, viewportSize: viewportSize)
                if try materialBinder.samplesTexture(texture, preparedPass: prepared, bindingContext: context) { return true }
            }
        }
        // Other renderer paths sample only their own resolved asset texture.
        // Children can remain visible even when their parent has no instances.
        for child in system.childSystems {
            if try samplesTexture(texture, system: child, materialsByID: materialsByID, materialBinder: materialBinder,
                                  sceneNamedTextures: sceneNamedTextures, viewportSize: viewportSize) { return true }
        }
        return false
    }

    func requiresSceneMipmaps(system: FrameParticleSystem, materialsByID: [String: FrameMaterial],
                              materialBinder: MaterialBinder, sceneNamedTextures: [String: MTLTexture],
                              viewportSize: CGSize) throws -> Bool {
        if system.visible, !system.instances.isEmpty,
           system.rendererName == "sprite" || system.rendererName == "spritetrail",
           let reference = system.materialReference, let material = materialsByID[reference] {
            let context = MaterialBindingContext(viewportSize: viewportSize, textureOverridesByName: sceneNamedTextures)
            for index in material.passOrdering {
                guard let pass = material.passes.first(where: { $0.index == index }) else { continue }
                let (prepared, _) = try prepareMaterial(system: system, material: material, pass: pass,
                    materialBinder: materialBinder, sceneNamedTextures: sceneNamedTextures, viewportSize: viewportSize)
                if materialBinder.requiresSceneMipmaps(preparedPass: prepared, bindingContext: context) { return true }
            }
        }
        for child in system.childSystems {
            if try requiresSceneMipmaps(system: child, materialsByID: materialsByID, materialBinder: materialBinder,
                                       sceneNamedTextures: sceneNamedTextures, viewportSize: viewportSize) { return true }
        }
        return false
    }

    private func prepareMaterial(system: FrameParticleSystem, material: FrameMaterial, pass: FrameMaterialPass,
                                 materialBinder: MaterialBinder, sceneNamedTextures: [String: MTLTexture],
                                 viewportSize: CGSize) throws -> (PreparedMaterialPass, ParticleTextureAtlas?) {
        var combos = pass.combos
        // Metal has no geometry stage. WE supplies a vertex shader variant
        // that expands six copies of each particle center into a billboard.
        combos["GS_ENABLED"] = 0
        combos["THICKFORMAT"] = 1
        combos["TRAILRENDERER"] = system.rendererName == "spritetrail" ? 1 : 0
        let atlas = try materialBinder.particleAtlas(for: pass)
        if atlas != nil {
            combos["SPRITESHEET"] = 1
            combos["SPRITESHEETBLEND"] = system.animationMode.lowercased() == "randomframe" ? 0 : (combos["SPRITESHEETBLEND"] ?? 1)
        }
        if combos["NORMALMAP"] == nil,
           (pass.textures + pass.userTextures).contains(where: { $0.slot == 1 && !$0.path.isEmpty }) {
            combos["NORMALMAP"] = 1
        }
        let shaderPass = FrameMaterialPass(index: pass.index, shaderPath: pass.shaderPath,
            blending: pass.blending, culling: pass.culling, depthTest: pass.depthTest, depthWrite: pass.depthWrite,
            textures: pass.textures, userTextures: pass.userTextures, constants: pass.constants, combos: combos)
        let prepared = try materialBinder.preparePass(material: material, pass: shaderPass,
            bindingContext: MaterialBindingContext(viewportSize: viewportSize, textureOverridesByName: sceneNamedTextures))
        return (prepared, atlas)
    }

    private func makeBillboardInputs(system: FrameParticleSystem, scene: SceneDescription, viewportSize: CGSize,
                                     opacity: Float, atlas: ParticleTextureAtlas?) -> (Geometry, [String: MTLBuffer])? {
        let sizeScale: Float = (scene.scene?.camera.projection.isAuto ?? true) ? Float(viewportSize.height) * 320 : 1
        let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        var positions: [Float] = []
        var uv: [Float] = []
        var rotationSize: [Float] = []
        var rotationXY: [Float] = []
        var velocityLife: [Float] = []
        var colors: [Float] = []
        positions.reserveCapacity(system.instances.count * 18)
        uv.reserveCapacity(system.instances.count * 12)
        rotationSize.reserveCapacity(system.instances.count * 24)
        rotationXY.reserveCapacity(system.instances.count * 12)
        velocityLife.reserveCapacity(system.instances.count * 24)
        colors.reserveCapacity(system.instances.count * 24)
        for instance in system.instances where instance.size.isFinite && instance.size > 0 {
            if system.rendererName == "spritetrail",
               simd_length_squared(SIMD3(instance.velocity.x, instance.velocity.y, instance.velocity.z)) < 0.00000001 { continue }
            let animationPosition = atlas?.animationPosition(mode: system.animationMode,
                lifetimePosition: instance.lifetimePosition, random: instance.animationRandom ?? 0,
                multiplier: Float(system.sequenceMultiplier)) ?? instance.lifetimePosition
            let scaledSize = instance.size * sizeScale
            let alpha = min(max(instance.color.w * opacity, 0), 1)
            for corner in corners {
                // Append directly into the reserved buffers. Array literals here
                // allocate six temporary arrays for every vertex of every particle.
                positions.append(instance.position.x)
                positions.append(instance.position.y)
                positions.append(instance.position.z)
                uv.append(corner.x)
                uv.append(corner.y)
                rotationSize.append(corner.x)
                rotationSize.append(corner.y)
                rotationSize.append(instance.rotation.z)
                rotationSize.append(scaledSize)
                rotationXY.append(instance.rotation.x)
                rotationXY.append(instance.rotation.y)
                velocityLife.append(instance.velocity.x)
                velocityLife.append(instance.velocity.y)
                velocityLife.append(instance.velocity.z)
                velocityLife.append(animationPosition)
                colors.append(instance.color.x)
                colors.append(instance.color.y)
                colors.append(instance.color.z)
                colors.append(alpha)
            }
        }
        func buffer(_ values: [Float]) -> MTLBuffer? {
            guard !values.isEmpty else { return nil }
            return device.makeBuffer(bytes: values, length: MemoryLayout<Float>.stride * values.count)
        }
        guard let positionBuffer = buffer(positions), let uvBuffer = buffer(uv), let colorBuffer = buffer(colors),
              let rotationSizeBuffer = buffer(rotationSize), let rotationXYBuffer = buffer(rotationXY),
              let velocityLifeBuffer = buffer(velocityLife) else { return nil }
        return (Geometry(positions: positionBuffer, texCoords: uvBuffer, colors: colorBuffer, vertexCount: positions.count / 3),
                ["a_TexCoordVec4": rotationSizeBuffer, "a_TexCoordC2": rotationXYBuffer,
                 "a_TexCoordVec4C1": velocityLifeBuffer])
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
        opacity: Float,
        textureRatio: Float
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

        switch system.rendererName {
        case "ropetrail":
            buildRopeTrailGeometry(
                system: system,
                sizeScale: sizeScale,
                opacity: opacity,
                positions: &positions,
                texCoords: &texCoords,
                colors: &colors
            )
        case "rope":
            buildRopeGeometry(
                system: system,
                sizeScale: sizeScale,
                opacity: opacity,
                positions: &positions,
                texCoords: &texCoords,
                colors: &colors
            )
        case "spritetrail":
            buildSpriteGeometry(
                system: system,
                sizeScale: sizeScale,
                opacity: opacity,
                textureRatio: textureRatio,
                trail: true,
                positions: &positions,
                texCoords: &texCoords,
                colors: &colors
            )
        default:
            buildSpriteGeometry(
                system: system,
                sizeScale: sizeScale,
                opacity: opacity,
                textureRatio: textureRatio,
                trail: false,
                positions: &positions,
                texCoords: &texCoords,
                colors: &colors
            )
        }

        guard !positions.isEmpty,
              let positionBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<Float>.stride * positions.count),
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

    private func buildSpriteGeometry(
        system: FrameParticleSystem,
        sizeScale: Float,
        opacity: Float,
        textureRatio: Float,
        trail: Bool,
        positions: inout [Float],
        texCoords: inout [Float],
        colors: inout [Float]
    ) {
        let trailLengthFactor = Float(system.rendererParameters?.length ?? 0.05)
        let trailMaxLength = Float(system.rendererParameters?.maxLength ?? 10)
        let trailMinLength = Float(system.rendererParameters?.minLength ?? 0)

        for instance in system.instances {
            let scaledSize = instance.size * sizeScale
            guard scaledSize.isFinite, scaledSize > 0 else {
                continue
            }
            let alpha = min(max(instance.color.w * opacity, 0), 1)
            let color = SIMD4<Float>(instance.color.x, instance.color.y, instance.color.z, alpha)
            let position = SIMD2<Float>(instance.position.x, instance.position.y)

            var rightAxis: SIMD2<Float>
            var upAxis: SIMD2<Float>
            if trail {
                let velocity = SIMD2<Float>(instance.velocity.x, instance.velocity.y)
                let speed = simd_length(velocity)
                guard speed > 0.0001 else {
                    continue
                }
                let direction = velocity / speed
                // Matches the WP trail shader: up follows velocity with the
                // trail length clamped between min/max, right is perpendicular.
                let trailLength = max(trailMinLength, min(speed * trailLengthFactor, trailMaxLength))
                rightAxis = SIMD2<Float>(-direction.y, direction.x) * (scaledSize * 0.5)
                upAxis = direction * (scaledSize * 0.5 * trailLength * textureRatio)
            } else {
                let sinAngle = sin(instance.rotation.z)
                let cosAngle = cos(instance.rotation.z)
                rightAxis = SIMD2<Float>(cosAngle, sinAngle) * (scaledSize * 0.5)
                upAxis = SIMD2<Float>(-sinAngle, cosAngle) * (scaledSize * 0.5)
            }

            let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
                (SIMD2<Float>(-1, -1), SIMD2<Float>(0, 0)),
                (SIMD2<Float>(-1, 1), SIMD2<Float>(0, 1)),
                (SIMD2<Float>(1, -1), SIMD2<Float>(1, 0)),
                (SIMD2<Float>(1, -1), SIMD2<Float>(1, 0)),
                (SIMD2<Float>(-1, 1), SIMD2<Float>(0, 1)),
                (SIMD2<Float>(1, 1), SIMD2<Float>(1, 1)),
            ]

            for (corner, uv) in corners {
                let offset = rightAxis * corner.x + upAxis * corner.y
                positions.append(contentsOf: [position.x + offset.x, position.y + offset.y, 0])
                texCoords.append(contentsOf: [uv.x, 1 - uv.y])
                colors.append(contentsOf: [color.x, color.y, color.z, color.w])
            }
        }
    }

    private struct RopePoint {
        var position: SIMD3<Float>
        var size: Float
        var color: SIMD4<Float>
    }

    /// `rope` chains every live particle into one ribbon.
    private func buildRopeGeometry(
        system: FrameParticleSystem,
        sizeScale: Float,
        opacity: Float,
        positions: inout [Float],
        texCoords: inout [Float],
        colors: inout [Float]
    ) {
        let points = system.instances.map {
            RopePoint(
                position: SIMD3<Float>($0.position.x, $0.position.y, $0.position.z),
                size: $0.size,
                color: SIMD4<Float>($0.color.x, $0.color.y, $0.color.z, $0.color.w)
            )
        }
        appendRopeRibbon(
            points: points,
            subdivision: max(1, Int(system.rendererParameters?.subdivision ?? 1)),
            sizeScale: sizeScale,
            opacity: opacity,
            positions: &positions,
            texCoords: &texCoords,
            colors: &colors
        )
    }

    /// `ropetrail` draws one ribbon per particle through its position history,
    /// head (v = 0) to tail.
    private func buildRopeTrailGeometry(
        system: FrameParticleSystem,
        sizeScale: Float,
        opacity: Float,
        positions: inout [Float],
        texCoords: inout [Float],
        colors: inout [Float]
    ) {
        let subdivision = max(1, Int(system.rendererParameters?.subdivision ?? 1))
        for instance in system.instances {
            guard let trail = instance.trail, !trail.isEmpty else { continue }
            let color = SIMD4<Float>(instance.color.x, instance.color.y, instance.color.z, instance.color.w)
            var chain = [RopePoint(
                position: SIMD3<Float>(instance.position.x, instance.position.y, instance.position.z),
                size: instance.size,
                color: color
            )]
            for past in trail.reversed() {
                chain.append(RopePoint(position: SIMD3<Float>(past.x, past.y, past.z), size: instance.size, color: color))
            }
            appendRopeRibbon(
                points: chain,
                subdivision: subdivision,
                sizeScale: sizeScale,
                opacity: opacity,
                positions: &positions,
                texCoords: &texCoords,
                colors: &colors
            )
        }
    }

    private func appendRopeRibbon(
        points: [RopePoint],
        subdivision: Int,
        sizeScale: Float,
        opacity: Float,
        positions: inout [Float],
        texCoords: inout [Float],
        colors: inout [Float]
    ) {
        guard points.count >= 2 else {
            return
        }

        let segmentCount = points.count - 1

        func point(_ index: Int) -> SIMD3<Float> {
            points[min(max(index, 0), points.count - 1)].position
        }

        func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            let t2 = t * t
            let t3 = t2 * t
            var result = p1 * 2
            result += (p2 - p0) * t
            let quadratic = p0 * 2 - p1 * 5 + p2 * 4 - p3
            result += quadratic * t2
            let cubic = p1 * 3 - p0 - p2 * 3 + p3
            result += cubic * t3
            return result * 0.5
        }

        // Evaluate the spline: positions, widths, colors per sample point.
        var splinePoints: [SIMD3<Float>] = []
        var splineSizes: [Float] = []
        var splineColors: [SIMD4<Float>] = []
        let totalPoints = segmentCount * subdivision + 1
        splinePoints.reserveCapacity(totalPoints)
        splineSizes.reserveCapacity(totalPoints)
        splineColors.reserveCapacity(totalPoints)

        for segment in 0..<segmentCount {
            let p0 = point(segment - 1)
            let p1 = point(segment)
            let p2 = point(segment + 1)
            let p3 = point(segment + 2)
            let c1 = points[segment]
            let c2 = points[segment + 1]
            for step in 0..<subdivision {
                let t = Float(step) / Float(subdivision)
                splinePoints.append(catmullRom(p0, p1, p2, p3, t))
                splineSizes.append(c1.size + (c2.size - c1.size) * t)
                splineColors.append(c1.color + (c2.color - c1.color) * t)
            }
        }
        let last = points[points.count - 1]
        splinePoints.append(last.position)
        splineSizes.append(last.size)
        splineColors.append(last.color)

        // Build the ribbon: two vertices per spline point, quads between points.
        var edges: [(SIMD2<Float>, SIMD2<Float>)] = []
        edges.reserveCapacity(splinePoints.count)
        for index in 0..<splinePoints.count {
            let current = splinePoints[index]
            let previous = splinePoints[max(index - 1, 0)]
            let next = splinePoints[min(index + 1, splinePoints.count - 1)]
            var tangent = SIMD2<Float>(next.x - previous.x, next.y - previous.y)
            let tangentLength = simd_length(tangent)
            tangent = tangentLength > 0.0001 ? tangent / tangentLength : SIMD2<Float>(0, 1)
            let normal = SIMD2<Float>(-tangent.y, tangent.x)
            let halfWidth = splineSizes[index] * sizeScale * 0.5
            let center = SIMD2<Float>(current.x, current.y)
            edges.append((center - normal * halfWidth, center + normal * halfWidth))
        }

        for index in 0..<(edges.count - 1) {
            let v = Float(index) / Float(max(edges.count - 1, 1))
            let vNext = Float(index + 1) / Float(max(edges.count - 1, 1))
            let colorA = splineColors[index]
            let colorB = splineColors[index + 1]
            let alphaA = min(max(colorA.w * opacity, 0), 1)
            let alphaB = min(max(colorB.w * opacity, 0), 1)

            let quad: [(SIMD2<Float>, SIMD2<Float>, SIMD4<Float>)] = [
                (edges[index].0, SIMD2<Float>(0, v), SIMD4<Float>(colorA.x, colorA.y, colorA.z, alphaA)),
                (edges[index].1, SIMD2<Float>(1, v), SIMD4<Float>(colorA.x, colorA.y, colorA.z, alphaA)),
                (edges[index + 1].0, SIMD2<Float>(0, vNext), SIMD4<Float>(colorB.x, colorB.y, colorB.z, alphaB)),
                (edges[index + 1].0, SIMD2<Float>(0, vNext), SIMD4<Float>(colorB.x, colorB.y, colorB.z, alphaB)),
                (edges[index].1, SIMD2<Float>(1, v), SIMD4<Float>(colorA.x, colorA.y, colorA.z, alphaA)),
                (edges[index + 1].1, SIMD2<Float>(1, vNext), SIMD4<Float>(colorB.x, colorB.y, colorB.z, alphaB)),
            ]

            for (position, uv, color) in quad {
                positions.append(contentsOf: [position.x, position.y, 0])
                texCoords.append(contentsOf: [uv.x, uv.y])
                colors.append(contentsOf: [color.x, color.y, color.z, color.w])
            }
        }
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
            const device packed_float3* positions [[buffer(0)]],
            const device float2* texCoords [[buffer(1)]],
            const device float4* colors [[buffer(2)]],
            constant ParticleUniforms& uniforms [[buffer(3)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = uniforms.modelViewProjectionMatrix * float4(float3(positions[vertexID]), 1.0);
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
            if candidate.pathExtension.lowercased() == "tex" {
                if let decoded = WETexDecoder.decode(url: candidate, device: loader.device) {
                    cache[path] = decoded.texture
                    return decoded.texture
                }
                continue
            }
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
        let extensions = ext.isEmpty ? ["png", "tga", "jpg", "jpeg", "tex"] : [ext]

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
