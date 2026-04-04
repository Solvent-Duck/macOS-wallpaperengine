import CoreGraphics
import Foundation
import Metal
import NativeSceneCore
import NativeSceneRuntime
import simd

public enum NativeSceneParityStatus: String, Codable, Equatable, Sendable {
    case unsupported
    case partial
    case complete
}

public struct NativeSceneRendererSupport: Codable, Equatable, Sendable {
    public let isSupported: Bool
    public let parityStatus: NativeSceneParityStatus
    public let blockingReasons: [String]
    public let placeholderSubsystems: [String]
    public let reason: String?

    public init(
        isSupported: Bool,
        parityStatus: NativeSceneParityStatus,
        blockingReasons: [String] = [],
        placeholderSubsystems: [String] = [],
        reason: String? = nil
    ) {
        self.isSupported = isSupported
        self.parityStatus = parityStatus
        self.blockingReasons = blockingReasons
        self.placeholderSubsystems = placeholderSubsystems
        if let reason, !reason.isEmpty {
            self.reason = reason
        } else {
            self.reason = Self.composeReason(
                blockingReasons: blockingReasons,
                placeholderSubsystems: placeholderSubsystems
            )
        }
    }

    public var hasKnownPlaceholders: Bool {
        !placeholderSubsystems.isEmpty
    }

    private static func composeReason(
        blockingReasons: [String],
        placeholderSubsystems: [String]
    ) -> String? {
        var segments: [String] = []
        if !blockingReasons.isEmpty {
            segments.append("blocking: " + blockingReasons.joined(separator: "; "))
        }
        if !placeholderSubsystems.isEmpty {
            segments.append("placeholders: " + placeholderSubsystems.joined(separator: ", "))
        }
        return segments.isEmpty ? nil : segments.joined(separator: " | ")
    }
}

public enum NativeSceneRendererError: LocalizedError {
    case missingSceneGraph
    case unsupportedScene(String)
    case commandEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .missingSceneGraph:
            return "The scene description does not contain a scene graph."
        case .unsupportedScene(let reason):
            return "The native renderer does not support this scene yet: \(reason)"
        case .commandEncodingFailed:
            return "Failed to create a Metal render command encoder."
        }
    }
}

public final class NativeSceneRenderer {
    public let scene: SceneDescription
    public let device: MTLDevice
    public let assetRoots: [URL]

    private let runtime: SceneRuntime
    private let materialBinder: MaterialBinder
    private let passGraph = PassGraph()
    private let imageRenderer = ImageRenderer()
    private let particleRenderer: ParticleRenderer
    private let lightingPass = LightingPass()
    private var postProcessPass: PostProcessPass
    private let textRenderer: TextRenderer

    private var propertyOverrides: [String: FrameValue] = [:]
    private var audioInput: AudioInputState = .silent
    private var cursorPosition: RuntimeVector2?
    private var persistentRenderTargets: [String: MTLTexture] = [:]

    private struct ImageChainStep {
        let material: FrameMaterial?
        let pass: FrameMaterialPass?
        let binds: [FrameTextureBinding]
        let target: String?
        let command: Int?
        let source: String?
    }

    public init(
        scene: SceneDescription,
        device: MTLDevice,
        assetRoots: [URL],
        colorPixelFormat: MTLPixelFormat = .rgba8Unorm
    ) throws {
        guard scene.scene != nil else {
            throw NativeSceneRendererError.missingSceneGraph
        }

        let support = Self.support(scene: scene)
        guard support.isSupported else {
            throw NativeSceneRendererError.unsupportedScene(support.reason ?? "unknown")
        }

        self.scene = scene
        self.device = device
        self.assetRoots = assetRoots
        self.runtime = SceneRuntime(scene: scene)
        self.materialBinder = try MaterialBinder(
            device: device,
            assetRoots: assetRoots,
            colorPixelFormat: colorPixelFormat
        )
        self.particleRenderer = try ParticleRenderer(
            device: device,
            assetRoots: assetRoots,
            colorPixelFormat: colorPixelFormat
        )
        self.textRenderer = try TextRenderer(device: device, assetRoots: assetRoots, colorPixelFormat: colorPixelFormat)
        self.postProcessPass = try PostProcessPass(device: device)
    }

