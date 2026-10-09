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
    public var scene: SceneDescription { runtime.scene }
    public var sceneRevision: UInt64 { runtime.sceneRevision }
    public let device: MTLDevice
    public let assetRoots: [URL]

    private let runtime: SceneRuntime
    private let materialBinder: MaterialBinder
    private let passGraph = PassGraph()
    private let imageRenderer: ImageRenderer
    private let directModelRenderer: DirectModelRenderer
    private var sceneReflectionTexture: MTLTexture?
    private let particleRenderer: ParticleRenderer
    private let lightingPass = LightingPass()
    private var postProcessPass: PostProcessPass
    private let textRenderer: TextRenderer

    private var propertyOverrides: [String: FrameValue] = [:]
    private var audioInput: AudioInputState = .silent
    private var cursorPosition: RuntimeVector2?
    private var cursorLeftDown = false
    private var cursorEvents = CursorInputQueue()
    private var warnedSkippedNodes: Set<Int> = []
    private var warnedTargetFormats: Set<String> = []
    private struct EffectTargetOwner: Hashable {
        let nodeID: NodeID
        let sourceIndex: Int
    }

    private final class EffectTargets {
        let owner: EffectTargetOwner
        let retainedNames: Set<String>
        var textures: [String: MTLTexture]

        init(owner: EffectTargetOwner, retainedNames: Set<String>, textures: [String: MTLTexture]) {
            self.owner = owner
            self.retainedNames = retainedNames
            self.textures = textures
        }
    }

    private struct RetainedEffectTexture {
        let texture: MTLTexture
        let format: EffectRenderTargetFormat
    }

    private var effectTargetHistory: [EffectTargetOwner: [String: RetainedEffectTexture]] = [:]

    // Counts of resources owned by live layer IDs, for lifecycle regression checks.
    var layerResourceCounts: (text: Int, video: Int, effects: Int) {
        (textRenderer.cachedNodeCount, materialBinder.controlledVideoPlayerCount, effectTargetHistory.count)
    }
    private var effectTextureFormats: [ObjectIdentifier: EffectRenderTargetFormat] = [:]
    private var sharedSceneEncoder: (encoder: MTLRenderCommandEncoder, target: MTLTexture, commandBuffer: MTLCommandBuffer)?

    private struct RenderTextureKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }

    /// Render textures handed out during the current frame.
    private var leasedRenderTextures: [MTLTexture] = []
    /// Last frame's render textures, reusable by size and format this frame.
    private var reusableRenderTextures: [RenderTextureKey: [MTLTexture]] = [:]

    private struct SceneDraw {
        let frame: FrameNode
        var geometry: DirectModelRenderer.Geometry? = nil
        var material: FrameMaterial? = nil
        var cameraDepth: Float = 0

        var isTranslucent: Bool {
            guard let material else { return false }
            return material.passes.contains { material.passOrdering.contains($0.index) && ($0.blending == 2 || $0.blending == 3) }
        }
    }

    deinit {
        runtime.shutdown(cursorPosition: cursorPosition)
    }

    private struct ImageChainStep {
        let material: FrameMaterial?
        let pass: FrameMaterialPass?
        let binds: [FrameTextureBinding]
        let target: String?
        let command: Int?
        let source: String?
        var isColorBlend = false
        var effectIndex: Int? = nil
    }

    public init(
        scene: SceneDescription,
        device: MTLDevice,
        assetRoots: [URL],
        colorPixelFormat: MTLPixelFormat = .rgba8Unorm,
        scriptStorage: SceneScriptStorage? = nil
    ) throws {
        guard scene.scene != nil else {
            throw NativeSceneRendererError.missingSceneGraph
        }

        let support = Self.support(scene: scene)
        guard support.isSupported else {
            throw NativeSceneRendererError.unsupportedScene(support.reason ?? "unknown")
        }

        self.device = device
        self.assetRoots = assetRoots
        let puppetModels = PuppetModelLibrary(assetRoots: assetRoots)
        let textLayouts = TextLayoutEngine(assetRoots: assetRoots)
        self.runtime = SceneRuntime(scene: scene, storage: scriptStorage, puppetModels: puppetModels,
                                    textureAnimations: TextureAnimationLibrary(assetRoots: assetRoots), textLayouts: textLayouts,
                                    assetRoots: assetRoots)
        self.imageRenderer = ImageRenderer(assetRoots: assetRoots, puppetModels: puppetModels)
        self.directModelRenderer = DirectModelRenderer(assetRoots: assetRoots, puppetModels: puppetModels)
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
        self.textRenderer = try TextRenderer(device: device, assetRoots: assetRoots, colorPixelFormat: colorPixelFormat, textLayouts: textLayouts)
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
            let effects = node.image?.effects ?? node.text?.effects ?? []
            if effects.flatMap({ $0.effect?.fbos ?? [] }).contains(where: {
                EffectRenderTargetFormat(rawValue: $0.format.lowercased()) == nil
            }) {
                placeholders.insert("effect-target-formats")
            }
            switch node.kind {
            case .image:
                guard let image = node.image else {
                    placeholders.insert("image-data-gaps")
                    continue
                }

                guard let model = image.model, model.material != nil else {
                    placeholders.insert("image-data-gaps")
                    continue
                }

                for material in [model.material].compactMap({ $0 }) + (model.meshMaterials ?? []).compactMap({ $0 }) {
                    for texture in material.passes.flatMap(\.userTextures) {
                        if texture.sourceType == "system" { placeholders.insert("system-textures") }
                        if texture.sourceType == "usershortcut" { placeholders.insert("shortcut-icons") }
                    }
                }

                // Puppet-warp models render through the native skinned-mesh
                // path (PuppetModel + ImageRenderer.makePuppetGeometry).
                // A directly referenced MDL has no 3D geometry/skinning path;
                // retain partial rendering without claiming model support.
                if model.filename.lowercased().hasSuffix(".mdl"), model.puppet == nil {
                    placeholders.insert("3d-models")
                }

            case .text:
                break
            case .light:
                if node.light?.castsShadow == true { placeholders.insert("light-shadows") }
            case .particle:
                if let particle = node.particle, particleNeedsPlaceholder(particle) {
                    placeholders.insert("particles")
                }
            case .sound:
                // Sound nodes play through the app-level SceneSoundPlayer.
                break
            case .group:
                break
            case .unknown:
                placeholders.insert("unknown-node-kinds")
            }
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
        !ParticleFeatureCatalog.isSupported(particle)
    }

    public func updatePropertyOverrides(_ overrides: [String: FrameValue]) {
        propertyOverrides = overrides
    }

    public func updateMediaState(_ state: SceneMediaState) {
        runtime.updateMediaState(state)
        materialBinder.updateMediaArtwork(
            state.enabled && state.thumbnail.hasThumbnail ? state.thumbnail.artwork : nil
        )
    }

    public func updateAudio(_ input: AudioInputState) {
        audioInput = input
    }

    public func updateCursorPosition(_ position: CGPoint) {
        updateCursorInput(position, leftDown: cursorLeftDown)
    }

    public func updateCursorInput(_ position: CGPoint, leftDown: Bool) {
        guard position.x.isFinite, position.y.isFinite else { return }
        let normalized = RuntimeVector2(x: Float(position.x), y: Float(position.y))
        cursorPosition = normalized
        cursorLeftDown = leftDown
        cursorEvents.append(CursorInputSample(position: normalized, leftDown: leftDown))
    }

    public func cancelCursorInteraction() {
        cursorEvents.cancel()
    }

    /// Receives terminal acknowledgements from the app-owned sound player. Stale
    /// completions are rejected by the runtime using the run identifier.
    public func updateSoundPlaybackStatus(nodeID: NodeID, runID: UInt64, finished: Bool) {
        runtime.updateSoundPlaybackStatus(nodeID: nodeID, runID: runID, finished: finished)
    }

    @discardableResult
    public func renderNextFrame(
        deltaTime: Double,
        into targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> FramePacket {
        let pendingCursor = cursorEvents.drain()
        let packet = runtime.step(
            deltaTime: deltaTime,
            propertyOverrides: propertyOverrides,
            audioInput: audioInput,
            cursorPosition: cursorPosition,
            cursorLeftDown: cursorLeftDown,
            cursorEvents: pendingCursor.samples,
            resetCursorEvents: pendingCursor.reset,
            viewportSize: RuntimeVector2(x: Float(targetTexture.width), y: Float(targetTexture.height))
        )
        let removed = runtime.removedNodeIDs
        if !removed.isEmpty {
            textRenderer.remove(nodeIDs: removed)
            materialBinder.removeSceneLayers(removed)
            effectTargetHistory = effectTargetHistory.filter { !removed.contains($0.key.nodeID) }
            warnedSkippedNodes.subtract(removed.map(\.rawValue))
        }
        try render(packet: packet, into: targetTexture, commandBuffer: commandBuffer)
        return packet
    }

    /// Debug-only capture of intermediate scene textures, populated when the
    /// WE_DEBUG_STAGES environment variable is set. Each entry is
    /// (label, RGBA8 buffer, width, height) readable after GPU completion.
    public private(set) var debugStageDumps: [(String, MTLBuffer, Int, Int)] = []
    // Debug options are launch configuration; avoid rebuilding the complete
    // process environment for every layer/pass when diagnostics are disabled.
    private let debugStagesEnabled = ProcessInfo.processInfo.environment["WE_DEBUG_STAGES"] != nil
    private let debugStageFilter = ProcessInfo.processInfo.environment["WE_DEBUG_STAGE_FILTER"]?.split(separator: ",").map(String.init)

    private func debugDumpStage(_ label: String, texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard debugStagesEnabled else {
            return
        }
        // Limit GPU readbacks when diagnosing a large workshop effect chain.
        if let filter = debugStageFilter,
           !filter.contains(where: { label.hasPrefix($0) }) {
            return
        }
        endSharedSceneEncoder()
        // The public debug buffers are RGBA8 previews. Convert numerical
        // targets before readback instead of interpreting half floats as bytes.
        let texture = materialBinder.sampledTexture(for: texture)
        let preview: MTLTexture
        if texture.pixelFormat == .rgba8Unorm {
            preview = texture
        } else {
            do {
                preview = try makeRenderTexture(width: texture.width, height: texture.height)
                try postProcessPass.copyTexture(source: texture, destination: preview, commandBuffer: commandBuffer)
            } catch {
                return
            }
        }
        let bytesPerRow = texture.width * 4
        guard let buffer = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(
            from: preview,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height
        )
        blit.endEncoding()
        debugStageDumps.append((label, buffer, texture.width, texture.height))
    }

    public func render(
        packet: FramePacket,
        into targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let graph = scene.scene else {
            throw NativeSceneRendererError.missingSceneGraph
        }
        defer { endSharedSceneEncoder() }
        debugStageDumps.removeAll()
        effectTextureFormats.removeAll(keepingCapacity: true)
        materialBinder.resetEffectTextureViews()
        materialBinder.updateSceneLighting(packet: packet, scene: scene)

        let clear = defaultClearColor(from: graph.clearColor)

        let materialsByID = Dictionary(packet.materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let particleSystemsByID = Dictionary(uniqueKeysWithValues: packet.particleSystems.map { ($0.nodeID, $0) })
        let textsByID = Dictionary(packet.texts.map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let viewportSize = CGSize(width: targetTexture.width, height: targetTexture.height)
        try recycleRenderTextures(commandBuffer: commandBuffer)
        var currentScene = try makeRenderTexture(width: targetTexture.width, height: targetTexture.height)
        var nextScene = try makeRenderTexture(width: targetTexture.width, height: targetTexture.height)
        try clearTexture(currentScene, color: clear, commandBuffer: commandBuffer)
        try clearTexture(nextScene, color: clear, commandBuffer: commandBuffer)

        var sceneDepth: MTLTexture?
        if scene.nodes.contains(where: { $0.image?.model?.filename.lowercased().hasSuffix(".mdl") == true }) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: targetTexture.width, height: targetTexture.height, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            guard let depth = device.makeTexture(descriptor: descriptor) else { throw NativeSceneRendererError.commandEncodingFailed }
            sceneDepth = depth
            let clear = MTLRenderPassDescriptor()
            clear.depthAttachment.texture = depth
            clear.depthAttachment.loadAction = .clear
            clear.depthAttachment.storeAction = .store
            clear.depthAttachment.clearDepth = 1
            endSharedSceneEncoder()
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: clear) else { throw NativeSceneRendererError.commandEncodingFailed }
            encoder.endEncoding()
        }

        var sceneNamedTextures: [String: MTLTexture] = [
            "_rt_FullFrameBuffer": currentScene,
            "_rt_MipMappedFrameBuffer": currentScene,
        ]

        debugDumpStage("00-after-clear", texture: currentScene, commandBuffer: commandBuffer)

        let nodeDescriptorsByID = Dictionary(scene.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for draw in sceneDraws(packet: packet, materials: materialsByID, descriptors: nodeDescriptorsByID) {
            let frameNode = draw.frame
            guard let nodeDescriptor = nodeDescriptorsByID[frameNode.nodeID] else {
                continue
            }
            // Preparation sees the current scene's format. Active reflection
            // readers receive a separate mipmapped snapshot before drawing.
            sceneNamedTextures["_rt_MipMappedFrameBuffer"] = currentScene

            if nodeDescriptor.image != nil {
                let rendered: MTLTexture?
                do {
                    if let depth = sceneDepth, nodeDescriptor.image?.model?.filename.lowercased().hasSuffix(".mdl") == true {
                        rendered = try renderDirectModelNode(frameNode: frameNode, node: nodeDescriptor, packet: packet,
                            materials: materialsByID, currentScene: currentScene, destinationScene: nextScene,
                            namedTextures: sceneNamedTextures, depth: depth, viewport: viewportSize, commandBuffer: commandBuffer,
                            geometryOverride: draw.geometry, materialOverride: draw.material)
                    } else {
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
                    }
                } catch {
                    if !warnedSkippedNodes.contains(frameNode.nodeID.rawValue) {
                        print("[NativeSceneRenderer] Skipping image node \(frameNode.nodeID.rawValue): \(error.localizedDescription)")
                        warnedSkippedNodes.insert(frameNode.nodeID.rawValue)
                    }
                    continue
                }
                if let rendered, rendered === nextScene {
                    swap(&currentScene, &nextScene)
                    sceneNamedTextures["_rt_FullFrameBuffer"] = currentScene
                }
                debugDumpStage("node\(frameNode.nodeID.rawValue)-\(frameNode.name)", texture: currentScene, commandBuffer: commandBuffer)
            } else if nodeDescriptor.particle != nil,
                      let particleSystem = particleSystemsByID[frameNode.nodeID],
                      particleSystem.visible {
                var particleTextures = sceneNamedTextures
                if try particleRenderer.requiresSceneMipmaps(system: particleSystem, materialsByID: materialsByID,
                    materialBinder: materialBinder, sceneNamedTextures: particleTextures, viewportSize: viewportSize) {
                    particleTextures["_rt_MipMappedFrameBuffer"] = try captureSceneMipmaps(currentScene, commandBuffer: commandBuffer)
                }
                let samplesScene = try particleRenderer.samplesTexture(currentScene, system: particleSystem,
                    materialsByID: materialsByID, materialBinder: materialBinder,
                    sceneNamedTextures: particleTextures, viewportSize: viewportSize)
                if samplesScene {
                    try copyTexture(from: currentScene, to: nextScene, commandBuffer: commandBuffer)
                }
                try renderParticleNode(
                    frameNode: frameNode,
                    nodeDescriptor: nodeDescriptor,
                    particleSystem: particleSystem,
                    packet: packet,
                    materialsByID: materialsByID,
                    sceneNamedTextures: particleTextures,
                    destinationScene: samplesScene ? nextScene : currentScene,
                    viewportSize: viewportSize,
                    commandBuffer: commandBuffer
                )
                if samplesScene {
                    swap(&currentScene, &nextScene)
                    sceneNamedTextures["_rt_FullFrameBuffer"] = currentScene
                }
                debugDumpStage("node\(frameNode.nodeID.rawValue)-\(frameNode.name)", texture: currentScene, commandBuffer: commandBuffer)
            } else if let text = textsByID[frameNode.nodeID], text.visible {
                do {
                    if frameNode.imageEffects.isEmpty {
                        // Plain text samples only its glyph texture, so it can
                        // blend in place without copying the whole scene.
                        try renderTexts(texts: [text], packet: packet, destinationScene: currentScene,
                                        commandBuffer: commandBuffer)
                    } else {
                        try copyTexture(from: currentScene, to: nextScene, commandBuffer: commandBuffer)
                        try renderTextNodeWithEffects(
                            text: text,
                            frameNode: frameNode,
                            nodeDescriptor: nodeDescriptor,
                            packet: packet,
                            materialsByID: materialsByID,
                            currentScene: currentScene,
                            destinationScene: nextScene,
                            viewportSize: viewportSize,
                            commandBuffer: commandBuffer
                        )
                        swap(&currentScene, &nextScene)
                        sceneNamedTextures["_rt_FullFrameBuffer"] = currentScene
                    }
                } catch {
                    if !warnedSkippedNodes.contains(frameNode.nodeID.rawValue) {
                        print("[NativeSceneRenderer] Text effect chain failed for node \(frameNode.nodeID.rawValue): \(error.localizedDescription)")
                        warnedSkippedNodes.insert(frameNode.nodeID.rawValue)
                    }
                }
                debugDumpStage("node\(frameNode.nodeID.rawValue)-\(frameNode.name)", texture: currentScene, commandBuffer: commandBuffer)
            }
        }

        endSharedSceneEncoder()
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
        packet: FramePacket,
        materialsByID: [String: FrameMaterial],
        sceneNamedTextures: [String: MTLTexture],
        destinationScene: MTLTexture,
        viewportSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let encoder = try sceneEncoder(for: destinationScene, commandBuffer: commandBuffer)

        try renderParticleSystemTree(
            system: particleSystem,
            frameNode: frameNode,
            nodeDescriptor: nodeDescriptor,
            packet: packet,
            materialsByID: materialsByID,
            sceneNamedTextures: sceneNamedTextures,
            viewportSize: viewportSize,
            encoder: encoder
        )
    }

    /// Renders a particle system and its child systems (depth-first, parent
    /// first) into an already-open encoder. Systems without a resolvable
    /// material still render children, which carry their own materials.
    private func renderParticleSystemTree(
        system: FrameParticleSystem,
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        packet: FramePacket,
        materialsByID: [String: FrameMaterial],
        sceneNamedTextures: [String: MTLTexture],
        viewportSize: CGSize,
        inheritedOpacity: Float = 1,
        encoder: MTLRenderCommandEncoder
    ) throws {
        if let materialID = system.materialReference,
           let material = materialsByID[materialID] {
            for passIndex in material.passOrdering {
                guard let pass = material.passes.first(where: { $0.index == passIndex }) else { continue }
                try particleRenderer.render(
                    system: system,
                    frameNode: frameNode,
                    nodeDescriptor: nodeDescriptor,
                    packet: packet,
                    material: material,
                    pass: pass,
                    materialBinder: materialBinder,
                    sceneNamedTextures: sceneNamedTextures,
                    scene: scene,
                    viewportSize: viewportSize,
                    inheritedOpacity: inheritedOpacity,
                    encoder: encoder
                )
            }
        }

        for child in system.childSystems {
            try renderParticleSystemTree(
                system: child,
                frameNode: frameNode,
                nodeDescriptor: nodeDescriptor,
                packet: packet,
                materialsByID: materialsByID,
                sceneNamedTextures: sceneNamedTextures,
                viewportSize: viewportSize,
                // Root instances already contain their layer's alpha. Child
                // instances have independent initialization and inherit it here.
                inheritedOpacity: Float(frameNode.opacity ?? 1),
                encoder: encoder
            )
        }
    }

    /// Fullscreen effects and painted layers bound a 3D drawing batch. Within
    /// each batch, opaque sections establish depth before translucent sections
    /// blend from back to front. Material passes retain their authored order.
    private func sceneDraws(packet: FramePacket, materials: [String: FrameMaterial],
                            descriptors: [NodeID: NodeDescriptor]) -> [SceneDraw] {
        let nodes = passGraph.nodesInRenderOrder(packet.nodes)
        guard scene.scene?.camera.projection.isPerspective == true else { return nodes.map { SceneDraw(frame: $0) } }
        var result: [SceneDraw] = [], batch: [SceneDraw] = []

        func flush() {
            let preferred = batch.indices.sorted { a, b in
                if batch[a].isTranslucent != batch[b].isTranslucent { return !batch[a].isTranslucent }
                if batch[a].isTranslucent, batch[a].cameraDepth != batch[b].cameraDepth {
                    return batch[a].cameraDepth > batch[b].cameraDepth
                }
                return a < b
            }
            let indicesByNode = Dictionary(grouping: batch.indices, by: { batch[$0].frame.nodeID })
            var visited: Set<Int> = []
            func visit(_ index: Int) {
                guard visited.insert(index).inserted else { return }
                for dependency in batch[index].frame.dependencyIDs where dependency != batch[index].frame.nodeID {
                    for producer in indicesByNode[dependency] ?? [] { visit(producer) }
                }
                result.append(batch[index])
            }
            for index in preferred { visit(index) }
            batch.removeAll(keepingCapacity: true)
        }

        for frame in nodes {
            guard let node = descriptors[frame.nodeID] else { continue }
            if let path = node.image?.model?.filename, path.lowercased().hasSuffix(".mdl"), frame.visible {
                do {
                    let geometries = try directModelRenderer.geometry(path: path, frame: frame,
                        time: packet.timing.elapsedTime, device: device)
                    let draws = try geometries.map { geometry -> SceneDraw in
                        guard let material = frame.renderItemReferences.compactMap({ materials[$0] }).first(where: { $0.sourceFile == geometry.material }) else {
                            throw NativeSceneRendererError.unsupportedScene("missing model material \(geometry.material)")
                        }
                        return SceneDraw(frame: frame, geometry: geometry, material: material,
                            cameraDepth: DirectModelRenderer.cameraDepth(geometry: geometry, frame: frame, scene: scene))
                    }
                    batch.append(contentsOf: draws)
                } catch {
                    if warnedSkippedNodes.insert(frame.nodeID.rawValue).inserted {
                        print("[NativeSceneRenderer] Skipping image node \(frame.nodeID.rawValue): \(error.localizedDescription)")
                    }
                }
            } else {
                if node.image != nil || node.particle != nil || node.text != nil { flush() }
                result.append(SceneDraw(frame: frame))
            }
        }
        flush()
        return result
    }

    private func renderDirectModelNode(
        frameNode: FrameNode, node: NodeDescriptor, packet: FramePacket, materials: [String: FrameMaterial],
        currentScene: MTLTexture, destinationScene: MTLTexture, namedTextures: [String: MTLTexture],
        depth: MTLTexture, viewport: CGSize, commandBuffer: MTLCommandBuffer,
        geometryOverride: DirectModelRenderer.Geometry? = nil, materialOverride: FrameMaterial? = nil
    ) throws -> MTLTexture? {
        guard frameNode.visible, let path = node.image?.model?.filename else { return nil }
        let geometries = try geometryOverride.map { [$0] }
            ?? directModelRenderer.geometry(path: path, frame: frameNode, time: packet.timing.elapsedTime, device: device)
        let uniforms = DirectModelRenderer.uniforms(node: node, frame: frameNode, scene: scene, viewport: viewport, cameraZoom: packet.cameraZoom)
        var current = currentScene, other = destinationScene
        // In a 2D composition each model is a painted layer. Its mesh sections
        // share depth, but a previous layer may use a different projection and
        // must not leave incompatible depth values behind. Full 3D scenes keep
        // one depth buffer for all models viewed through the scene camera.
        var clearDepth = scene.scene?.camera.projection.isPerspective != true
        for geometry in geometries {
            guard let material = materialOverride ?? frameNode.renderItemReferences.compactMap({ materials[$0] }).first(where: { $0.sourceFile == geometry.material }) else {
                throw NativeSceneRendererError.unsupportedScene("missing model material \(geometry.material)")
            }
            for index in material.passOrdering {
                guard let authored = material.passes.first(where: { $0.index == index }) else { continue }
                // Skinning has already transformed position, normal and tangent
                // buffers on the CPU; do not apply the shader palette again.
                let pass = FrameMaterialPass(index: authored.index, shaderPath: authored.shaderPath,
                    blending: authored.blending, culling: authored.culling, depthTest: authored.depthTest, depthWrite: authored.depthWrite,
                    textures: authored.textures, userTextures: authored.userTextures, constants: authored.constants,
                    combos: authored.combos.merging(["SKINNING": 0]) { _, new in new })
                var textures = namedTextures
                textures["_rt_FullFrameBuffer"] = current
                var context = MaterialBindingContext(viewportSize: viewport, textureOverridesByName: textures,
                    uniformOverrides: uniforms, depthAttachmentPixelFormat: .depth32Float)
                let prepared = try materialBinder.preparePass(material: material, pass: pass, bindingContext: context)
                context = try reflectionBindingContext(context, preparedPass: prepared, sceneTexture: current, commandBuffer: commandBuffer)
                let samplesScene = try materialBinder.samplesTexture(current, preparedPass: prepared, bindingContext: context)
                if samplesScene { try copyTexture(from: current, to: other, commandBuffer: commandBuffer) }
                let descriptor = renderPassDescriptor(for: samplesScene ? other : current, loadAction: .load)
                descriptor.depthAttachment.texture = depth
                descriptor.depthAttachment.loadAction = clearDepth ? .clear : .load
                descriptor.depthAttachment.clearDepth = 1
                descriptor.depthAttachment.storeAction = .store
                endSharedSceneEncoder()
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                    throw NativeSceneRendererError.commandEncodingFailed
                }
                do {
                    defer { encoder.endEncoding() }
                    try materialBinder.bind(preparedPass: prepared, frameNode: frameNode, nodeDescriptor: node,
                        scene: scene, packet: packet, positions: geometry.positions, texCoords: geometry.texCoords,
                        vertexCount: geometry.vertexCount, encoder: encoder, bindingContext: context,
                        vertexAttributeBuffers: geometry.attributes)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
                }
                clearDepth = false
                if samplesScene { swap(&current, &other) }
            }
        }
        return current
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
    ) throws -> MTLTexture? {
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
                device: device,
                elapsedTime: packet.timing.elapsedTime,
                animationLayers: frameNode.animationLayers,
                alignment: frameNode.imageAlignment
              ),
              let copyGeometry = imageRenderer.makeOffscreenCopyGeometry(size: imageSize, device: device),
              let passGeometry = imageRenderer.makeOffscreenPassGeometry(device: device) else {
            return nil
        }

        var chainSteps = buildImageChain(baseMaterial: baseMaterial, frameNode: frameNode,
                                        colorBlendMode: nodeDescriptor.image?.colorBlendMode ?? 0,
                                        materialsByID: materialsByID)
        let isPassthrough = nodeDescriptor.image?.model?.passthrough == true
        if isPassthrough && chainSteps.count == 1 && frameNode.visible {
            // Compose layers first capture the scene into their local A
            // texture, even without effects. Consumers can sample that capture.
            let pass = FrameMaterialPass(index: 0, shaderPath: "genericimage3", blending: 1,
                culling: 0, depthTest: 0, depthWrite: 0, textures: [], userTextures: [], constants: [:], combos: [:])
            let material = FrameMaterial(id: "\(baseMaterial.id):composeCopy", sourceNodeID: frameNode.nodeID,
                sourceFile: "materials/util/effectpassthrough.json", passOrdering: [0], passes: [pass])
            chainSteps.append(ImageChainStep(material: material, pass: pass, binds: [], target: nil,
                                            command: nil, source: nil, isColorBlend: true))
        }
        guard let lastScenePassIndex = chainSteps.lastIndex(where: { $0.material != nil && $0.pass != nil && $0.target == nil }) else {
            return nil
        }

        let usesScreenSpaceGeometry = nodeDescriptor.image?.model?.fullscreen == true
        let alignment = imageRenderer.alignmentOffset(frameNode.imageAlignment ?? nodeDescriptor.image?.alignment ?? "center", size: imageSize)
        var copyToLayer = matrix_identity_float4x4
        copyToLayer.columns.3 = SIMD4(alignment.x - Float(imageSize.width / 2), alignment.y - Float(imageSize.height / 2), 0, 1)
        let offscreenLayerModel = frameNode.worldTransform.simdValue * copyToLayer

        var namedTextures = sceneNamedTextures
        let compositeAName = "_rt_imageLayerComposite_\(frameNode.nodeID.rawValue)_a"
        let compositeBName = "_rt_imageLayerComposite_\(frameNode.nodeID.rawValue)_b"
        var currentMain = try makeRenderTexture(width: Int(imageSize.width), height: Int(imageSize.height))
        var currentSub = try makeRenderTexture(width: Int(imageSize.width), height: Int(imageSize.height))
        namedTextures[compositeAName] = currentMain
        namedTextures[compositeBName] = currentSub
        if !frameNode.visible {
            let transparent = RuntimeVector4.zero
            try clearTexture(currentMain, color: transparent, commandBuffer: commandBuffer)
            try clearTexture(currentSub, color: transparent, commandBuffer: commandBuffer)
        }

        let effectTargets = try makeEffectTargets(frameNode: frameNode, size: imageSize,
            backbufferFormat: currentScene.pixelFormat, materialsByID: materialsByID, commandBuffer: commandBuffer)
        for index in effectTargets.keys.sorted() {
            namedTextures.merge(effectTargets[index]!.textures) { _, new in new }
        }

        var chainInputTexture: MTLTexture?
        var writtenTargets = Set<ObjectIdentifier>()
        var renderedScene: MTLTexture?

        for (index, step) in chainSteps.enumerated() {
            let ownedTargets = step.effectIndex.flatMap { effectTargets[$0] }
            if let ownedTargets {
                namedTextures.merge(ownedTargets.textures) { _, new in new }
            }
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
                    if ownedTargets?.textures[source] != nil { ownedTargets?.textures[source] = targetTexture }
                    if ownedTargets?.textures[target] != nil { ownedTargets?.textures[target] = sourceTexture }
                } else {
                    try copyTexture(from: sourceTexture, to: targetTexture, commandBuffer: commandBuffer)
                    writtenTargets.insert(ObjectIdentifier(targetTexture))
                }
                continue
            }

            guard let material = step.material,
                  var pass = step.pass else {
                continue
            }

            let isScenePass = frameNode.visible && index == lastScenePassIndex
            if let basePass = baseMaterial.passes.first,
               (isScenePass && index > 0) || (index == 0 && lastScenePassIndex > 0) {
                // The final composite onto the scene uses the image's authored
                // blending; effect materials often declare opaque blending
                // meant only for offscreen ping-pong passes.
                pass = FrameMaterialPass(
                    index: pass.index,
                    shaderPath: pass.shaderPath,
                    // Store straight color/alpha in the initial offscreen
                    // texture; apply the authored blending only at composite.
                    blending: isScenePass ? basePass.blending : 1,
                    culling: pass.culling,
                    depthTest: pass.depthTest,
                    depthWrite: pass.depthWrite,
                    textures: pass.textures,
                    userTextures: pass.userTextures,
                    constants: pass.constants,
                    combos: pass.combos
                )
            }
            let isFirstPass = chainInputTexture == nil
            let capturesScene = isFirstPass && isPassthrough
            let prelightsLayer = isFirstPass && !isScenePass && !usesScreenSpaceGeometry && !capturesScene
            if prelightsLayer {
                pass = FrameMaterialPass(index: pass.index, shaderPath: pass.shaderPath,
                    blending: pass.blending, culling: pass.culling, depthTest: pass.depthTest, depthWrite: pass.depthWrite,
                    textures: pass.textures, userTextures: pass.userTextures, constants: pass.constants,
                    combos: pass.combos.merging(["PRELIGHTING": 1]) { _, value in value })
            }
            var targetTexture: MTLTexture
            let geometry: ImageRenderer.SceneGeometry
            var bindingContext: MaterialBindingContext
            let loadAction: MTLLoadAction
            // The layer tint and opacity have already been applied by the
            // base material. The appended blend shader consumes that result.
            let blendUniforms = step.isColorBlend
                ? ["g_Color4": localRendererBytes(of: SIMD4<Float>(repeating: 1))]
                : [:]

            if isScenePass {
                targetTexture = destinationScene
                // Only fullscreen models bypass the layer transform. Local
                // compose layers composite effects back into their own region.
                geometry = usesScreenSpaceGeometry ? passGeometry : sceneGeometry
                bindingContext = MaterialBindingContext(
                    viewportSize: viewportSize,
                    textureOverridesBySlot: textureSlotOverrides(
                        binds: step.binds,
                        chainInputTexture: chainInputTexture,
                        namedTextures: namedTextures,
                        currentScene: currentScene
                    ),
                    textureOverridesByName: namedTextures.merging(["_rt_FullFrameBuffer": currentScene]) { _, new in new },
                    uniformOverrides: (usesScreenSpaceGeometry
                        ? offscreenUniformOverrides(targetSize: viewportSize, firstPass: false)
                        : [:]).merging(blendUniforms) { _, new in new }
                )
                loadAction = .load
            } else {
                if let target = step.target, let explicitTarget = namedTextures[target] {
                    targetTexture = explicitTarget
                    loadAction = writtenTargets.contains(ObjectIdentifier(explicitTarget)) ? .load : .clear
                    writtenTargets.insert(ObjectIdentifier(explicitTarget))
                } else {
                    targetTexture = currentMain
                    loadAction = .clear
                }

                geometry = capturesScene && !usesScreenSpaceGeometry ? sceneGeometry
                    : isFirstPass && !usesScreenSpaceGeometry ? copyGeometry : passGeometry
                bindingContext = MaterialBindingContext(
                    viewportSize: capturesScene ? viewportSize : CGSize(width: targetTexture.width, height: targetTexture.height),
                    textureOverridesBySlot: textureSlotOverrides(
                        binds: step.binds,
                        chainInputTexture: chainInputTexture,
                        namedTextures: namedTextures,
                        currentScene: currentScene
                    ),
                    textureOverridesByName: namedTextures.merging(["_rt_FullFrameBuffer": currentScene]) { _, new in new },
                    // The compose shader derives scene sampling coordinates
                    // from its world transform but fills the target via UVs.
                    uniformOverrides: (capturesScene && !usesScreenSpaceGeometry ? [:] : offscreenUniformOverrides(
                        targetSize: CGSize(width: targetTexture.width, height: targetTexture.height),
                        firstPass: isFirstPass && !usesScreenSpaceGeometry,
                        layerModel: prelightsLayer ? offscreenLayerModel : nil,
                        sceneViewProjection: prelightsLayer ? materialBinder.sceneViewProjection(scene: scene, viewportSize: viewportSize, cameraZoom: packet.cameraZoom) : nil
                    )).merging(blendUniforms) { _, new in new }
                )
            }

            let preparedPass = try materialBinder.preparePass(material: material, pass: pass,
                bindingContext: bindingContext, colorAttachmentPixelFormat: targetTexture.pixelFormat)
            bindingContext = try reflectionBindingContext(bindingContext, preparedPass: preparedPass,
                sceneTexture: currentScene, commandBuffer: commandBuffer, textureBinds: step.binds)
            if isScenePass {
                // Blend ordinary layers directly onto the existing scene. A
                // shader sampling that scene needs a separate destination, as
                // do chains with later commands that can still read the input.
                if index == chainSteps.count - 1,
                   try !materialBinder.samplesTexture(currentScene, preparedPass: preparedPass, bindingContext: bindingContext) {
                    targetTexture = currentScene
                } else {
                    try copyTexture(from: currentScene, to: destinationScene, commandBuffer: commandBuffer)
                }
                renderedScene = targetTexture
            }
            do {
                let encoder: MTLRenderCommandEncoder
                if isScenePass {
                    encoder = try sceneEncoder(for: targetTexture, commandBuffer: commandBuffer)
                } else {
                    endSharedSceneEncoder()
                    guard let offscreen = commandBuffer.makeRenderCommandEncoder(
                        descriptor: renderPassDescriptor(for: targetTexture, loadAction: loadAction)) else {
                        throw NativeSceneRendererError.commandEncodingFailed
                    }
                    encoder = offscreen
                }
                defer { if !isScenePass { encoder.endEncoding() } }

                try lightingPass.prepare(packet: packet, encoder: encoder)
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
                    bindingContext: bindingContext
                )
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
            }
            debugDumpStage(
                "chain\(frameNode.nodeID.rawValue)-step\(index)-\(pass.shaderPath.replacingOccurrences(of: "/", with: "_"))",
                texture: targetTexture,
                commandBuffer: commandBuffer
            )

            if !isScenePass, step.target == nil {
                chainInputTexture = currentMain
                swap(&currentMain, &currentSub)
                // Authored names identify the physical A/B textures, not the
                // next ping-pong destination. Consumers may request either one.
            }
        }

        retainEffectTargets(effectTargets)
        sceneNamedTextures.merge(namedTextures) { _, new in new }
        return renderedScene
    }

    private func buildImageChain(
        baseMaterial: FrameMaterial,
        frameNode: FrameNode,
        colorBlendMode: Int,
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

        steps.append(contentsOf: buildEffectSteps(frameNode: frameNode, materialsByID: materialsByID))

        if colorBlendMode > 0 {
            // WE implements layer color blending with the stock passthrough
            // shader after the complete effect chain, sampling the scene in
            // g_Texture4. Keep the authored blend equations in that shader.
            let pass = FrameMaterialPass(
                index: 0, shaderPath: "genericimage3", blending: 1,
                culling: 0, depthTest: 0, depthWrite: 0,
                textures: [], userTextures: [], constants: [:], combos: ["BLENDMODE": colorBlendMode]
            )
            let material = FrameMaterial(
                id: "\(baseMaterial.id):colorBlend", sourceNodeID: frameNode.nodeID,
                sourceFile: "materials/util/effectpassthrough.json", passOrdering: [0], passes: [pass]
            )
            steps.append(ImageChainStep(material: material, pass: pass, binds: [], target: nil,
                                        command: nil, source: nil, isColorBlend: true))
        }

        return steps
    }

    private func buildEffectSteps(
        frameNode: FrameNode,
        materialsByID: [String: FrameMaterial]
    ) -> [ImageChainStep] {
        var steps: [ImageChainStep] = []

        for (effectIndex, effect) in frameNode.imageEffects.enumerated() {
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
                                source: nil,
                                effectIndex: effectIndex
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
                            source: effectPass.source,
                            effectIndex: effectIndex
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
        firstPass: Bool,
        layerModel: simd_float4x4? = nil,
        sceneViewProjection: simd_float4x4? = nil
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
        let modelViewProjection = firstPass ? ortho : identity4
        let modelMatrix = layerModel ?? modelViewProjection
        let modelInverse = abs(simd_determinant(modelMatrix)) > 1e-10 ? simd_inverse(modelMatrix) : identity4
        let normalMatrix = layerModel.map(MaterialBinder.normalMatrix(for:)) ?? identity3
        let viewProjection = layerModel.map {
            abs(simd_determinant($0)) > 1e-10 ? modelViewProjection * simd_inverse($0) : modelViewProjection
        } ?? identity4

        return [
            "g_ModelViewProjectionMatrix": localRendererBytes(of: modelViewProjection),
            "g_ModelViewProjectionMatrixInverse": localRendererBytes(of: simd_inverse(modelViewProjection)),
            "g_ModelMatrix": localRendererBytes(of: modelMatrix),
            "g_ModelMatrixInverse": localRendererBytes(of: modelInverse),
            "g_AltModelMatrix": localRendererBytes(of: modelMatrix),
            "g_ViewProjectionMatrix": localRendererBytes(of: viewProjection),
            "g_AltViewProjectionMatrix": localRendererBytes(of: sceneViewProjection ?? viewProjection),
            "g_NormalModelMatrix": localRendererBytes(of: normalMatrix),
            "g_AltNormalModelMatrix": localRendererBytes(of: normalMatrix),
        ]
    }

    /// Consecutive draws that blend onto the same scene texture share one
    /// render pass. A tile-based GPU loads and stores the whole target for
    /// every pass, so a pass per layer, particle system or text quad dominated
    /// GPU time in busy scenes. Every other encoder must call
    /// `endSharedSceneEncoder()` first; draws and their order are unchanged.
    private func sceneEncoder(for target: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLRenderCommandEncoder {
        if let shared = sharedSceneEncoder, shared.target === target, shared.commandBuffer === commandBuffer {
            return shared.encoder
        }
        endSharedSceneEncoder()
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor(for: target, loadAction: .load)) else {
            throw NativeSceneRendererError.commandEncodingFailed
        }
        sharedSceneEncoder = (encoder, target, commandBuffer)
        return encoder
    }

    private func endSharedSceneEncoder() {
        sharedSceneEncoder?.encoder.endEncoding()
        sharedSceneEncoder = nil
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
        endSharedSceneEncoder()
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
        guard source !== destination else { return }
        endSharedSceneEncoder()
        let sampledSource = materialBinder.sampledTexture(for: source)
        if source.pixelFormat != destination.pixelFormat || sampledSource !== source {
            // Native blits require identical formats and do not apply channel
            // swizzles. Preserve the existing overlapping, unscaled region.
            try postProcessPass.copyTexture(source: sampledSource, destination: destination,
                commandBuffer: commandBuffer,
                region: MTLSize(width: min(source.width, destination.width),
                                height: min(source.height, destination.height), depth: 1))
            return
        }
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

    /// Preserve only initial contents that the pass graph reads before replacing,
    /// plus explicitly unique targets. Ordinary blur/composite scratch stays transient.
    private func retainedTargetNames(
        for effect: FrameImageEffect,
        materialsByID: [String: FrameMaterial]
    ) -> Set<String> {
        var initialOrigins: [String: String] = [:]
        var retained = Set<String>()
        for target in effect.renderTargets {
            initialOrigins[target.name] = target.name
            if target.unique { retained.insert(target.name) }
        }
        func read(_ name: String?) {
            if let name, let origin = initialOrigins[name] { retained.insert(origin) }
        }
        for step in effect.passes {
            if let reference = step.materialReference, let material = materialsByID[reference] {
                for index in material.passOrdering {
                    guard let pass = material.passes.first(where: { $0.index == index }) else { continue }
                    for binding in step.binds + pass.textures + pass.userTextures { read(binding.path) }
                    if let target = step.target { initialOrigins[target] = nil }
                }
            } else if step.command == 1, let source = step.source, let target = step.target {
                let sourceOrigin = initialOrigins[source]
                initialOrigins[source] = initialOrigins[target]
                initialOrigins[target] = sourceOrigin
            } else if step.command != nil {
                read(step.source)
                if let target = step.target { initialOrigins[target] = nil }
            }
        }
        return retained
    }

    private func makeEffectTargets(
        frameNode: FrameNode,
        size: CGSize,
        backbufferFormat: MTLPixelFormat,
        materialsByID: [String: FrameMaterial],
        commandBuffer: MTLCommandBuffer
    ) throws -> [Int: EffectTargets] {
        var result: [Int: EffectTargets] = [:]
        for (index, effect) in frameNode.imageEffects.enumerated() {
            let owner = EffectTargetOwner(nodeID: frameNode.nodeID, sourceIndex: effect.sourceIndex ?? index)
            let retained = retainedTargetNames(for: effect, materialsByID: materialsByID)
            var textures: [String: MTLTexture] = [:]
            for target in effect.renderTargets {
                let authoredFormat = EffectRenderTargetFormat(rawValue: target.format.lowercased())
                if authoredFormat == nil, warnedTargetFormats.insert(target.format).inserted {
                    print("[NativeSceneRenderer] Unsupported effect target format '\(target.format)'; using rgba8888")
                }
                let format = authoredFormat ?? .rgba8888
                let pixelFormat = format.pixelFormat(backbuffer: backbufferFormat)
                let width = max(Int((size.width / max(target.scale, 1)).rounded(.toNearestOrAwayFromZero)), 1)
                let height = max(Int((size.height / max(target.scale, 1)).rounded(.toNearestOrAwayFromZero)), 1)
                let texture: MTLTexture
                if retained.contains(target.name), let cached = effectTargetHistory[owner]?[target.name],
                   cached.texture.width == width, cached.texture.height == height,
                   cached.texture.pixelFormat == pixelFormat, cached.format == format {
                    texture = cached.texture
                } else {
                    texture = try makeRenderTexture(width: width, height: height, pixelFormat: pixelFormat)
                    if retained.contains(target.name) {
                        try clearTexture(texture, color: .zero, commandBuffer: commandBuffer)
                    }
                }
                textures[target.name] = texture
                effectTextureFormats[ObjectIdentifier(texture)] = format
                if format == .rgb161616f {
                    // Swizzled textures cannot be render attachments. Keep
                    // identity storage for writes and a separate sampling view.
                    guard let view = texture.makeTextureView(pixelFormat: pixelFormat, textureType: .type2D,
                        levels: 0..<1, slices: 0..<1,
                        swizzle: MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: format.alphaSwizzle)) else {
                        throw NativeSceneRendererError.unsupportedScene("failed to create RGB effect sampling view")
                    }
                    materialBinder.setEffectTextureView(view, for: texture)
                }
            }
            result[index] = EffectTargets(owner: owner, retainedNames: retained, textures: textures)
        }
        return result
    }

    private func retainEffectTargets(_ targets: [Int: EffectTargets]) {
        for state in targets.values {
            // Store logical names after command swaps. Replacing this owner map
            // also releases superseded dimensions instead of caching every size.
            let retained = state.textures.filter { state.retainedNames.contains($0.key) }.mapValues {
                RetainedEffectTexture(texture: $0, format: effectTextureFormats[ObjectIdentifier($0)] ?? .rgba8888)
            }
            effectTargetHistory[state.owner] = retained.isEmpty ? nil : retained
        }
    }

    /// Returns last frame's render textures to the reuse pool. Allocating
    /// every intermediate target per frame costs hundreds of MB of fresh GPU
    /// memory at 4K. Textures that effects keep across frames stay out of the
    /// pool, and anything not reused this frame is released at the next call.
    /// Pooled textures are cleared here, before any encoder is open, so they
    /// match a fresh allocation's transparent contents.
    private func recycleRenderTextures(commandBuffer: MTLCommandBuffer) throws {
        let retained = Set(effectTargetHistory.values.flatMap { $0.values.map { ObjectIdentifier($0.texture) } })
        reusableRenderTextures.removeAll(keepingCapacity: true)
        for texture in leasedRenderTextures where !retained.contains(ObjectIdentifier(texture)) {
            let key = RenderTextureKey(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
            try clearTexture(texture, color: .zero, commandBuffer: commandBuffer)
            reusableRenderTextures[key, default: []].append(texture)
        }
        leasedRenderTextures.removeAll(keepingCapacity: true)
    }

    private func makeRenderTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .rgba8Unorm
    ) throws -> MTLTexture {
        let key = RenderTextureKey(width: max(width, 1), height: max(height, 1), pixelFormat: pixelFormat)
        if let texture = reusableRenderTextures[key]?.popLast() {
            leasedRenderTextures.append(texture)
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: key.width,
            height: key.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NativeSceneRendererError.unsupportedScene("failed to allocate render texture")
        }
        leasedRenderTextures.append(texture)
        return texture
    }

    private func captureSceneMipmaps(_ source: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let texture: MTLTexture
        if let cached = sceneReflectionTexture, cached.width == source.width, cached.height == source.height,
           cached.pixelFormat == source.pixelFormat {
            texture = cached
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                width: source.width, height: source.height, mipmapped: true)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .private
            guard let allocated = device.makeTexture(descriptor: descriptor) else { throw NativeSceneRendererError.commandEncodingFailed }
            sceneReflectionTexture = allocated
            texture = allocated
        }
        try copyTexture(from: source, to: texture, commandBuffer: commandBuffer)
        if texture.mipmapLevelCount > 1 {
            endSharedSceneEncoder()
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw NativeSceneRendererError.commandEncodingFailed }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        return texture
    }

    private func reflectionBindingContext(_ context: MaterialBindingContext, preparedPass: PreparedMaterialPass,
                                          sceneTexture: MTLTexture, commandBuffer: MTLCommandBuffer,
                                          textureBinds: [FrameTextureBinding] = []) throws -> MaterialBindingContext {
        let pathsBySlot = Dictionary(textureBinds.map { ($0.slot, $0.path) }, uniquingKeysWith: { _, last in last })
        let mipSlots = Set(pathsBySlot.filter { $0.value == "_rt_MipMappedFrameBuffer" }.keys)
        guard materialBinder.requiresSceneMipmaps(preparedPass: preparedPass, bindingContext: context,
            sceneMipMapSlots: mipSlots) else { return context }
        let snapshot = try captureSceneMipmaps(sceneTexture, commandBuffer: commandBuffer)
        var textures = context.textureOverridesByName
        textures["_rt_MipMappedFrameBuffer"] = snapshot
        var slots = context.textureOverridesBySlot
        for slot in mipSlots { slots[slot] = snapshot }
        return MaterialBindingContext(viewportSize: context.viewportSize, textureOverridesBySlot: slots,
            textureOverridesByName: textures, uniformOverrides: context.uniformOverrides,
            depthAttachmentPixelFormat: context.depthAttachmentPixelFormat)
    }

    private func renderTexts(
        texts: [FrameText],
        packet: FramePacket,
        destinationScene: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let encoder = try sceneEncoder(for: destinationScene, commandBuffer: commandBuffer)

        try textRenderer.render(
            texts: texts,
            viewProjection: materialBinder.sceneViewProjection(
                scene: scene, viewportSize: CGSize(width: destinationScene.width, height: destinationScene.height),
                cameraZoom: packet.cameraZoom
            ),
            nodes: packet.nodes,
            encoder: encoder
        )
    }

    /// Runs a text node's rasterized texture through its authored effect
    /// chain (blur, shine, scroll, …) and composites the result as the text
    /// quad. Effect passes execute offscreen at the text texture's size.
    private func renderTextNodeWithEffects(
        text: FrameText,
        frameNode: FrameNode,
        nodeDescriptor: NodeDescriptor,
        packet: FramePacket,
        materialsByID: [String: FrameMaterial],
        currentScene: MTLTexture,
        destinationScene: MTLTexture,
        viewportSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) throws {
        // Effects may replace or expand alpha. Keep glyph coverage independent
        // of layer opacity, then apply that opacity once at final composition.
        guard let baseTexture = try textRenderer.rasterizedTexture(for: text, includeOpacity: false) else {
            return
        }

        let textureWidth = max(baseTexture.width, 1)
        let textureHeight = max(baseTexture.height, 1)
        guard let passGeometry = imageRenderer.makeOffscreenPassGeometry(device: device) else {
            throw NativeSceneRendererError.unsupportedScene("failed to build text effect geometry")
        }

        var namedTextures: [String: MTLTexture] = ["_rt_FullFrameBuffer": currentScene, "_rt_MipMappedFrameBuffer": currentScene]
        let effectTargets = try makeEffectTargets(frameNode: frameNode,
            size: CGSize(width: textureWidth, height: textureHeight),
            backbufferFormat: currentScene.pixelFormat, materialsByID: materialsByID, commandBuffer: commandBuffer)
        for index in effectTargets.keys.sorted() {
            namedTextures.merge(effectTargets[index]!.textures) { _, new in new }
        }

        var chainInput = baseTexture
        var scratch = try makeRenderTexture(width: textureWidth, height: textureHeight)
        var writtenTargets = Set<ObjectIdentifier>()
        for step in buildEffectSteps(frameNode: frameNode, materialsByID: materialsByID) {
            let ownedTargets = step.effectIndex.flatMap { effectTargets[$0] }
            if let ownedTargets {
                namedTextures.merge(ownedTargets.textures) { _, new in new }
            }
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
                    if ownedTargets?.textures[source] != nil { ownedTargets?.textures[source] = targetTexture }
                    if ownedTargets?.textures[target] != nil { ownedTargets?.textures[target] = sourceTexture }
                } else {
                    try copyTexture(from: sourceTexture, to: targetTexture, commandBuffer: commandBuffer)
                    writtenTargets.insert(ObjectIdentifier(targetTexture))
                }
                continue
            }

            guard let material = step.material, var pass = step.pass else {
                continue
            }

            let targetTexture: MTLTexture
            let loadAction: MTLLoadAction
            var advancesChain = false
            if let target = step.target, let explicitTarget = namedTextures[target] {
                targetTexture = explicitTarget
                loadAction = writtenTargets.contains(ObjectIdentifier(explicitTarget)) ? .load : .clear
                writtenTargets.insert(ObjectIdentifier(explicitTarget))
            } else {
                targetTexture = scratch
                loadAction = .clear
                advancesChain = true
                // Keep straight RGB/alpha while replacing an intermediate
                // texture. The final quad applies the text's alpha blending.
                pass = FrameMaterialPass(index: pass.index, shaderPath: pass.shaderPath,
                    blending: 1, culling: pass.culling, depthTest: pass.depthTest,
                    depthWrite: pass.depthWrite, textures: pass.textures,
                    userTextures: pass.userTextures, constants: pass.constants, combos: pass.combos)
            }

            var bindingContext = MaterialBindingContext(
                viewportSize: CGSize(width: targetTexture.width, height: targetTexture.height),
                textureOverridesBySlot: textureSlotOverrides(
                    binds: step.binds,
                    chainInputTexture: chainInput,
                    namedTextures: namedTextures,
                    currentScene: currentScene
                ),
                textureOverridesByName: namedTextures.merging(["_rt_FullFrameBuffer": currentScene]) { _, new in new },
                uniformOverrides: offscreenUniformOverrides(
                    targetSize: CGSize(width: targetTexture.width, height: targetTexture.height),
                    firstPass: false
                ).merging(["g_Color4": localRendererBytes(of: SIMD4<Float>(repeating: 1))]) { _, new in new }
            )

            let preparedPass = try materialBinder.preparePass(material: material, pass: pass,
                bindingContext: bindingContext, colorAttachmentPixelFormat: targetTexture.pixelFormat)
            bindingContext = try reflectionBindingContext(bindingContext, preparedPass: preparedPass,
                sceneTexture: currentScene, commandBuffer: commandBuffer, textureBinds: step.binds)
            endSharedSceneEncoder()
            let descriptor = renderPassDescriptor(for: targetTexture, loadAction: loadAction)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw NativeSceneRendererError.commandEncodingFailed
            }
            defer { encoder.endEncoding() }

            try lightingPass.prepare(packet: packet, encoder: encoder)
            try materialBinder.bind(
                preparedPass: preparedPass,
                frameNode: frameNode,
                nodeDescriptor: nodeDescriptor,
                scene: scene,
                packet: packet,
                positions: passGeometry.positions,
                texCoords: passGeometry.texCoords,
                vertexCount: passGeometry.vertexCount,
                encoder: encoder,
                bindingContext: bindingContext
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: passGeometry.vertexCount)

            if advancesChain {
                let processed = scratch
                if chainInput === baseTexture {
                    scratch = try makeRenderTexture(width: textureWidth, height: textureHeight)
                } else {
                    scratch = chainInput
                }
                chainInput = processed
            }
        }

        retainEffectTargets(effectTargets)

        let encoder = try sceneEncoder(for: destinationScene, commandBuffer: commandBuffer)
        try textRenderer.renderQuad(
            text: text,
            texture: chainInput,
            node: frameNode,
            viewProjection: materialBinder.sceneViewProjection(
                scene: scene, viewportSize: viewportSize, cameraZoom: packet.cameraZoom
            ),
            opacity: text.color.w,
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
