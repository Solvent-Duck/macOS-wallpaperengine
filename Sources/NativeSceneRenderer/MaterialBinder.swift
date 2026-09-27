import Foundation
import Metal
import MetalKit
import NativeSceneCompatibility
import NativeSceneCore
import NativeSceneRuntime
import simd

struct PreparedMaterialPass {
    let pass: FrameMaterialPass
    let pipelineState: MTLRenderPipelineState
    let vertexDescriptor: MTLVertexDescriptor
    let compiledShader: CompiledShaderPair
    let uniformSpecs: [String: UniformSpec]
    let samplerState: MTLSamplerState
    let depthStencilState: MTLDepthStencilState
}

struct UniformSpec: Sendable {
    let name: String
    let type: String
    let materialKey: String?
    let defaultValue: String?  // from shader annotation "default" field
}

struct MaterialBindingContext {
    let viewportSize: CGSize
    let textureOverridesBySlot: [Int: MTLTexture]
    let textureOverridesByName: [String: MTLTexture]
    let uniformOverrides: [String: Data]
    let depthAttachmentPixelFormat: MTLPixelFormat

    init(
        viewportSize: CGSize,
        textureOverridesBySlot: [Int: MTLTexture] = [:],
        textureOverridesByName: [String: MTLTexture] = [:],
        uniformOverrides: [String: Data] = [:],
        depthAttachmentPixelFormat: MTLPixelFormat = .invalid
    ) {
        self.viewportSize = viewportSize
        self.textureOverridesBySlot = textureOverridesBySlot
        self.textureOverridesByName = textureOverridesByName
        self.uniformOverrides = uniformOverrides
        self.depthAttachmentPixelFormat = depthAttachmentPixelFormat
    }
}

final class MaterialBinder {
    private let debugBindings = ProcessInfo.processInfo.environment["WE_DEBUG_BIND"] != nil
    private let device: MTLDevice
    private let assetRoots: [URL]
    private let colorPixelFormat: MTLPixelFormat
    private let textureResolver: SceneTextureResolver
    private let samplerState: MTLSamplerState
    private let repeatSamplerState: MTLSamplerState
    private let fallbackTexture: MTLTexture
    private let emptyMediaTexture: MTLTexture
    /// Artwork textures are replaced, rather than rewritten, so a command buffer
    /// already sampling the old cover retains a stable backing allocation.
    private var currentMediaArtwork: SceneMediaArtwork?
    private var currentMediaTexture: MTLTexture?
    private var previousMediaTexture: MTLTexture?
    private var effectTextureViews: [ObjectIdentifier: MTLTexture] = [:]

    private var pipelineCache: [String: PreparedMaterialPass] = [:]
    private var failedShaderKeys: Set<String> = []
    /// Cache of zero-filled buffers keyed by (shaderKey, bufferIndex).
    private var zeroBufferCache: [String: MTLBuffer] = [:]
    /// Track which shaders we've already warned about unknown attributes (once per shader).
    private var warnedUnknownAttributes: Set<String> = []
    private var warnedMissingUniforms: Set<String> = []
    private var sceneCombos: [String: Int] = [:]

    private static let zeroUniformData = Data(repeating: 0, count: 64)

    init(
        device: MTLDevice,
        assetRoots: [URL],
        colorPixelFormat: MTLPixelFormat
    ) throws {
        self.device = device
        self.assetRoots = assetRoots
        self.colorPixelFormat = colorPixelFormat
        self.textureResolver = SceneTextureResolver(device: device, roots: assetRoots)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to create default sampler state")
        }
        self.samplerState = samplerState