    public static func support(scene: SceneDescription) -> NativeSceneRendererSupport {
        guard let graph = scene.scene else {
            return NativeSceneRendererSupport(
                isSupported: false,
                parityStatus: .unsupported,
                blockingReasons: ["sceneDescription.scene is missing"]
            )
        }

        var placeholders = Set<String>()
        for node in graph.nodes {
            switch node.kind {
            case .image:
                guard let image = node.image else {
                    placeholders.insert("image-data-gaps")
                    continue
                }

                if !image.animationLayers.isEmpty {
                    placeholders.insert("animation-layers")
                }

                guard let model = image.model, model.material != nil else {
                    placeholders.insert("image-data-gaps")
                    continue
                }

                if model.filename.hasSuffix(".mdl") || model.filename.hasSuffix(".obj") {
                    placeholders.insert("mesh-geometry")
                }

            case .text:
                if let text = node.text {
                    if !text.effects.isEmpty {
                        placeholders.insert("text-effects")
                    }
                }
            case .light:
                break
            case .particle:
                if let particle = node.particle, particleNeedsPlaceholder(particle) {
                    placeholders.insert("particles")
                }
            case .sound:
                placeholders.insert("sound-nodes")
            case .unknown:
                placeholders.insert("unknown-node-kinds")
            }
        }

        if settingMightBeActive(graph.camera.shake.enabled) {
            placeholders.insert("camera-shake")
        }

        let placeholderSubsystems = placeholders.sorted()
        return NativeSceneRendererSupport(
            isSupported: true,
            parityStatus: placeholderSubsystems.isEmpty ? .complete : .partial,
            placeholderSubsystems: placeholderSubsystems
        )
    }

    public static func supportReportLine(for scene: SceneDescription) -> String? {
        let support = support(scene: scene)
        guard let data = try? JSONEncoder().encode(support),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func settingMightBeActive(_ setting: UserSettingDescriptor?) -> Bool {
        guard let setting else {
            return false
        }

        if setting.propertyBinding != nil {
            return true
        }

        guard let value = setting.value else {
            return false
        }

        if value.kind == .scripted {
            return true
        }

        switch value.value {
        case .null:
            return false
        case .float(let scalar):
            return abs(scalar) > 0.0001
        case .int(let scalar):
            return scalar != 0
        case .bool(let scalar):
            return scalar
        case .string(let scalar):
            let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "0" && trimmed.lowercased() != "false"
        case .vec2(let values), .vec3(let values), .vec4(let values):
            return values.contains { abs($0) > 0.0001 }
        case .ivec2(let values), .ivec3(let values), .ivec4(let values):
            return values.contains { $0 != 0 }
        }
    }

    private static func particleNeedsPlaceholder(_ particle: ParticleDescriptor) -> Bool {
        let supportedRenderers = Set(["sprite"])
        let supportedEmitters = Set(["boxrandom", "sphererandom"])
        let supportedInitializers = Set([
            "lifetimerandom",
            "sizerandom",
            "velocityrandom",
            "colorrandom",
            "rotationrandom",
            "angularvelocityrandom",
        ])
        let supportedOperators = Set([
            "movement",
            "alphafade",
            "oscillateposition",
            "oscillatealpha",
            "angularmovement",
        ])

        guard !particle.renderers.isEmpty else {
            return true
        }

        if particle.renderers.contains(where: { !supportedRenderers.contains($0.name.lowercased()) }) {
            return true
        }
        if particle.emitters.contains(where: { !supportedEmitters.contains($0.name.lowercased()) }) {
            return true
        }
        if particle.initializers.contains(where: { !supportedInitializers.contains($0.kind.lowercased()) }) {
            return true
        }
        if particle.operators.contains(where: { !supportedOperators.contains($0.kind.lowercased()) }) {
            return true
        }
        if !particle.children.isEmpty {
            return true
        }
        if particle.controlPoints.contains(where: \.lockToPointer) {
            return true
        }

        return false
    }

    public func updatePropertyOverrides(_ overrides: [String: FrameValue]) {
        propertyOverrides = overrides
    }

    public func updateAudio(_ input: AudioInputState) {
        audioInput = input
    }

    public func updateCursorPosition(_ position: CGPoint) {
        cursorPosition = RuntimeVector2(
            x: Float(min(max(position.x, 0), 1)),
            y: Float(min(max(position.y, 0), 1))
        )
    }

    @discardableResult
    public func renderNextFrame(
        deltaTime: Double,
        into targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> FramePacket {
        let packet = runtime.step(
            deltaTime: deltaTime,
            propertyOverrides: propertyOverrides,
            audioInput: audioInput,
            cursorPosition: cursorPosition
        )
        try render(packet: packet, into: targetTexture, commandBuffer: commandBuffer)
        return packet
    }

    public func render(
        packet: FramePacket,
        into targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let graph = scene.scene else {
            throw NativeSceneRendererError.missingSceneGraph
        }

        let clear = defaultClearColor(from: graph.clearColor)

        let materialsByID = Dictionary(uniqueKeysWithValues: packet.materials.map { ($0.id, $0) })
        let particleSystemsByID = Dictionary(uniqueKeysWithValues: packet.particleSystems.map { ($0.nodeID, $0) })
        let viewportSize = CGSize(width: targetTexture.width, height: targetTexture.height)
        var currentScene = try makeRenderTexture(width: targetTexture.width, height: targetTexture.height)
        var nextScene = try makeRenderTexture(width: targetTexture.width, height: targetTexture.height)
        try clearTexture(currentScene, color: clear, commandBuffer: commandBuffer)

        var sceneNamedTextures: [String: MTLTexture] = [
            "_rt_FullFrameBuffer": currentScene,
        ]

        for frameNode in packet.nodes where frameNode.visible {
            guard let nodeDescriptor = scene.nodes.first(where: { $0.id == frameNode.nodeID }) else {
                continue
            }

            if nodeDescriptor.image != nil {
                try copyTexture(from: currentScene, to: nextScene, commandBuffer: commandBuffer)
                let rendered: Bool
                do {
                    rendered = try renderImageNode(
                        frameNode: frameNode,
                        nodeDescriptor: nodeDescriptor,
                        packet: packet,
                        materialsByID: materialsByID,
                        currentScene: currentScene,
                        destinationScene: nextScene,
                        sceneNamedTextures: &sceneNamedTextures,
                        viewportSize: viewportSize,
                        commandBuffer: commandBuffer
                    )
                } catch {
                    print("[NativeSceneRenderer] Skipping image node \(frameNode.nodeID.rawValue): \(error.localizedDescription)")
                    continue
                }
                if rendered {
                    swap(&currentScene, &nextScene)
                    sceneNamedTextures["_rt_FullFrameBuffer"] = currentScene
                }
            } else if nodeDescriptor.particle != nil,
                      let particleSystem = particleSystemsByID[frameNode.nodeID],
                      particleSystem.visible,
                      particleSystem.emissionEnabled,
                      let materialID = particleSystem.materialReference,
                      let material = materialsByID[materialID] {
                try copyTexture(from: currentScene, to: nextScene, commandBuffer: commandBuffer)
                try renderParticleNode(
                    frameNode: frameNode,
                    nodeDescriptor: nodeDescriptor,
                    particleSystem: particleSystem,
                    material: material,
                    destinationScene: nextScene,
                    viewportSize: viewportSize,
                    commandBuffer: commandBuffer
                )
                swap(&currentScene, &nextScene)
                sceneNamedTextures["_rt_FullFrameBuffer"] = currentScene
            }
        }

        if packet.texts.contains(where: \.visible) {
            try copyTexture(from: currentScene, to: nextScene, commandBuffer: commandBuffer)
            try renderTexts(
                packet: packet,
                destinationScene: nextScene,
                commandBuffer: commandBuffer
            )
            swap(&currentScene, &nextScene)
            sceneNamedTextures["_rt_FullFrameBuffer"] = currentScene
        }

        do {
            try postProcessPass.finalize(
                packet: packet,
                scene: scene,
                currentSceneTexture: currentScene,
                targetTexture: targetTexture,
                materialBinder: materialBinder,
                imageRenderer: imageRenderer,
                commandBuffer: commandBuffer
            )
        } catch {
            print("[NativeSceneRenderer] Falling back to scene copy: \(error.localizedDescription)")
            try copyTexture(from: currentScene, to: targetTexture, commandBuffer: commandBuffer)
        }
    }

    private func renderParticleNode(
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        particleSystem: FrameParticleSystem,
        material: FrameMaterial,
        destinationScene: MTLTexture,
        viewportSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let passIndex = material.passOrdering.first,
              let pass = material.passes.first(where: { $0.index == passIndex }) else {
            return
        }

        let descriptor = renderPassDescriptor(for: destinationScene, loadAction: .load)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        defer { encoder.endEncoding() }
        try particleRenderer.render(
            system: particleSystem,
            frameNode: frameNode,
            pass: pass,
            scene: scene,
            viewportSize: viewportSize,
            encoder: encoder
        )
    }

    private func renderImageNode(
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        packet: FramePacket,
        materialsByID: [String: FrameMaterial],
        currentScene: MTLTexture,
        destinationScene: MTLTexture,
        sceneNamedTextures: inout [String: MTLTexture],
        viewportSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        guard let materialID = frameNode.renderItemReferences.first,
              let baseMaterial = materialsByID[materialID],
              let imageSize = imageRenderer.resolvedSize(
                for: nodeDescriptor,
                scene: scene,
                viewportSize: viewportSize
              ),
              let sceneGeometry = imageRenderer.makeSceneGeometry(
                for: nodeDescriptor,
                scene: scene,
                viewportSize: viewportSize,
                device: device
              ),
              let copyGeometry = imageRenderer.makeOffscreenCopyGeometry(size: imageSize, device: device),
              let passGeometry = imageRenderer.makeOffscreenPassGeometry(device: device) else {
            return false
        }

        let chainSteps = buildImageChain(baseMaterial: baseMaterial, frameNode: frameNode, materialsByID: materialsByID)
        guard let lastScenePassIndex = chainSteps.lastIndex(where: { $0.material != nil && $0.pass != nil && $0.target == nil }) else {
            return false
        }

        var namedTextures = sceneNamedTextures
        let compositeAName = "_rt_imageLayerComposite_\(frameNode.nodeID.rawValue)_a"
        let compositeBName = "_rt_imageLayerComposite_\(frameNode.nodeID.rawValue)_b"
        var currentMain = try makeRenderTexture(width: Int(imageSize.width), height: Int(imageSize.height))
        var currentSub = try makeRenderTexture(width: Int(imageSize.width), height: Int(imageSize.height))
        namedTextures[compositeAName] = currentMain
        namedTextures[compositeBName] = currentSub

        for effect in frameNode.imageEffects {
            for renderTarget in effect.renderTargets {
                let targetWidth = max(Int((imageSize.width / max(renderTarget.scale, 1)).rounded(.toNearestOrAwayFromZero)), 1)
                let targetHeight = max(Int((imageSize.height / max(renderTarget.scale, 1)).rounded(.toNearestOrAwayFromZero)), 1)
                let key = "node\(frameNode.nodeID.rawValue):effect\(effect.id):\(renderTarget.name):\(targetWidth)x\(targetHeight)"
                let texture = try makeRenderTexture(
                    width: targetWidth,
                    height: targetHeight,
                    persistentKey: renderTarget.unique ? key : nil
                )
                namedTextures[renderTarget.name] = texture
            }
        }

        var chainInputTexture: MTLTexture?
        var writtenTargets = Set<String>()

        for (index, step) in chainSteps.enumerated() {
            if let command = step.command {
                guard let source = step.source,
                      let target = step.target,
                      let sourceTexture = namedTextures[source],
                      let targetTexture = namedTextures[target] else {
                    continue
                }

                if command == 1 {
                    namedTextures[source] = targetTexture
                    namedTextures[target] = sourceTexture
                } else {
                    try copyTexture(from: sourceTexture, to: targetTexture, commandBuffer: commandBuffer)
                }
                continue
            }

            guard let material = step.material,
                  let pass = step.pass else {
                continue
            }

            let isScenePass = index == lastScenePassIndex
            let isFirstPass = chainInputTexture == nil
            let targetTexture: MTLTexture
            let geometry: (positions: MTLBuffer, texCoords: MTLBuffer)
            let bindingContext: MaterialBindingContext
            let loadAction: MTLLoadAction

            if isScenePass {
                targetTexture = destinationScene
                geometry = sceneGeometry
                bindingContext = MaterialBindingContext(
                    viewportSize: viewportSize,
                    textureOverridesBySlot: textureSlotOverrides(
                        binds: step.binds,
                        chainInputTexture: chainInputTexture,
                        namedTextures: namedTextures,
                        currentScene: currentScene
                    ),
                    textureOverridesByName: namedTextures.merging(["_rt_FullFrameBuffer": currentScene]) { _, new in new }
                )
                loadAction = .load
            } else {
                if let target = step.target, let explicitTarget = namedTextures[target] {
                    targetTexture = explicitTarget
                    loadAction = writtenTargets.contains(target) ? .load : .clear
                    writtenTargets.insert(target)
                } else {
                    targetTexture = currentMain
                    loadAction = .clear
                }

                geometry = isFirstPass ? copyGeometry : passGeometry
                bindingContext = MaterialBindingContext(
                    viewportSize: CGSize(width: targetTexture.width, height: targetTexture.height),
                    textureOverridesBySlot: textureSlotOverrides(
                        binds: step.binds,
                        chainInputTexture: chainInputTexture,
                        namedTextures: namedTextures,
                        currentScene: currentScene
                    ),
                    textureOverridesByName: namedTextures.merging(["_rt_FullFrameBuffer": currentScene]) { _, new in new },
                    uniformOverrides: offscreenUniformOverrides(
                        targetSize: CGSize(width: targetTexture.width, height: targetTexture.height),
                        firstPass: isFirstPass
                    )
                )
            }

            let descriptor = renderPassDescriptor(for: targetTexture, loadAction: loadAction)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw NativeSceneRendererError.commandEncodingFailed
            }
            defer { encoder.endEncoding() }

            try lightingPass.prepare(packet: packet, encoder: encoder)
            let preparedPass = try materialBinder.preparePass(material: material, pass: pass)
            try materialBinder.bind(
                preparedPass: preparedPass,
                frameNode: frameNode,
                nodeDescriptor: nodeDescriptor,
                scene: scene,
                packet: packet,
                positions: geometry.positions,
                texCoords: geometry.texCoords,
                encoder: encoder,
                bindingContext: bindingContext
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            if !isScenePass, step.target == nil {
                chainInputTexture = currentMain
                swap(&currentMain, &currentSub)
                namedTextures[compositeAName] = currentMain
                namedTextures[compositeBName] = currentSub
            }
        }

        sceneNamedTextures.merge(namedTextures) { _, new in new }
        return true
    }

    private func buildImageChain(
        baseMaterial: FrameMaterial,
        frameNode: FrameNode,
        materialsByID: [String: FrameMaterial]
    ) -> [ImageChainStep] {
        var steps: [ImageChainStep] = []

        for orderedPass in baseMaterial.passOrdering {
            guard let pass = baseMaterial.passes.first(where: { $0.index == orderedPass }) else {
                continue
            }
            steps.append(
                ImageChainStep(
                    material: baseMaterial,
                    pass: pass,
                    binds: [],
                    target: nil,
                    command: nil,
                    source: nil
                )
            )
        }

        for effect in frameNode.imageEffects {
            for effectPass in effect.passes {
                if let materialReference = effectPass.materialReference,
                   let material = materialsByID[materialReference] {
                    for orderedPass in material.passOrdering {
                        guard let pass = material.passes.first(where: { $0.index == orderedPass }) else {
                            continue
                        }
                        steps.append(
                            ImageChainStep(
                                material: material,
                                pass: pass,
                                binds: effectPass.binds,
                                target: effectPass.target,
                                command: nil,
                                source: nil
                            )
                        )
                    }
                } else {
                    steps.append(
                        ImageChainStep(
                            material: nil,
                            pass: nil,
                            binds: effectPass.binds,
                            target: effectPass.target,
                            command: effectPass.command,
                            source: effectPass.source
                        )
                    )
                }
            }
        }

        return steps
    }

    private func textureSlotOverrides(
        binds: [FrameTextureBinding],
        chainInputTexture: MTLTexture?,
        namedTextures: [String: MTLTexture],
        currentScene: MTLTexture
    ) -> [Int: MTLTexture] {
        var overrides: [Int: MTLTexture] = [:]
        if let chainInputTexture {
            overrides[0] = chainInputTexture
        }

        for bind in binds {
            if bind.path == "previous" {
                if let chainInputTexture {
                    overrides[bind.slot] = chainInputTexture
                }
            } else if bind.path == "_rt_FullFrameBuffer" {
                overrides[bind.slot] = currentScene
            } else if let texture = namedTextures[bind.path] {
                overrides[bind.slot] = texture
            }
        }

        return overrides
    }

    private func offscreenUniformOverrides(
        targetSize: CGSize,
        firstPass: Bool
    ) -> [String: Data] {
        let identity4 = matrix_identity_float4x4
        let identity3 = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1)
        )
        let ortho = simd_float4x4(
            SIMD4<Float>(2 / max(Float(targetSize.width), 1), 0, 0, 0),
            SIMD4<Float>(0, 2 / max(Float(targetSize.height), 1), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, -1, 0, 1)
        )
        let modelMatrix = firstPass ? ortho : identity4
        let modelViewProjection = firstPass ? ortho : identity4

        return [
            "g_ModelViewProjectionMatrix": localRendererBytes(of: modelViewProjection),
            "g_ModelMatrix": localRendererBytes(of: modelMatrix),
            "g_AltModelMatrix": localRendererBytes(of: modelMatrix),
            "g_ViewProjectionMatrix": localRendererBytes(of: identity4),
            "g_AltViewProjectionMatrix": localRendererBytes(of: identity4),
            "g_NormalModelMatrix": localRendererBytes(of: identity3),
            "g_AltNormalModelMatrix": localRendererBytes(of: identity3),
        ]
    }