        let repeatDescriptor = MTLSamplerDescriptor()
        repeatDescriptor.minFilter = .linear
        repeatDescriptor.magFilter = .linear
        repeatDescriptor.mipFilter = .linear
        repeatDescriptor.sAddressMode = .repeat
        repeatDescriptor.tAddressMode = .repeat
        guard let repeatSamplerState = device.makeSamplerState(descriptor: repeatDescriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to create repeat sampler state")
        }
        self.repeatSamplerState = repeatSamplerState
        self.fallbackTexture = try Self.makeFallbackTexture(device: device)
        self.emptyMediaTexture = try Self.makeFallbackTexture(device: device, transparent: true)
    }

    /// Clear per-frame views of numerical effect targets.
    func resetEffectTextureViews() {
        effectTextureViews.removeAll(keepingCapacity: true)
    }

    func removeSceneLayers(_ ids: Set<NodeID>) {
        textureResolver.removeSceneLayers(ids)
    }

    var controlledVideoPlayerCount: Int { textureResolver.controlledVideoPlayerCount }

    func setEffectTextureView(_ view: MTLTexture, for texture: MTLTexture) {
        effectTextureViews[ObjectIdentifier(texture)] = view
    }

    func sampledTexture(for texture: MTLTexture) -> MTLTexture {
        effectTextureViews[ObjectIdentifier(texture)] ?? texture
    }

    /// Updates the two authored media-cover bindings. Repeating equal artwork
    /// preserves the previous cover; only a distinct pixel payload advances it.
    func updateMediaArtwork(_ artwork: SceneMediaArtwork?) {
        guard artwork != currentMediaArtwork else { return }
        guard let artwork else {
            currentMediaArtwork = nil
            currentMediaTexture = nil
            previousMediaTexture = nil
            return
        }
        guard let replacement = makeMediaTexture(artwork) else {
            currentMediaArtwork = nil
            currentMediaTexture = nil
            previousMediaTexture = nil
            return
        }
        previousMediaTexture = currentMediaTexture
        currentMediaTexture = replacement
        currentMediaArtwork = artwork
    }

    func updateSceneLighting(packet: FramePacket, scene: SceneDescription) {
        sceneCombos = ["SCENE_ORTHO": scene.scene?.camera.projection.isPerspective == true ? 0 : 1]
        for (type, name) in ["LIGHTS_POINT", "LIGHTS_SPOT", "LIGHTS_TUBE", "LIGHTS_DIRECTIONAL"].enumerated() {
            // Keep the shader layout stable as scripted visibility changes.
            // Hidden lights retain their slot and receive a zero color.
            sceneCombos[name] = packet.lights.filter { $0.type == type }.count
        }
    }

    func preparePass(material: FrameMaterial, pass authoredPass: FrameMaterialPass,
                     bindingContext: MaterialBindingContext? = nil,
                     colorAttachmentPixelFormat: MTLPixelFormat? = nil) throws -> PreparedMaterialPass {
        var combos = authoredPass.combos.merging(sceneCombos) { _, sceneValue in sceneValue }
        // The supplied generic3 shaders use the modern color/intensity layout
        // from version 62 onward. Preserve an explicitly authored older ABI.
        if combos["SHADERVERSION"] == nil { combos["SHADERVERSION"] = 62 }
        let context = bindingContext ?? MaterialBindingContext(viewportSize: .zero)
        let attachmentFormat = colorAttachmentPixelFormat ?? colorPixelFormat
        // Effect binds can supply slots absent from the material's texture list.
        let formatSlots = Set([0] + (authoredPass.textures + authoredPass.userTextures).map(\.slot))
            .union(context.textureOverridesBySlot.keys)
        for slot in formatSlots {
            guard let texture = try resolveTexture(name: "g_Texture\(slot)", slot: slot, pass: authoredPass,
                                                    bindingContext: context, defaultPath: nil) else { continue }
            // RG stores luminance/alpha; R stores an alpha mask. WE shaders
            // convert these channels through the texture format combo.
            switch texture.pixelFormat {
            case .bc3_rgba: combos["TEX\(slot)FORMAT"] = 4
            case .bc2_rgba: combos["TEX\(slot)FORMAT"] = 6
            case .bc1_rgba: combos["TEX\(slot)FORMAT"] = 7
            case .rg8Unorm: combos["TEX\(slot)FORMAT"] = 8
            case .r8Unorm: combos["TEX\(slot)FORMAT"] = 9
            case .rg16Float: combos["TEX\(slot)FORMAT"] = 10
            case .r16Float: combos["TEX\(slot)FORMAT"] = 11
            default: combos["TEX\(slot)FORMAT"] = 0
            }
            if slot == 0, authoredPass.shaderPath.lowercased().contains("genericimage"),
               textureResolver.hasAnimation(texture) { combos["SPRITESHEET"] = 1 }
        }
        let pass = FrameMaterialPass(index: authoredPass.index, shaderPath: authoredPass.shaderPath,
            blending: authoredPass.blending, culling: authoredPass.culling,
            depthTest: authoredPass.depthTest, depthWrite: authoredPass.depthWrite,
            textures: authoredPass.textures, userTextures: authoredPass.userTextures,
            constants: authoredPass.constants, combos: combos)
        let textureSlots = Set((pass.textures + pass.userTextures).filter { !$0.path.isEmpty }.map(\.slot))
        let key = cacheKey(material: material, pass: pass)
            + "#color:\(attachmentFormat.rawValue)"
            + "#textures:\(textureSlots.sorted())#depth:\(context.depthAttachmentPixelFormat.rawValue):\(pass.depthTest):\(pass.depthWrite)"
        if let cached = pipelineCache[key] {
            // Only the compiled GPU state is shared. Constants and textures
            // belong to this layer and this frame, including animated values.
            return PreparedMaterialPass(
                pass: pass,
                pipelineState: cached.pipelineState,
                vertexDescriptor: cached.vertexDescriptor,
                compiledShader: cached.compiledShader,
                uniformSpecs: cached.uniformSpecs,
                samplerState: cached.samplerState,
                depthStencilState: cached.depthStencilState
            )
        }
        if failedShaderKeys.contains(key) {
            throw ShaderPipelineError.compilationFailed("cached failure for \(pass.shaderPath)")
        }

        do {
            let compiled = try ShaderPipeline.compile(
                ShaderCompilationRequest(
                    shaderPath: pass.shaderPath,
                    assetRoots: assetRoots,
                    combos: pass.combos,
                    textureSlots: textureSlots
                )
            )

            let uniformSpecs = parseUniforms(
                vertexGLSL: compiled.vertexGLSL,
                fragmentGLSL: compiled.fragmentGLSL
            )
            let vertexDescriptor = makeVertexDescriptor(from: compiled.metal.vertexAttributes)
            let vertexLibrary = try device.makeLibrary(source: compiled.metal.vertexMSL, options: nil)
            let fragmentLibrary = try device.makeLibrary(source: compiled.metal.fragmentMSL, options: nil)

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexLibrary.makeFunction(name: "main0")
            descriptor.fragmentFunction = fragmentLibrary.makeFunction(name: "main0")
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.colorAttachments[0].pixelFormat = attachmentFormat
            configureBlending(pass.blending, descriptor: descriptor)
            descriptor.depthAttachmentPixelFormat = context.depthAttachmentPixelFormat
            let depth = MTLDepthStencilDescriptor()
            let hasDepth = context.depthAttachmentPixelFormat != .invalid
            depth.depthCompareFunction = hasDepth && pass.depthTest != 0 ? .lessEqual : .always
            depth.isDepthWriteEnabled = hasDepth && pass.depthWrite != 0
            // Metal validation rejects setting nil. A disabled state also
            // resets depth when a later pass shares an existing encoder.
            guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
                throw NativeSceneRendererError.unsupportedScene("failed to allocate material depth state")
            }

            let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            let prepared = PreparedMaterialPass(
                pass: pass,
                pipelineState: pipelineState,
                vertexDescriptor: vertexDescriptor,
                compiledShader: compiled,
                uniformSpecs: uniformSpecs,
                samplerState: samplerState,
                depthStencilState: depthState
            )
            pipelineCache[key] = prepared
            return prepared
        } catch {
            print("[MaterialBinder] Shader '\(pass.shaderPath)' failed (cached): \(error.localizedDescription)")
            failedShaderKeys.insert(key)
            throw error
        }
    }

    func particleAtlas(for pass: FrameMaterialPass) throws -> ParticleTextureAtlas? {
        guard let path = pass.textures.first(where: { $0.slot == 0 })?.path
                ?? pass.userTextures.first(where: { $0.slot == 0 })?.path else { return nil }
        guard let texture = try textureResolver.resolveTexture(named: path) else { return nil }
        return textureResolver.atlas(for: texture)
    }

    func bind(
        preparedPass: PreparedMaterialPass,
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        scene: SceneDescription,
        packet: FramePacket,
        positions: MTLBuffer,
        texCoords: MTLBuffer,
        vertexCount: Int,
        encoder: MTLRenderCommandEncoder,
        bindingContext: MaterialBindingContext,
        vertexAttributeBuffers: [String: MTLBuffer] = [:]
    ) throws {
        encoder.setRenderPipelineState(preparedPass.pipelineState)
        encoder.setDepthStencilState(preparedPass.depthStencilState)
        if bindingContext.depthAttachmentPixelFormat != .invalid {
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(preparedPass.pass.culling != 0 ? .back : .none)
        }

        // Bind vertex attribute buffers using shader metadata (indices assigned alphabetically by name).
        let attributes = preparedPass.compiledShader.metal.vertexAttributes
        let shaderKey = preparedPass.pass.shaderPath

        if debugBindings {
            let attrs = attributes.map { "\($0.name) loc=\($0.location) buf=\($0.bufferIndex) vec=\($0.vecSize)" }
            print("[BindDebug] shader=\(shaderKey) attrs=[\(attrs.joined(separator: "; "))] vtxUniforms=\(preparedPass.compiledShader.metal.vertexUniformSlots) vtxCount=\(vertexCount)")
            let ptr = positions.contents().bindMemory(to: Float.self, capacity: 18)
            let first = (0..<min(18, vertexCount * 3)).map { String(format: "%.1f", ptr[$0]) }
            print("[BindDebug] positions[0..18]=\(first.joined(separator: ","))")
            let sceneProjectionDbg = projectionMatrix(scene: scene, viewportSize: bindingContext.viewportSize, cameraZoom: packet.cameraZoom)
            let conversionDbg = sceneCoordinateConversion(scene: scene, viewportSize: bindingContext.viewportSize)
            let modelDbg = simd_mul(conversionDbg, frameNode.worldTransform.simdValue)
            let mvpDbg = simd_mul(sceneProjectionDbg, modelDbg)
            for (label, matrix) in [("world", frameNode.worldTransform.simdValue), ("mvp", mvpDbg)] {
                let cols = (0..<4).map { c in (0..<4).map { r in String(format: "%.3f", matrix[c][r]) }.joined(separator: ",") }
                print("[BindDebug] \(label) cols: \(cols.joined(separator: " | "))")
            }
            let corner = simd_mul(mvpDbg, SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1))
            print("[BindDebug] corner0 -> \(corner)")
        }

        for attribute in attributes {
            let idx = Int(attribute.bufferIndex)
            if let buffer = vertexAttributeBuffers[attribute.name] {
                encoder.setVertexBuffer(buffer, offset: 0, index: idx)
            } else if attribute.name.contains("Position") {
                encoder.setVertexBuffer(positions, offset: 0, index: idx)
            } else if attribute.name.contains("TexCoord") {
                encoder.setVertexBuffer(texCoords, offset: 0, index: idx)
            } else {
                // Unknown attribute — bind a zero-filled buffer of the right size.
                let cacheKey = "\(shaderKey):\(idx)"
                let zeroBuffer: MTLBuffer
                let byteCount = max(Int(attribute.vecSize) * vertexCount * MemoryLayout<Float>.stride, 1)
                if let cached = zeroBufferCache[cacheKey], cached.length >= byteCount {
                    zeroBuffer = cached
                } else {
                    guard let buf = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                        throw NativeSceneRendererError.unsupportedScene("failed to allocate zero buffer for attribute \(attribute.name)")
                    }
                    memset(buf.contents(), 0, buf.length)
                    zeroBufferCache[cacheKey] = buf
                    zeroBuffer = buf
                }

                if !warnedUnknownAttributes.contains(cacheKey) {
                    print("[MaterialBinder] Unknown vertex attribute '\(attribute.name)' (bufferIndex \(idx)) — zero-filling")
                    warnedUnknownAttributes.insert(cacheKey)
                }

                encoder.setVertexBuffer(zeroBuffer, offset: 0, index: idx)
            }
        }

        let sceneProjection = projectionMatrix(scene: scene, viewportSize: bindingContext.viewportSize, cameraZoom: packet.cameraZoom)
        let sceneConversion = sceneCoordinateConversion(scene: scene, viewportSize: bindingContext.viewportSize)
        let modelMatrix = frameNode.worldTransform.simdValue
        let mvp = sceneProjection * sceneConversion * modelMatrix
        var resolvedTextures = try resolveTextures(
            preparedPass: preparedPass,
            bindingContext: bindingContext
        )
        var uniformOverrides = bindingContext.uniformOverrides
        let primaryPath = nodeDescriptor.image?.model?.material?.passes.first?.textures.first(where: { $0.slot == 0 })?.path
        for (name, texture) in resolvedTextures {
            if let sampled = textureResolver.videoSample(for: texture, primaryPath: primaryPath,
                nodeID: frameNode.nodeID, time: name == "g_Texture0" ? frameNode.videoTextureTime : nil,
                sharedTime: packet.timing.elapsedTime) {
                resolvedTextures[name] = sampled
            }
        }
        if nodeDescriptor.image != nil, let texture = resolvedTextures["g_Texture0"] {
            let sample = textureResolver.animationSample(for: texture, primaryPath: primaryPath,
                controlledTime: frameNode.textureAnimationTime, sharedTime: packet.timing.elapsedTime)
            if let sample {
                resolvedTextures["g_Texture0"] = sample.texture
                if uniformOverrides["g_Texture0Rotation"] == nil { uniformOverrides["g_Texture0Rotation"] = bytes(of: sample.frame.rotation) }
                if uniformOverrides["g_Texture0Translation"] == nil { uniformOverrides["g_Texture0Translation"] = bytes(of: sample.frame.translation) }
            }
        }

        let uniformData = buildUniformBindings(
            preparedPass: preparedPass,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            scene: scene,
            packet: packet,
            viewportSize: bindingContext.viewportSize,
            modelMatrix: modelMatrix,
            modelViewProjectionMatrix: mvp,
            resolvedTextures: resolvedTextures,
            uniformOverrides: uniformOverrides
        )

        for (name, slot) in preparedPass.compiledShader.metal.vertexUniformSlots {
            let data = uniformData[name] ?? {
                let warnKey = "\(preparedPass.pass.shaderPath):\(name)"
                if !warnedMissingUniforms.contains(warnKey) {
                    print("[MaterialBinder] Uniform '\(name)' not bound for shader '\(preparedPass.pass.shaderPath)' — using zero fallback")
                    warnedMissingUniforms.insert(warnKey)
                }
                return MaterialBinder.zeroUniformData
            }()
            data.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: data.count, index: Int(slot))
            }
        }

        for (name, slot) in preparedPass.compiledShader.metal.fragmentUniformSlots {
            let data = uniformData[name] ?? {
                let warnKey = "\(preparedPass.pass.shaderPath):\(name)"
                if !warnedMissingUniforms.contains(warnKey) {
                    print("[MaterialBinder] Uniform '\(name)' not bound for shader '\(preparedPass.pass.shaderPath)' — using zero fallback")
                    if debugBindings {
                        if let spec = preparedPass.uniformSpecs[name] {
                            print("[BindDebug] spec for \(name): type=\(spec.type) materialKey=\(spec.materialKey ?? "-") default=\(spec.defaultValue ?? "-")")
                        } else {
                            print("[BindDebug] no uniform spec parsed for \(name); parsed specs: \(preparedPass.uniformSpecs.keys.sorted())")
                        }
                        for sourceLine in preparedPass.compiledShader.fragmentGLSL.split(whereSeparator: \.isNewline)
                        where sourceLine.contains("uniform") && sourceLine.contains(name) {
                            print("[BindDebug] fragment line: \(sourceLine)")
                        }
                        for sourceLine in preparedPass.compiledShader.vertexGLSL.split(whereSeparator: \.isNewline)
                        where sourceLine.contains("uniform") && sourceLine.contains(name) {
                            print("[BindDebug] vertex line: \(sourceLine)")
                        }
                    }
                    warnedMissingUniforms.insert(warnKey)
                }
                return MaterialBinder.zeroUniformData
            }()
            data.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: data.count, index: Int(slot))
            }
        }

        for (name, slot) in preparedPass.compiledShader.metal.fragmentTextureSlots {
            let texture = resolvedTextures[name] ?? fallbackTexture
            encoder.setFragmentTexture(texture, index: Int(slot))
        }

        for (samplerName, slot) in preparedPass.compiledShader.metal.fragmentSamplerSlots {
            // SPIRV-Cross names samplers "<texture>Smplr"; honor the paired
            // texture's WE flags (repeat is the WE default; RTT overrides and
            // unknown textures stay clamped).
            let textureName = samplerName
                .replacingOccurrences(of: "Smplr", with: "")
                .replacingOccurrences(of: "Sampler", with: "")
            var chosen = samplerState
            if let texture = resolvedTextures[textureName],
               textureResolver.prefersRepeatSampling(texture) {
                chosen = repeatSamplerState
            }
            encoder.setFragmentSamplerState(chosen, index: Int(slot))
        }
    }

    /// Only reflected samplers can read the render attachment. Resolution
    /// uniforms and unused authored textures do not require a scene copy.
    func samplesTexture(
        _ texture: MTLTexture,
        preparedPass: PreparedMaterialPass,
        bindingContext: MaterialBindingContext
    ) throws -> Bool {
        for (name, slot) in preparedPass.compiledShader.metal.fragmentTextureSlots {
            if let sampled = try resolveTexture(
                name: name, slot: Int(slot), pass: preparedPass.pass,
                bindingContext: bindingContext,
                defaultPath: preparedPass.uniformSpecs[name]?.defaultValue
            ), sampled === sampledTexture(for: texture) {
                return true
            }
        }
        return false
    }

    /// Check the active shader's logical bindings before opening a render
    /// encoder. Scene mipmaps must be generated by a separate blit encoder.
    func requiresSceneMipmaps(preparedPass: PreparedMaterialPass, bindingContext: MaterialBindingContext,
                              sceneMipMapSlots: Set<Int> = []) -> Bool {
        var bindings = preparedPass.compiledShader.metal.fragmentTextureSlots.mapValues { Int($0) }
        let uniformNames = Set(preparedPass.compiledShader.metal.vertexUniformSlots.keys)
            .union(preparedPass.compiledShader.metal.fragmentUniformSlots.keys)
        for name in uniformNames {
            if let slot = textureMipMapInfoSlot(for: name) { bindings["g_Texture\(slot)"] = slot }
        }
        for (name, metalSlot) in bindings {
            let slot = textureSlot(for: name) ?? metalSlot
            if bindingContext.textureOverridesByName[name] != nil { continue }
            if sceneMipMapSlots.contains(slot) { return true }
            if bindingContext.textureOverridesBySlot[slot] != nil { continue }
            let texture = preparedPass.pass.textures.first { $0.slot == slot }
                ?? preparedPass.pass.userTextures.first { $0.slot == slot }
            if (texture?.path ?? preparedPass.uniformSpecs[name]?.defaultValue) == "_rt_MipMappedFrameBuffer" { return true }
        }
        return false
    }

    private func resolveTextures(
        preparedPass: PreparedMaterialPass,
        bindingContext: MaterialBindingContext
    ) throws -> [String: MTLTexture] {
        var textures: [String: MTLTexture] = [:]

        for (name, slot) in preparedPass.compiledShader.metal.fragmentTextureSlots {
            let texture = try resolveTexture(
                name: name,
                slot: Int(slot),
                pass: preparedPass.pass,
                bindingContext: bindingContext,
                defaultPath: preparedPass.uniformSpecs[name]?.defaultValue
            ) ?? fallbackTexture
            textures[name] = texture
        }

        // A shader may use texture dimensions or mip metadata without sampling
        // it. Metal then removes the sampler, but those uniforms still need
        // the authored texture or the current effect input's actual metadata.
        let uniformNames = Set(preparedPass.compiledShader.metal.vertexUniformSlots.keys)
            .union(preparedPass.compiledShader.metal.fragmentUniformSlots.keys)
        for name in uniformNames {
            guard let slot = textureResolutionSlot(for: name) ?? textureMipMapInfoSlot(for: name) else { continue }
            let textureName = "g_Texture\(slot)"
            guard textures[textureName] == nil else { continue }
            textures[textureName] = try resolveTexture(
                name: textureName, slot: slot, pass: preparedPass.pass,
                bindingContext: bindingContext,
                defaultPath: preparedPass.uniformSpecs[textureName]?.defaultValue
            ) ?? fallbackTexture
        }

        if debugBindings {
            let summary = textures
                .sorted { $0.key < $1.key }
                .map { "\($0.key)->\($0.value.width)x\($0.value.height)" }
                .joined(separator: " ")
            print("[BindDebug] textures shader=\(preparedPass.pass.shaderPath): \(summary)")
        }

        return textures
    }

    private func resolveTexture(
        name: String,
        slot: Int,
        pass: FrameMaterialPass,
        bindingContext: MaterialBindingContext,
        defaultPath: String?
    ) throws -> MTLTexture? {
        if let override = bindingContext.textureOverridesByName[name] {
            return sampledTexture(for: override)
        }

        // Slot overrides are keyed by the WE texture index (the N in
        // g_TextureN). The MSL slot from reflection is use-ordered and can
        // permute those indices (e.g. a fragment sampling g_Texture2 before
        // g_Texture1), so the name-derived index must win.
        let preferredSlot = textureSlot(for: name) ?? slot
        if let override = bindingContext.textureOverridesBySlot[preferredSlot] {
            return sampledTexture(for: override)
        }
        // An optimized-out sampler can make g_Texture1 occupy Metal slot 0.
        // Slot 0's chain input must never replace that separately authored
        // texture; reflection indices are only for the encoder bindings.
        let textureBinding = pass.textures.first(where: { $0.slot == preferredSlot }) ?? pass.userTextures.first(where: { $0.slot == preferredSlot })
        guard let path = textureBinding?.path ?? defaultPath else {
            return fallbackTexture
        }
        if let override = bindingContext.textureOverridesByName[path] {
            return sampledTexture(for: override)
        }
        if textureBinding?.sourceType == "system",
           path == "$mediaThumbnail" || path == "$mediaPreviousThumbnail" {
            let artwork = path == "$mediaThumbnail" ? currentMediaTexture : previousMediaTexture
            if let artwork { return artwork }
            // A missing current/previous cover retains the wallpaper's own
            // placeholder, including its alpha. Only an absent placeholder is transparent.
            if let fallbackPath = textureBinding?.fallbackPath ?? defaultPath {
                if let override = bindingContext.textureOverridesByName[fallbackPath] {
                    return sampledTexture(for: override)
                }
                if let placeholder = try textureResolver.resolveTexture(named: fallbackPath) { return placeholder }
            }
            return emptyMediaTexture
        }
        return try textureResolver.resolveTexture(named: path) ?? fallbackTexture
    }

    private func buildUniformBindings(
        preparedPass: PreparedMaterialPass,
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        scene: SceneDescription,
        packet: FramePacket,
        viewportSize: CGSize,
        modelMatrix: simd_float4x4,
        modelViewProjectionMatrix: simd_float4x4,
        resolvedTextures: [String: MTLTexture],
        uniformOverrides: [String: Data]
    ) -> [String: Data] {
        var bindings: [String: Data] = [:]
        let constants = preparedPass.pass.constants
        let lightUniforms = buildLightUniformBindings(packet: packet, scene: scene)

        for spec in preparedPass.uniformSpecs.values {
            if let override = uniformOverrides[spec.name] {
                bindings[spec.name] = override
                continue
            }

            let data: Data?

            switch spec.name {
            case "g_ModelViewProjectionMatrix":
                data = bytes(of: modelViewProjectionMatrix)
            case "g_ModelViewProjectionMatrixInverse":
                data = bytes(of: simd_inverse(modelViewProjectionMatrix))
            case "g_ModelMatrix", "g_AltModelMatrix":
                data = bytes(of: modelMatrix)
            case "g_ModelMatrixInverse":
                data = bytes(of: simd_inverse(modelMatrix))
            case "g_LayerModelMatrix":
                // Effects render into local intermediate targets, but still
                // need the original layer transform for scale-aware shapes.
                data = bytes(of: modelMatrix)
            case "g_ViewProjectionMatrix", "g_AltViewProjectionMatrix":
                data = bytes(of: sceneViewProjection(scene: scene, viewportSize: viewportSize, cameraZoom: packet.cameraZoom))
            case "g_NormalModelMatrix", "g_AltNormalModelMatrix":
                data = bytes(of: Self.normalMatrix(for: modelMatrix))
            case "g_Time":
                data = bytes(of: Float(packet.timing.elapsedTime))
            case "g_Frametime":
                data = bytes(of: Float(packet.timing.deltaTime))
            case "g_TextureReductionScale":
                // Image intermediates currently retain their authored size;
                // no global texture-quality reduction is applied. Blend/skew
                // effects divide pixel offsets by this factor, so zero makes
                // their texture coordinates invalid even with zero offsets.
                data = bytes(of: Float(1))
            case "g_Daytime":
                let daytime = Float(Self.daytimeFraction())
                data = bytes(of: daytime)
            case "g_Texture0Rotation":
                data = bytes(of: SIMD4<Float>(1, 0, 0, 1))
            case "g_Texture0Translation":
                data = bytes(of: SIMD2<Float>(0, 0))
            case let name where textureResolutionSlot(for: name) != nil:
                let slot = textureResolutionSlot(for: name) ?? 0
                let textureName = "g_Texture\(slot)"
                if let texture = resolvedTextures[textureName] {
                    // WE semantics: xy = storage size, zw = real image size.
                    if let resolution = textureResolver.resolution(for: texture) {
                        data = bytes(of: resolution)
                    } else {
                        data = bytes(of: SIMD4<Float>(
                            Float(texture.width),
                            Float(texture.height),
                            Float(texture.width),
                            Float(texture.height)
                        ))
                    }
                } else {
                    data = bytes(of: SIMD4<Float>(1, 1, 1, 1))
                }
            case let name where textureMipMapInfoSlot(for: name) != nil:
                let slot = textureMipMapInfoSlot(for: name) ?? 0
                data = bytes(of: Float(max((resolvedTextures["g_Texture\(slot)"]?.mipmapLevelCount ?? 1) - 1, 0)))
            case "g_PointerPosition":
                let cursor = packet.cursor?.normalized ?? RuntimeVector2(x: 0.5, y: 0.5)
                data = bytes(of: SIMD2<Float>(min(max(cursor.x, 0), 1), min(max(cursor.y, 0), 1)))
            case "g_PointerPositionLast":
                let cursor = packet.cursor?.previousNormalized ?? RuntimeVector2(x: 0.5, y: 0.5)
                data = bytes(of: SIMD2<Float>(min(max(cursor.x, 0), 1), min(max(cursor.y, 0), 1)))
            case "g_PointerState":
                // Shipped ripple and fluid shaders use z as added click force.
                // X/Y/W retain zero until their Wallpaper Engine semantics are evidenced.
                data = bytes(of: SIMD4<Float>(0, 0, packet.cursor?.leftDown == true ? 1 : 0, 0))
            case "g_ParallaxPosition":
                // Depth-parallax effects recenter around the pointer; 0.5/0.5
                // is the neutral center.
                let cursor = packet.cursor?.normalized ?? RuntimeVector2(x: 0.5, y: 0.5)
                data = bytes(of: SIMD2<Float>(min(max(cursor.x, 0), 1), min(max(cursor.y, 0), 1)))
            case "g_EffectTextureProjectionMatrix",
                 "g_EffectTextureProjectionMatrixInverse",
                 "g_EffectModelViewProjectionMatrix",
                 "g_EffectModelViewProjectionMatrixInverse":
                // Effects render in plain texture space here, so the effect
                // projection is identity. A zero fallback would NaN out
                // shaders that normalize projected axes (depthparallax).
                data = bytes(of: matrix_identity_float4x4)
            case let name where name.hasPrefix("g_AudioSpectrum"):
                data = Self.audioSpectrumUniform(name: name, spectrum: packet.audio?.spectrum ?? [])
            case "g_EyePosition":
                let eye = scene.scene?.camera.configuration.eye ?? [0, 0, 1]
                let resolvedEye = RuntimeVector3(eye, default: RuntimeVector3(x: 0, y: 0, z: 1))
                data = bytes(of: SIMD3<Float>(resolvedEye.x, resolvedEye.y, resolvedEye.z))
            case "g_Screen":
                let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
                data = bytes(of: SIMD3<Float>(
                    Float(projectionSize.width),
                    Float(projectionSize.height),
                    Float(sceneAspect(scene: scene, viewportSize: viewportSize))
                ))
            case "g_TexelSize":
                let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
                data = bytes(of: SIMD2<Float>(
                    1 / max(Float(projectionSize.width), 1),
                    1 / max(Float(projectionSize.height), 1)
                ))
            case "g_TexelSizeHalf":
                let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
                data = bytes(of: SIMD2<Float>(
                    0.5 / max(Float(projectionSize.width), 1),
                    0.5 / max(Float(projectionSize.height), 1)
                ))
            case "g_Color4":
                let alpha = Float(frameNode.opacity ?? 1)
                let color = frameNode.color ?? RuntimeVector3(x: 1, y: 1, z: 1)
                data = bytes(of: SIMD4<Float>(color.x, color.y, color.z, alpha))
            case "g_Color", "g_Alpha":
                // Effect parameters may use these same names. Authored
                // material values/defaults take precedence over layer tint.
                if let value = constants[spec.materialKey ?? spec.name] ?? constants[spec.name] {
                    data = encode(value: value, as: spec.type, fallbackOpacity: frameNode.opacity)
                } else if let value = spec.defaultValue {
                    data = encodeDefault(value, as: spec.type)
                } else if spec.name == "g_Alpha" {
                    data = bytes(of: Float(frameNode.opacity ?? 1))
                } else {
                    let color = frameNode.color ?? RuntimeVector3(x: 1, y: 1, z: 1)
                    data = bytes(of: SIMD3<Float>(color.x, color.y, color.z))
                }
            case let name where lightUniforms[name] != nil:
                data = lightUniforms[name]
            default:
                let lookupKey = spec.materialKey ?? spec.name
                let sourceValue = constants[lookupKey] ?? constants[spec.name]
                if let sourceValue {
                    data = encode(value: sourceValue, as: spec.type, fallbackOpacity: frameNode.opacity)
                } else if let defaultStr = spec.defaultValue {
                    data = encodeDefault(defaultStr, as: spec.type)
                } else {
                    data = nil
                }
            }

            if let data {
                bindings[spec.name] = data
            }
        }

        if bindings["g_UserAlpha"] == nil {
            bindings["g_UserAlpha"] = bytes(of: Float(frameNode.opacity ?? 1))
        }
        if bindings["g_Brightness"] == nil {
            bindings["g_Brightness"] = bytes(of: Float(1))
        }
        if bindings["g_Power"] == nil {
            bindings["g_Power"] = bytes(of: Float(1))
        }

        return bindings
    }

    /// Encodes `g_AudioSpectrum{16,32,64}{Left,Right}` float arrays from the
    /// captured 128-band spectrum. Elements use std140 layout (16-byte stride)
    /// to match the translated shader's uniform block layout. Mono capture
    /// feeds both channels.
    private static func audioSpectrumUniform(name: String, spectrum: [Float]) -> Data? {
        let bandCount: Int
        if name.contains("64") {
            bandCount = 64
        } else if name.contains("32") {
            bandCount = 32
        } else if name.contains("16") {
            bandCount = 16
        } else {
            return nil
        }

        var padded = [SIMD4<Float>](repeating: .zero, count: bandCount)
        if !spectrum.isEmpty {
            let groupSize = max(spectrum.count / bandCount, 1)
            for band in 0..<bandCount {
                let start = min(band * groupSize, spectrum.count - 1)
                let end = min(start + groupSize, spectrum.count)
                var sum: Float = 0
                for index in start..<end {
                    sum += spectrum[index]
                }
                padded[band] = SIMD4<Float>(sum / Float(max(end - start, 1)), 0, 0, 0)
            }
        }
        return bytes(of: padded)
    }

    private func buildLightUniformBindings(packet: FramePacket, scene: SceneDescription) -> [String: Data] {
        let ambient = RuntimeVector3(scene.scene?.ambientColor ?? [0.001, 0.001, 0.001], default: RuntimeVector3(x: 0.001, y: 0.001, z: 0.001))
        let skylight = RuntimeVector3(scene.scene?.skylightColor ?? [0, 0, 0], default: .zero)

        var pointOrigins: [SIMD4<Float>] = []
        var pointColors: [SIMD4<Float>] = []
        var pointFalloffs: [SIMD4<Float>] = []
        var spotOrigins: [SIMD4<Float>] = []
        var spotDirections: [SIMD4<Float>] = []
        var spotColors: [SIMD4<Float>] = []
        var spotFalloffs: [SIMD4<Float>] = []
        var tubeOriginsA: [SIMD4<Float>] = []
        var tubeOriginsB: [SIMD4<Float>] = []
        var tubeColors: [SIMD4<Float>] = []
        var tubeFalloffs: [SIMD4<Float>] = []
        var directionalDirections: [SIMD4<Float>] = []
        var directionalColors: [SIMD4<Float>] = []

        let visibleLights = packet.lights.filter(\.visible)
        for light in packet.lights {
            let direction = lightDirection(for: light)
            let exponent = light.exponent ?? 2
            let falloff = SIMD4<Float>(
                light.radius.isFinite ? max(Float(light.radius), 0.001) : 0.001,
                exponent.isFinite ? max(Float(exponent), 0) : 2, 0, 0
            )
            let color = light.visible ? SIMD4<Float>(
                light.color.x,
                light.color.y,
                light.color.z,
                Float(light.intensity)
            ) : .zero

            switch light.type {
            case 0:
                pointOrigins.append(
                    SIMD4<Float>(
                        light.position.x,
                        light.position.y,
                        light.position.z,
                        max(Float(light.radius), 0.001)
                    )
                )
                pointColors.append(color)
                pointFalloffs.append(falloff)
            case 1:
                let innerCone = normalizedConeAngle(light.innerCone)
                let outerCone = normalizedConeAngle(light.outerCone)
                let clampedInner = min(innerCone, outerCone)
                let clampedOuter = max(innerCone, outerCone)
                // Stock consumers call smoothstep(direction.w, origin.w, cos).
                // Cosine decreases as the cone widens: outer must come first.
                spotOrigins.append(
                    SIMD4<Float>(
                        light.position.x,
                        light.position.y,
                        light.position.z,
                        cos(clampedInner)
                    )
                )
                spotDirections.append(
                    SIMD4<Float>(
                        direction.x,
                        direction.y,
                        direction.z,
                        cos(clampedOuter)
                    )
                )
                spotColors.append(color)
                spotFalloffs.append(falloff)
            case 2:
                let halfLength = max(Float(light.length), 0) * 0.5
                let offset = direction * halfLength
                let start = light.endPosition == nil ? light.position.simdValue - offset : light.position.simdValue
                let end = light.endPosition?.simdValue ?? light.position.simdValue + offset
                tubeOriginsA.append(
                    SIMD4<Float>(
                        start.x,
                        start.y,
                        start.z,
                        max(Float(light.radius), 0.001)
                    )
                )
                tubeOriginsB.append(
                    SIMD4<Float>(
                        end.x,
                        end.y,
                        end.z,
                        max(Float(light.radius), 0.001)
                    )
                )
                tubeColors.append(color)
                tubeFalloffs.append(falloff)
            case 3:
                directionalDirections.append(SIMD4<Float>(direction.x, direction.y, direction.z, 0))
                directionalColors.append(color)
            default:
                continue
            }
        }

        // Legacy generic shaders unconditionally read four positions and pack
        // the fourth light's RGB into the W components of three color vectors.
        // Missing lights must be zero-filled, not encoded as extra intensity.
        var genericPositions = [SIMD3<Float>](repeating: .zero, count: 4)
        var genericColors = [SIMD4<Float>](repeating: .zero, count: 3)
        for (index, light) in visibleLights.prefix(4).enumerated() {
            genericPositions[index] = SIMD3<Float>(light.position.x, light.position.y, light.position.z)
            let color = SIMD3<Float>(light.color.x, light.color.y, light.color.z) * Float(light.intensity)
            if index < 3 {
                genericColors[index] = SIMD4<Float>(color.x, color.y, color.z, 0)
            } else {
                for channel in 0..<3 { genericColors[channel].w = color[channel] }
            }
        }

        let countBindings: [String: Data] = [
            "g_LightCount": bytes(of: Int32(visibleLights.count)),
            "g_LightPointCount": bytes(of: Int32(pointOrigins.count)),
            "g_LightSpotCount": bytes(of: Int32(spotOrigins.count)),
            "g_LightTubeCount": bytes(of: Int32(tubeOriginsA.count)),
            "g_LightDirectionalCount": bytes(of: Int32(directionalDirections.count)),
        ]

        var result: [String: Data] = [
            "g_LightAmbientColor": bytes(of: SIMD3<Float>(ambient.x, ambient.y, ambient.z)),
            "g_LightSkylightColor": bytes(of: SIMD3<Float>(skylight.x, skylight.y, skylight.z)),
            "g_LightsColorPremultiplied": bytes(of: genericColors),
            "g_LightsPosition": bytes(of: genericPositions),
        ]

        if !pointOrigins.isEmpty { result["g_LPoint_Origin"] = bytes(of: pointOrigins) }
        if !pointColors.isEmpty { result["g_LPoint_Color"] = bytes(of: pointColors) }
        if !pointFalloffs.isEmpty { result["g_WELPoint_Falloff"] = bytes(of: pointFalloffs) }
        if !spotOrigins.isEmpty { result["g_LSpot_Origin"] = bytes(of: spotOrigins) }
        if !spotDirections.isEmpty { result["g_LSpot_Direction"] = bytes(of: spotDirections) }
        if !spotColors.isEmpty { result["g_LSpot_Color"] = bytes(of: spotColors) }
        if !spotFalloffs.isEmpty { result["g_WELSpot_Falloff"] = bytes(of: spotFalloffs) }
        if !tubeOriginsA.isEmpty { result["g_LTube_OriginA"] = bytes(of: tubeOriginsA) }
        if !tubeOriginsB.isEmpty { result["g_LTube_OriginB"] = bytes(of: tubeOriginsB) }
        if !tubeColors.isEmpty { result["g_LTube_Color"] = bytes(of: tubeColors) }
        if !tubeFalloffs.isEmpty { result["g_WELTube_Falloff"] = bytes(of: tubeFalloffs) }
        if !directionalDirections.isEmpty { result["g_LDirectional_Direction"] = bytes(of: directionalDirections) }
        if !directionalColors.isEmpty { result["g_LDirectional_Color"] = bytes(of: directionalColors) }

        result.merge(countBindings) { _, new in new }
        return result
    }

    private func encode(value: FrameValue, as type: String, fallbackOpacity: Double?) -> Data? {
        switch type {
        case "float":
            return bytes(of: Float(value.doubleValue ?? fallbackOpacity ?? 0))
        case "int":
            return bytes(of: Int32(value.doubleValue.map(Int32.init) ?? 0))
        case "vec2":
            let vector = value.vector3Value ?? RuntimeVector3.zero
            return bytes(of: SIMD2<Float>(vector.x, vector.y))
        case "vec3":
            let vector = value.vector3Value ?? RuntimeVector3.zero
            return bytes(of: SIMD3<Float>(vector.x, vector.y, vector.z))
        case "vec4":
            switch value {
            case .vec4(let values):
                return bytes(of: SIMD4<Float>(
                    Float(values[safe: 0] ?? 0),
                    Float(values[safe: 1] ?? 0),
                    Float(values[safe: 2] ?? 0),
                    Float(values[safe: 3] ?? 0)
                ))
            case .vec3(let values):
                return bytes(of: SIMD4<Float>(
                    Float(values[safe: 0] ?? 0),
                    Float(values[safe: 1] ?? 0),
                    Float(values[safe: 2] ?? 0),
                    Float(fallbackOpacity ?? 1)
                ))
            default:
                let scalar = Float(value.doubleValue ?? 0)
                return bytes(of: SIMD4<Float>(scalar, scalar, scalar, scalar))
            }
        default:
            return nil
        }
    }

    private func encodeDefault(_ defaultStr: String, as type: String) -> Data? {
        let parts = defaultStr.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
        func scalar() -> Float { parts.first ?? 0 }
        switch type {
        case "float":
            return bytes(of: scalar())
        case "int":
            return bytes(of: Int32(scalar()))
        case "vec2":
            return bytes(of: SIMD2<Float>(
                parts[safe: 0] ?? scalar(),
                parts[safe: 1] ?? scalar()
            ))
        case "vec3":
            return bytes(of: SIMD3<Float>(
                parts[safe: 0] ?? scalar(),
                parts[safe: 1] ?? scalar(),
                parts[safe: 2] ?? scalar()
            ))
        case "vec4":
            return bytes(of: SIMD4<Float>(
                parts[safe: 0] ?? scalar(),
                parts[safe: 1] ?? scalar(),
                parts[safe: 2] ?? scalar(),
                parts[safe: 3] ?? scalar()
            ))
        default:
            return nil
        }
    }

    func sceneViewProjection(scene: SceneDescription, viewportSize: CGSize, cameraZoom: Float = 1) -> simd_float4x4 {
        projectionMatrix(scene: scene, viewportSize: viewportSize, cameraZoom: cameraZoom) * sceneCoordinateConversion(scene: scene, viewportSize: viewportSize)
    }

    static func normalMatrix(for model: simd_float4x4) -> simd_float3x3 {
        let basis = simd_float3x3(columns: (SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
            SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)))
        return abs(simd_determinant(basis)) > 1e-10 ? simd_transpose(simd_inverse(basis)) : matrix_identity_float3x3
    }

    static func cameraViewMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        SceneCameraGeometry.cameraViewMatrix(eye: eye, center: center, up: up)
    }

    private func projectionMatrix(scene: SceneDescription, viewportSize: CGSize, cameraZoom: Float) -> simd_float4x4 {
        SceneCameraGeometry.projectionMatrix(scene: scene, viewportSize: viewportSize, cameraZoom: cameraZoom)
    }

    private func sceneCoordinateConversion(scene: SceneDescription, viewportSize: CGSize) -> simd_float4x4 {
        SceneCameraGeometry.sceneCoordinateConversion(scene: scene, viewportSize: viewportSize)
    }

    private func sceneAspect(scene: SceneDescription, viewportSize: CGSize) -> Double {
        let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
        let width = Double(projectionSize.width)
        let height = Double(projectionSize.height)
        return height > 0 ? width / height : 1
    }

    private func resolvedProjectionSize(scene: SceneDescription, viewportSize: CGSize) -> CGSize {
        SceneCameraGeometry.resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
    }

    private static func daytimeFraction() -> Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return minutes / (24.0 * 60.0)
    }

    private func lightDirection(for light: FrameLight) -> SIMD3<Float> {
        let angles = SIMD3<Float>(
            normalizedAngle(light.angles.x),
            normalizedAngle(light.angles.y),
            normalizedAngle(light.angles.z)
        )
        let rotation = rotationMatrix(radians: angles)
        let rotated = simd_mul(rotation, SIMD4<Float>(0, 0, -1, 0))
        let direction = SIMD3<Float>(rotated.x, rotated.y, rotated.z)
        let length = simd_length(direction)
        return length > 0.0001 ? direction / length : SIMD3<Float>(0, 0, -1)
    }

    private func normalizedAngle(_ angle: Float) -> Float {
        abs(angle) > .pi ? angle * .pi / 180 : angle
    }

    private func normalizedConeAngle(_ angle: Double) -> Float {
        let scalar = Float(angle)
        return abs(scalar) > .pi ? scalar * .pi / 180 : scalar
    }

    private func rotationMatrix(radians: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_float4x4(
            SIMD4<Float>(cos(-radians.z), sin(-radians.z), 0, 0),
            SIMD4<Float>(-sin(-radians.z), cos(-radians.z), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let y = simd_float4x4(
            SIMD4<Float>(cos(radians.y), 0, -sin(radians.y), 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sin(radians.y), 0, cos(radians.y), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let x = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cos(-radians.x), sin(-radians.x), 0),
            SIMD4<Float>(0, -sin(-radians.x), cos(-radians.x), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        return z * y * x
    }

    private func cacheKey(material: FrameMaterial, pass: FrameMaterialPass) -> String {
        "\(material.sourceFile)#\(pass.index)#\(pass.shaderPath)#\(pass.blending)#\(pass.combos.sorted { $0.key < $1.key })"
    }

    private func parseUniforms(vertexGLSL: String, fragmentGLSL: String) -> [String: UniformSpec] {
        func collect(in source: String) -> [String: UniformSpec] {
            var uniforms: [String: UniformSpec] = [:]
            let lines = source.split(whereSeparator: \.isNewline).map(String.init)
            let pattern = #"\buniform\s+(?:lowp\s+|mediump\s+|highp\s+)?([A-Za-z0-9_]+(?:\s*\[[^\]]+\])?)\s+([A-Za-z0-9_]+)"#
            let regex = try? NSRegularExpression(pattern: pattern)

            for line in lines {
                let end = line.range(of: "//")?.lowerBound ?? line.endIndex
                let nsRange = NSRange(line.startIndex..<end, in: line)
                let matches = regex?.matches(in: line, range: nsRange) ?? []
                for (index, match) in matches.enumerated() {
                    guard let typeRange = Range(match.range(at: 1), in: line),
                          let nameRange = Range(match.range(at: 2), in: line) else { continue }
                    let type = String(line[typeRange]).replacingOccurrences(of: " ", with: "")
                    let name = String(line[nameRange])
                    // A trailing annotation belongs to the nearest declaration.
                    let annotation = index == matches.count - 1 ? parseShaderAnnotation(from: line) : (nil,nil)
                    uniforms[name] = UniformSpec(name: name, type: type, materialKey: annotation.0, defaultValue: annotation.1)
                }
            }

            return uniforms
        }

        return collect(in: vertexGLSL).merging(collect(in: fragmentGLSL)) { current, _ in current }
    }

    private func parseShaderAnnotation(from line: String) -> (materialKey: String?, defaultValue: String?) {
        guard let commentStart = line.range(of: "//") else {
            return (nil, nil)
        }

        let comment = String(line[commentStart.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard comment.hasPrefix("{") else {
            return (nil, nil)
        }

        // The annotation may be followed by unrelated text (e.g. include
        // markers appended to the same line); take the balanced JSON object.
        var depth = 0
        var jsonEnd: String.Index?
        var inString = false
        var previousCharacter: Character = " "
        for index in comment.indices {
            let character = comment[index]
            if character == "\"" && previousCharacter != "\\" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        jsonEnd = index
                        break
                    }
                }
            }
            previousCharacter = character
        }
        guard let jsonEnd,
              let data = String(comment[...jsonEnd]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        let materialKey = json["material"] as? String

        let defaultValue: String?
        if let num = json["default"] as? NSNumber {
            defaultValue = num.stringValue
        } else if let str = json["default"] as? String {
            defaultValue = str
        } else if let array = json["default"] as? [NSNumber] {
            defaultValue = array.map(\.stringValue).joined(separator: " ")
        } else {
            defaultValue = nil
        }

        return (materialKey, defaultValue)
    }

    private func makeVertexDescriptor(from attributes: [MetalShaderVertexAttribute]) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()

        for attribute in attributes {
            descriptor.attributes[Int(attribute.location)].bufferIndex = Int(attribute.bufferIndex)
            descriptor.attributes[Int(attribute.location)].offset = 0

            switch attribute.vecSize {
            case 2:
                descriptor.attributes[Int(attribute.location)].format = .float2
                descriptor.layouts[Int(attribute.bufferIndex)].stride = MemoryLayout<Float>.stride * 2
            case 3:
                descriptor.attributes[Int(attribute.location)].format = .float3
                descriptor.layouts[Int(attribute.bufferIndex)].stride = MemoryLayout<Float>.stride * 3
            case 4:
                descriptor.attributes[Int(attribute.location)].format = .float4
                descriptor.layouts[Int(attribute.bufferIndex)].stride = MemoryLayout<Float>.stride * 4
            default:
                descriptor.attributes[Int(attribute.location)].format = .float
                descriptor.layouts[Int(attribute.bufferIndex)].stride = MemoryLayout<Float>.stride
            }

            descriptor.layouts[Int(attribute.bufferIndex)].stepFunction = .perVertex
        }

        return descriptor
    }

    private func configureBlending(_ mode: Int, descriptor: MTLRenderPipelineDescriptor) {
        guard let attachment = descriptor.colorAttachments[0] else {
            return
        }

        switch mode {
        case 2: // translucent
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case 3: // additive
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        default:
            attachment.isBlendingEnabled = false
        }
    }

    private func textureSlot(for name: String) -> Int? {
        let digits = name.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty else {
            return nil
        }
        return Int(String(digits))
    }

    private func textureResolutionSlot(for name: String) -> Int? {
        guard name.hasPrefix("g_Texture"), name.hasSuffix("Resolution") else {
            return nil
        }

        let prefixless = name.dropFirst("g_Texture".count)
        let digits = prefixless.prefix { $0.isNumber }
        guard !digits.isEmpty else {
            return nil
        }

        return Int(digits)
    }

    private func textureMipMapInfoSlot(for name: String) -> Int? {
        guard name.hasPrefix("g_Texture"), name.hasSuffix("MipMapInfo") else { return nil }
        return Int(name.dropFirst("g_Texture".count).dropLast("MipMapInfo".count))
    }

    private func makeMediaTexture(_ artwork: SceneMediaArtwork) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: artwork.width,
            height: artwork.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        artwork.rgba8.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, artwork.width, artwork.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: artwork.width * 4
            )
        }
        return texture
    }

    private static func makeFallbackTexture(device: MTLDevice, transparent: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate fallback texture")
        }

        var pixel: [UInt8] = transparent ? [0, 0, 0, 0] : [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return texture
    }
}

private final class SceneTextureResolver {
    private let debugBindings = ProcessInfo.processInfo.environment["WE_DEBUG_BIND"] != nil
    private let device: MTLDevice
    private let roots: [URL]
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]
    /// WE resolution metadata (storage vs real size) per resolved texture.
    private var resolutions: [ObjectIdentifier: SIMD4<Float>] = [:]
    private var atlases: [ObjectIdentifier: ParticleTextureAtlas] = [:]
    /// File textures whose WE flags request repeat (wrap) sampling.
    private var repeatTextures: Set<ObjectIdentifier> = []
    private var warnedMissingTextures: Set<String> = []
    /// Players for animated `.tex` textures (embedded MP4), keyed by path.
    private var videoPlayers: [String: VideoTexturePlayer] = [:]
    private var videoSources: [ObjectIdentifier: (path: String, url: URL)] = [:]
    private var controlledVideoPlayers: [NodeID: (path: String, player: VideoTexturePlayer)] = [:]
    var controlledVideoPlayerCount: Int { controlledVideoPlayers.count }

    func removeSceneLayers(_ ids: Set<NodeID>) {
        for id in ids {
            if let entry = controlledVideoPlayers.removeValue(forKey: id) {
                let textureID = ObjectIdentifier(entry.player.texture)
                resolutions[textureID] = nil
                repeatTextures.remove(textureID)
            }
        }
    }
    private var animationSources: [ObjectIdentifier: (path: String, url: URL, animation: TextureAnimation)] = [:]
    private var animationPages: [String: [Int: MTLTexture]] = [:]

    init(device: MTLDevice, roots: [URL]) {
        self.device = device
        self.roots = roots
        self.loader = MTKTextureLoader(device: device)
    }

    func resolution(for texture: MTLTexture) -> SIMD4<Float>? {
        resolutions[ObjectIdentifier(texture)]
    }

    func atlas(for texture: MTLTexture) -> ParticleTextureAtlas? {
        atlases[ObjectIdentifier(texture)]
    }

    func prefersRepeatSampling(_ texture: MTLTexture) -> Bool {
        repeatTextures.contains(ObjectIdentifier(texture))
    }

    func hasAnimation(_ texture: MTLTexture) -> Bool { animationSources[ObjectIdentifier(texture)] != nil }

    func videoSample(for texture: MTLTexture, primaryPath: String?, nodeID: NodeID, time: Double?, sharedTime: Double) -> MTLTexture? {
        guard let source = videoSources[ObjectIdentifier(texture)] else { return nil }
        guard let time, source.path == primaryPath else {
            // All shared users request the same time. Updating here also
            // handles a movie first loaded after the frame has begun, without
            // continually decoding the shared copy of a paused private movie.
            videoPlayers[source.path]?.advance(to: sharedTime)
            return texture
        }
        if controlledVideoPlayers[nodeID]?.path != source.path {
            guard case .video(let payload)? = WETexDecoder.contents(url: source.url, device: device),
                  let player = VideoTexturePlayer(payload: payload, cacheURL: source.url.appendingPathExtension("mp4"), device: device)
            else { return nil }
            controlledVideoPlayers[nodeID] = (source.path, player)
            resolutions[ObjectIdentifier(player.texture)] = player.resolution
            if !player.clampUVs { repeatTextures.insert(ObjectIdentifier(player.texture)) }
        }
        guard let player = controlledVideoPlayers[nodeID]?.player else { return nil }
        // The runtime already handles wrap and completion. In particular,
        // seeking to duration must display the final frame rather than zero.
        player.advance(to: time, looping: false)
        return player.texture
    }

    func animationSample(for texture: MTLTexture, primaryPath: String?, controlledTime: Double?, sharedTime: Double)
        -> (texture: MTLTexture, frame: TextureAnimationFrame)? {
        guard let source = animationSources[ObjectIdentifier(texture)] else { return nil }
        let time = source.path == primaryPath ? controlledTime ?? sharedTime : sharedTime
        let frame = source.animation.frames[source.animation.frameIndex(at: time)]
        if let page = animationPages[source.path]?[frame.imageIndex] { return (page,frame) }
        guard case .texture(let decoded)? = WETexDecoder.contents(url: source.url, device: device, imageIndex: frame.imageIndex) else { return nil }
        animationPages[source.path, default: [:]][frame.imageIndex] = decoded.texture
        resolutions[ObjectIdentifier(decoded.texture)] = decoded.resolution
        if !decoded.clampUVs { repeatTextures.insert(ObjectIdentifier(decoded.texture)) }
        return (decoded.texture,frame)
    }

    func resolveTexture(named path: String) throws -> MTLTexture? {
        if let cached = cache[path] {
            return cached
        }

        let fileManager = FileManager.default
        for candidate in candidateURLs(for: path) where fileManager.fileExists(atPath: candidate.path) {
            let texture: MTLTexture?
            if candidate.pathExtension.lowercased() == "tex" {
                switch WETexDecoder.contents(url: candidate, device: device) {
                case .texture(let decoded):
                    texture = decoded.texture
                    resolutions[ObjectIdentifier(decoded.texture)] = decoded.resolution
                    if let data = try? Data(contentsOf: candidate), let atlas = ParticleTextureAtlas.decode(data) {
                        atlases[ObjectIdentifier(decoded.texture)] = atlas
                    }
                    if let data = try? Data(contentsOf: candidate), let animation = TextureAnimation.decode(data) {
                        animationSources[ObjectIdentifier(decoded.texture)] = (path,candidate,animation)
                        animationPages[path] = [0: decoded.texture]
                    }
                    if !decoded.clampUVs {
                        repeatTextures.insert(ObjectIdentifier(decoded.texture))
                    }
                case .video(let payload):
                    let cacheURL = candidate.appendingPathExtension("mp4")
                    if let player = VideoTexturePlayer(payload: payload, cacheURL: cacheURL, device: device) {
                        videoPlayers[path] = player
                        videoSources[ObjectIdentifier(player.texture)] = (path, candidate)
                        texture = player.texture
                        resolutions[ObjectIdentifier(player.texture)] = player.resolution
                        if !player.clampUVs {
                            repeatTextures.insert(ObjectIdentifier(player.texture))
                        }
                    } else {
                        texture = nil
                    }
                case nil:
                    texture = nil
                }
            } else {
                texture = try? loader.newTexture(
                    URL: candidate,
                    options: [
                        .SRGB: false,
                        .generateMipmaps: false,
                    ]
                )
                if let texture {
                    // Plain image files carry no WE flags; repeat is the
                    // Wallpaper Engine default for material textures.
                    repeatTextures.insert(ObjectIdentifier(texture))
                }
            }
            if let texture {
                cache[path] = texture
                return texture
            }
        }

        if !warnedMissingTextures.contains(path) {
            print("[MaterialBinder] Texture '\(path)' could not be resolved — using fallback")
            if debugBindings {
                for candidate in candidateURLs(for: path) {
                    let exists = FileManager.default.fileExists(atPath: candidate.path)
                    print("[MaterialBinder]   candidate \(candidate.path) exists=\(exists)")
                }
            }
            warnedMissingTextures.insert(path)
        }
        return nil
    }

    private func candidateURLs(for path: String) -> [URL] {
        // User-selected files and published preset assets are absolute paths.
        if (path as NSString).isAbsolutePath {
            let url = URL(fileURLWithPath: path)
            return [url, url.appendingPathExtension("tex")]
        }
        let ext = URL(fileURLWithPath: path).pathExtension
        let baseNames: [String]
        if ext.isEmpty {
            baseNames = [path, "materials/\(path)"]
        } else {
            baseNames = [path, "materials/\(path)"]
        }

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
                    // WE texture names may embed an extension ("photo.jpg")
                    // while the packed asset is "photo.jpg.tex".
                    urls.append(root.appendingPathComponent(baseName + ".tex"))
                }
            }
        }
        return urls
    }
}

private func bytes<T>(of value: T) -> Data {
    withUnsafeBytes(of: value) { Data($0) }
}

private func bytes<T>(of value: [T]) -> Data {
    value.withUnsafeBytes { Data($0) }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