    private func renderPassDescriptor(for texture: MTLTexture, loadAction: MTLLoadAction) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        if loadAction == .clear {
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return descriptor
    }

    private func clearTexture(
        _ texture: MTLTexture,
        color: RuntimeVector4,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: texture, loadAction: .clear)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(color.x),
            green: Double(color.y),
            blue: Double(color.z),
            alpha: Double(color.w)
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        encoder.endEncoding()
    }

    private func copyTexture(
        from source: MTLTexture,
        to destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: min(source.width, destination.width), height: min(source.height, destination.height), depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    private func makeRenderTexture(
        width: Int,
        height: Int,
        persistentKey: String? = nil
    ) throws -> MTLTexture {
        if let persistentKey,
           let cached = persistentRenderTargets[persistentKey],
           cached.width == width,
           cached.height == height {
            return cached
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate render texture")
        }

        if let persistentKey {
            persistentRenderTargets[persistentKey] = texture
        }

        return texture
    }

    private func renderTexts(
        packet: FramePacket,
        destinationScene: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: destinationScene, loadAction: .load)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        defer { encoder.endEncoding() }

        try textRenderer.render(
            texts: packet.texts,
            scene: scene,
            nodes: packet.nodes,
            encoder: encoder
        )
    }

    private func defaultClearColor(from setting: UserSettingDescriptor?) -> RuntimeVector4 {
        guard let descriptor = setting?.value else {
            return RuntimeVector4(x: 0, y: 0, z: 0, w: 1)
        }

        switch descriptor.value {
        case .vec4(let values):
            return RuntimeVector4(values, default: RuntimeVector4(x: 0, y: 0, z: 0, w: 1))
        case .vec3(let values):
            return RuntimeVector4(
                x: Float(values[safe: 0] ?? 0),
                y: Float(values[safe: 1] ?? 0),
                z: Float(values[safe: 2] ?? 0),
                w: 1
            )
        default:
            return RuntimeVector4(x: 0, y: 0, z: 0, w: 1)
        }
    }
}

private func localRendererBytes<T>(of value: T) -> Data {
    withUnsafeBytes(of: value) { Data($0) }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
