import Foundation
import NativeSceneCore
import simd

public final class SceneRuntime: @unchecked Sendable {
    public var scene: SceneDescription { sceneScriptRuntime.scene }
    public var sceneRevision: UInt64 { sceneScriptRuntime.sceneRevision }
    public var removedNodeIDs: Set<NodeID> { sceneScriptRuntime.removedThisFrame }

    public private(set) var frameIndex: UInt64 = 0
    public private(set) var elapsedTime: Double = 0
    public private(set) var isPaused = false
    public private(set) var parallaxDisplacement = RuntimeVector2.zero
    private var cameraShakeDisplacement = RuntimeVector2.zero
    private var particleStates: [NodeID: ParticleSystemState] = [:]
    private let sceneScriptRuntime: SceneScriptRuntime
    private let puppetModels: PuppetModelLibrary
    private let textLayouts: TextLayoutEngine
    private var textStyles: [NodeID: [String: UserSettingDescriptor]]
    private var materialSequence: Int = 0
    private var previousCursorPosition: RuntimeVector2?

    public init(scene: SceneDescription, storage: SceneScriptStorage? = nil, puppetModels: PuppetModelLibrary? = nil,
                textureAnimations: TextureAnimationLibrary? = nil, textLayouts: TextLayoutEngine? = nil,
                assetRoots: [URL]? = nil) {
        let roots = assetRoots ?? scene.extractedRoots
        self.textLayouts = textLayouts ?? TextLayoutEngine(assetRoots: roots)
        self.textStyles = Dictionary(uniqueKeysWithValues: scene.nodes.compactMap { node in
            node.text.map { (node.id, $0.resolvedStyleSettings(ownerID: "scene.node.\(node.id.rawValue)")) }
        })
        self.puppetModels = puppetModels ?? PuppetModelLibrary(assetRoots: roots)
        self.sceneScriptRuntime = SceneScriptRuntime(scene: scene, storage: storage, puppetModels: self.puppetModels,
            textureAnimations: textureAnimations ?? TextureAnimationLibrary(assetRoots: roots), textLayouts: self.textLayouts, assetRoots: roots)
    }

    public func updateMediaState(_ state: SceneMediaState) {
        sceneScriptRuntime.scriptHost.updateMediaState(state)
    }

    public func updateSoundPlaybackStatus(nodeID: NodeID, runID: UInt64, finished: Bool) {
        sceneScriptRuntime.scriptHost.updateSoundPlaybackStatus(nodeID: nodeID, runID: runID, finished: finished)
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    @discardableResult
    public func step(
        deltaTime: Double,
        propertyOverrides: [String: FrameValue] = [:],
        audioInput: AudioInputState = .silent,
        cursorPosition: RuntimeVector2? = nil,
        cursorLeftDown: Bool = false,
        cursorEvents: [CursorInputSample] = [],
        resetCursorEvents: Bool = false,
        viewportSize: RuntimeVector2? = nil
    ) -> FramePacket {
        let clampedDelta = max(0, deltaTime)
        if !isPaused {
            elapsedTime += clampedDelta
        }

        let context = PropertyEvaluationContext(
            elapsedTime: elapsedTime,
            deltaTime: isPaused ? 0 : clampedDelta,
            frameIndex: frameIndex,
            cursorPosition: cursorPosition,
            cursorLeftDown: cursorLeftDown,
            cursorEvents: cursorEvents,
            resetCursorEvents: resetCursorEvents,
            viewportSize: viewportSize,
            propertyOverrides: propertyOverrides,
            audio: audioInput,
            scriptHost: sceneScriptRuntime.scriptHost,
            isPaused: isPaused
        )
        defer { sceneScriptRuntime.endFrame() }
        sceneScriptRuntime.step(context: context)
        for id in sceneScriptRuntime.removedThisFrame {
            particleStates[id] = nil
            textStyles[id] = nil
        }
        let propertyEvaluator = PropertyEvaluator(
            scene: scene,
            context: PropertyEvaluationContext(
                elapsedTime: elapsedTime,
                deltaTime: isPaused ? 0 : clampedDelta,
                frameIndex: frameIndex,
                cursorPosition: cursorPosition,
                cursorLeftDown: cursorLeftDown,
                cursorEvents: cursorEvents,
                resetCursorEvents: resetCursorEvents,
                viewportSize: viewportSize,
                propertyOverrides: propertyOverrides,
                audio: audioInput,
                scriptHost: sceneScriptRuntime.scriptHost,
                isPaused: isPaused
            )
        )
        updateParallaxDisplacement(
            deltaTime: clampedDelta,
            propertyEvaluator: propertyEvaluator,
            cursorPosition: cursorPosition
        )
        updateCameraShakeDisplacement(propertyEvaluator: propertyEvaluator)
        let animationStates = Dictionary(uniqueKeysWithValues: scene.nodes.map { node in
            (node.id, AnimationEvaluator.evaluate(node: node, elapsedTime: elapsedTime, propertyEvaluator: propertyEvaluator))
        })
        let transformStates = TransformEvaluator.evaluate(
            scene: scene,
            propertyEvaluator: propertyEvaluator,
            parallaxDisplacement: parallaxDisplacement,
            cameraShakeDisplacement: cameraShakeDisplacement,
            attachmentTransforms: attachmentTransforms(animationStates: animationStates)
        )
        let parents = TransformEvaluator.resolvedParents(scene: scene, scriptHost: sceneScriptRuntime.scriptHost)
        let orderedNodes = TransformEvaluator.evaluationOrder(for: scene.nodes, parents: parents)

        var nodeVisibility: [NodeID: Bool] = [:]
        var nodeFrames: [FrameNode] = []
        var materials: [FrameMaterial] = []
        var lights: [FrameLight] = []
        var particleSystems: [FrameParticleSystem] = []
        var texts: [FrameText] = []

        for node in orderedNodes {
            let animationState = animationStates[node.id] ?? .empty
            let visible = resolveVisibility(
                for: node,
                propertyEvaluator: propertyEvaluator,
                parentVisibility: parents[node.id].flatMap { nodeVisibility[$0] } ?? true,
                animationState: animationState
            )
            nodeVisibility[node.id] = visible

            let transform = transformStates[node.id] ?? NodeTransformState(
                localTransform: .identity,
                worldTransform: .identity,
                origin: .zero,
                scale: .one,
                angles: .zero
            )

            let materialCollection = collectMaterials(
                for: node,
                propertyEvaluator: propertyEvaluator,
                into: &materials
            )

            if let light = buildLightFrame(
                node: node,
                visible: visible,
                transform: transform,
                propertyEvaluator: propertyEvaluator
            ) {
                lights.append(light)
            }

            if let particle = buildParticleFrame(
                node: node,
                visible: visible,
                transform: transform,
                materialReference: materialCollection.references.first,
                childMaterialReferences: materialCollection.particleChildReferences,
                propertyEvaluator: propertyEvaluator,
                deltaTime: isPaused ? 0 : clampedDelta,
                cursorPosition: cursorPosition
            ) {
                particleSystems.append(particle)
            }

            if let text = buildTextFrame(
                node: node,
                visible: visible,
                propertyEvaluator: propertyEvaluator
            ) {
                texts.append(text)
            }

            nodeFrames.append(
                FrameNode(
                    nodeID: node.id,
                    name: node.name,
                    kind: node.kind,
                    parentID: parents[node.id],
                    dependencyIDs: node.dependencyIds,
                    localTransform: transform.localTransform,
                    worldTransform: transform.worldTransform,
                    worldPosition: transform.worldTransform.translation,
                    visible: visible,
                    opacity: resolveOpacity(for: node, propertyEvaluator: propertyEvaluator),
                    renderItemReferences: materialCollection.references,
                    imageEffects: materialCollection.imageEffects,
                    animationLayers: animationState.layers,
                    color: node.image.map { propertyEvaluator.vector3Value(for: $0.color, default: RuntimeVector3(x: 1, y: 1, z: 1)) },
                    textureAnimationTime: sceneScriptRuntime.scriptHost.textureAnimationTime(nodeID: node.id),
                    videoTextureTime: sceneScriptRuntime.scriptHost.videoTextureTime(nodeID: node.id),
                    imageAlignment: sceneScriptRuntime.scriptHost.imageAlignment(for: node)
                )
            )
        }

        let cameraBloom = buildCameraBloom(propertyEvaluator: propertyEvaluator)

        // Nodes were evaluated in dependency order (parents first for
        // visibility/transform inheritance); the renderer paints
        // packet.nodes sequentially, so restore authored scene order.
        let sceneOrder = Dictionary(
            scene.nodes.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        nodeFrames.sort { (sceneOrder[$0.nodeID] ?? 0) < (sceneOrder[$1.nodeID] ?? 0) }

        let packet = FramePacket(
            metadata: scene.metadata,
            timing: RuntimeClock(
                frameIndex: frameIndex,
                deltaTime: clampedDelta,
                elapsedTime: elapsedTime,
                isPaused: isPaused
            ),
            cursor: cursorPosition.map {
                RuntimeCursorState(normalized: $0, parallaxDisplacement: parallaxDisplacement,
                    previousNormalized: previousCursorPosition ?? $0, leftDown: cursorLeftDown)
            },
            cameraBloom: cameraBloom,
            properties: propertyEvaluator.resolvedUserProperties(),
            nodes: nodeFrames,
            materials: materials,
            lights: lights,
            particleSystems: particleSystems,
            texts: texts,
            soundTransports: sceneScriptRuntime.scriptHost.soundTransportSnapshot(),
            audio: audioInput,
            cameraZoom: scene.scene?.camera.projection.isPerspective == true ? 1
                : Float(propertyEvaluator.scalarDouble(for: scene.scene?.camera.zoom, default: 1))
        )

        previousCursorPosition = cursorPosition
        frameIndex += 1
        return packet
    }

    /// Finish playback and release generated layers. The next step reinitializes authored scripts.
    public func shutdown(cursorPosition: RuntimeVector2? = nil) {
        sceneScriptRuntime.shutdown()
        particleStates.removeAll()
        textStyles.removeAll()
        previousCursorPosition = nil
    }

    private func attachmentTransforms(animationStates: [NodeID: AnimationState]) -> [NodeID: Matrix4x4f] {
        let nodes = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
        var boneTransforms: [NodeID: [simd_float4x4]] = [:]
        var transforms: [NodeID: Matrix4x4f] = [:]
        for node in scene.nodes {
            guard let reference = sceneScriptRuntime.scriptHost.attachment(for: node),
                  let parent = sceneScriptRuntime.scriptHost.parentID(for: node),
                  let descriptor = nodes[parent]?.image?.model,
                  let path = descriptor.puppet ?? (descriptor.filename.lowercased().hasSuffix(".mdl") ? descriptor.filename : nil),
                  let model = puppetModels.model(for: path) else { continue }
            let attachment: PuppetAttachment?
            switch reference {
            case .name(let name): attachment = model.attachments.first { $0.name == name }
            case .index(let index): attachment = model.attachments.indices.contains(index) ? model.attachments[index] : nil
            }
            guard let attachment else { continue }
            if boneTransforms[parent] == nil {
                let layers = animationStates[parent]?.layers ?? []
                let active = layers.first { $0.visible && $0.blend > 0 }
                boneTransforms[parent] = !layers.isEmpty && active == nil ? model.bindWorldTransforms
                    : model.boneTransforms(at: elapsedTime, animationID: active?.animation,
                                           rate: active?.rate ?? 1, blend: active?.blend ?? 1, frame: active?.sampleFrame)
            }
            let bones = boneTransforms[parent] ?? []
            let bone = bones.indices.contains(attachment.bone) ? bones[attachment.bone] : matrix_identity_float4x4
            transforms[node.id] = Matrix4x4f(bone * attachment.localTransform)
        }
        return transforms
    }

    private func updateParallaxDisplacement(
        deltaTime: Double,
        propertyEvaluator: PropertyEvaluator,
        cursorPosition: RuntimeVector2?
    ) {
        guard let camera = scene.scene?.camera,
              propertyEvaluator.boolValue(for: camera.parallax.enabled, default: false),
              let cursorPosition else {
            parallaxDisplacement = .zero
            return
        }

        let amount = Float(propertyEvaluator.scalarDouble(for: camera.parallax.amount, default: 1))
        let influence = Float(propertyEvaluator.scalarDouble(for: camera.parallax.mouseInfluence, default: 1))
        let centered = RuntimeVector2(
            x: (min(max(cursorPosition.x, 0), 1) - 0.5) * 2,
            y: (min(max(cursorPosition.y, 0), 1) - 0.5) * 2
        )
        let target = RuntimeVector2(
            x: centered.x * amount * influence,
            y: centered.y * amount * influence
        )

        let delay = max(propertyEvaluator.scalarDouble(for: camera.parallax.delay, default: 0), 0)
        let blend = delay > 0 ? Float(min(deltaTime / delay, 1)) : 1
        parallaxDisplacement = RuntimeVector2(
            x: parallaxDisplacement.x + (target.x - parallaxDisplacement.x) * blend,
            y: parallaxDisplacement.y + (target.y - parallaxDisplacement.y) * blend
        )
    }

    private func updateCameraShakeDisplacement(propertyEvaluator: PropertyEvaluator) {
        guard let camera = scene.scene?.camera,
              propertyEvaluator.boolValue(for: camera.shake.enabled, default: false) else {
            cameraShakeDisplacement = .zero
            return
        }
        let amplitude = Float(propertyEvaluator.scalarDouble(for: camera.shake.amplitude, default: 0.5))
        let speed = Float(propertyEvaluator.scalarDouble(for: camera.shake.speed, default: 3))
        let t = Float(elapsedTime) * speed
        // Two-frequency sinusoidal shake approximates Perlin noise
        let x = (sin(t * 1.1 + cos(t * 0.7)) + sin(t * 2.3) * 0.5) * amplitude * 0.5
        let y = (cos(t * 0.9 + sin(t * 1.3)) + cos(t * 1.7) * 0.5) * amplitude * 0.5
        cameraShakeDisplacement = RuntimeVector2(x: x, y: y)
    }

    private func resolveVisibility(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator,
        parentVisibility: Bool,
        animationState: AnimationState
    ) -> Bool {
        let ownVisibility: Bool
        switch node.kind {
        case .group:
            ownVisibility = propertyEvaluator.boolValue(for: node.group?.visible, default: true)
        case .image:
            ownVisibility = propertyEvaluator.boolValue(for: node.image?.visible, default: true)
        case .light:
            ownVisibility = propertyEvaluator.boolValue(for: node.light?.visible, default: true)
        case .particle:
            ownVisibility = propertyEvaluator.boolValue(for: node.particle?.visible, default: true)
        case .text:
            ownVisibility = propertyEvaluator.boolValue(for: node.text?.visible, default: true)
        default:
            ownVisibility = true
        }

        return parentVisibility && ownVisibility && animationState.keepsNodeVisible
    }

    private func resolveOpacity(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator
    ) -> Double? {
        if let image = node.image {
            return propertyEvaluator.scalarDouble(for: image.alpha, default: 1)
        }
        if let particle = node.particle {
            return propertyEvaluator.evaluate(particle.instanceOverride.alpha)?.value.doubleValue
        }
        if let text = node.text {
            return propertyEvaluator.scalarDouble(for: text.alpha, default: 1)
        }
        return nil
    }

    private func collectMaterials(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator,
        into materials: inout [FrameMaterial]
    ) -> (references: [String], imageEffects: [FrameImageEffect], particleChildReferences: [String: String]) {
        var references: [String] = []
        var imageEffects: [FrameImageEffect] = []
        var particleChildReferences: [String: String] = [:]

        if let material = node.image?.model?.material {
            let materialFrame = materialFrame(
                idPrefix: "node\(node.id.rawValue)",
                nodeID: node.id,
                material: material,
                propertyEvaluator: propertyEvaluator
            )
            materials.append(materialFrame)
            references.append(materialFrame.id)
        }
        for (index, material) in (node.image?.model?.meshMaterials ?? []).enumerated() where index > 0 {
            guard let material else { continue }
            let frame = materialFrame(idPrefix: "node\(node.id.rawValue):mesh\(index)", nodeID: node.id,
                                      material: material, propertyEvaluator: propertyEvaluator)
            materials.append(frame)
            references.append(frame.id)
        }

        if let image = node.image {
            imageEffects = buildImageEffects(
                for: node,
                effects: image.effects,
                propertyEvaluator: propertyEvaluator,
                materials: &materials
            )
        } else if let text = node.text {
            imageEffects = buildImageEffects(
                for: node,
                effects: text.effects,
                propertyEvaluator: propertyEvaluator,
                materials: &materials
            )
        }

        if let particleMaterial = node.particle?.material?.material {
            let materialFrame = materialFrame(
                idPrefix: "particle\(node.id.rawValue)",
                nodeID: node.id,
                material: particleMaterial,
                propertyEvaluator: propertyEvaluator
            )
            materials.append(materialFrame)
            references.append(materialFrame.id)
        }

        if let particle = node.particle {
            collectChildParticleMaterials(
                particle: particle,
                nodeID: node.id,
                childPath: "",
                propertyEvaluator: propertyEvaluator,
                into: &materials,
                references: &particleChildReferences
            )
        }

        return (references, imageEffects, particleChildReferences)
    }

    private func collectChildParticleMaterials(
        particle: ParticleDescriptor,
        nodeID: NodeID,
        childPath: String,
        propertyEvaluator: PropertyEvaluator,
        into materials: inout [FrameMaterial],
        references: inout [String: String]
    ) {
        for (index, child) in particle.children.enumerated() {
            guard let childParticle = child.particle.first else {
                continue
            }
            let path = childPath.isEmpty ? "\(index)" : "\(childPath)/\(index)"
            if let material = childParticle.material?.material {
                let materialFrame = materialFrame(
                    idPrefix: "particle\(nodeID.rawValue)-child\(path)",
                    nodeID: nodeID,
                    material: material,
                    propertyEvaluator: propertyEvaluator
                )
                materials.append(materialFrame)
                references[path] = materialFrame.id
            }
            collectChildParticleMaterials(
                particle: childParticle,
                nodeID: nodeID,
                childPath: path,
                propertyEvaluator: propertyEvaluator,
                into: &materials,
                references: &references
            )
        }
    }

    private func nextMaterialSequence() -> Int {
        materialSequence += 1
        return materialSequence
    }

    private func materialFrame(
        idPrefix: String,
        nodeID: NodeID,
        material: MaterialDescriptor,
        propertyEvaluator: PropertyEvaluator,
        overridePass: EffectOverridePassDescriptor? = nil
    ) -> FrameMaterial {
        let userProperties = !(overridePass?.userTextures.isEmpty ?? true)
            || material.passes.contains(where: { !$0.userTextures.isEmpty })
            ? propertyEvaluator.resolvedUserProperties() : [:]
        let passes: [FrameMaterialPass] = material.passes.enumerated().map { index, pass in
            // Scene effect overrides pair with effect passes by order (their
            // "id" field is a scene-object id, not a pass index).
            let appliesOverride = overridePass != nil
            let resolvedTextures = appliesOverride && !(overridePass?.textures.isEmpty ?? true)
                ? overridePass?.textures ?? []
                : pass.textures
            // Named bindings may select a user property or a host-owned system
            // texture. Empty user selections retain the authored asset slot.
            let namedOverrides = overridePass?.userTextures ?? []
            let overriddenSlots = Set(namedOverrides.map(\.slot))
            let namedTextures = pass.userTextures.filter { !overriddenSlots.contains($0.slot) } + namedOverrides
            let userTextures = namedTextures.sorted { $0.slot < $1.slot }.compactMap { texture -> FrameTextureBinding? in
                if texture.sourceType == "system" {
                    return FrameTextureBinding(slot: texture.slot, path: texture.path, sourceType: texture.sourceType,
                        fallbackPath: resolvedTextures.first { $0.slot == texture.slot }?.path)
                }
                // Shortcut properties identify applications, not image files.
                guard texture.sourceType != "usershortcut" else { return nil }
                guard case .string(let path) = userProperties[texture.path], !path.isEmpty else { return nil }
                return FrameTextureBinding(slot: texture.slot, path: path, sourceType: texture.sourceType)
            }
            let userTextureSlots = Set(userTextures.map(\.slot))
            let textures = resolvedTextures.filter { !userTextureSlots.contains($0.slot) }
                .map { FrameTextureBinding(slot: $0.slot, path: $0.path, sourceType: $0.sourceType) } + userTextures
            let resolvedConstants = pass.constants.mapValues { propertyEvaluator.evaluate($0)?.value ?? .null }
                .merging(
                    appliesOverride
                        ? (overridePass?.constants.mapValues { propertyEvaluator.evaluate($0)?.value ?? .null } ?? [:])
                        : [:],
                    uniquingKeysWith: { _, override in override }
                )
            return FrameMaterialPass(
                index: index,
                shaderPath: appliesOverride ? (overridePass?.shaderOverride ?? pass.shader.path) : pass.shader.path,
                blending: pass.blending,
                culling: pass.culling,
                depthTest: pass.depthTest,
                depthWrite: pass.depthWrite,
                textures: textures.sorted { $0.slot < $1.slot },
                userTextures: userTextures,
                constants: resolvedConstants,
                combos: pass.combos.merging(
                    appliesOverride ? (overridePass?.combos ?? [:]) : [:],
                    uniquingKeysWith: { _, override in override }
                )
            )
        }

        return FrameMaterial(
            id: "\(idPrefix):\(material.filename)#\(nextMaterialSequence())",
            sourceNodeID: nodeID,
            sourceFile: material.filename,
            passOrdering: passes.map(\.index),
            passes: passes
        )
    }

    private func buildImageEffects(
        for node: NodeDescriptor,
        effects: [ImageEffectDescriptor],
        propertyEvaluator: PropertyEvaluator,
        materials: inout [FrameMaterial]
    ) -> [FrameImageEffect] {
        var frames: [FrameImageEffect] = []

        for (effectIndex, imageEffect) in effects.enumerated() {
            guard propertyEvaluator.boolValue(for: imageEffect.visible, default: true),
                  let effect = imageEffect.effect else {
                continue
            }

            var overrideIndex = 0
            var framePasses: [FrameEffectPass] = []

            for (passIndex, effectPass) in effect.passes.enumerated() {
                if let material = effectPass.material {
                    let overridePass = imageEffect.passOverrides.indices.contains(overrideIndex)
                        ? imageEffect.passOverrides[overrideIndex]
                        : nil
                    let materialFrame = materialFrame(
                        idPrefix: "node\(node.id.rawValue)-effect\(effectIndex)-pass\(passIndex)",
                        nodeID: node.id,
                        material: material,
                        propertyEvaluator: propertyEvaluator,
                        overridePass: overridePass
                    )
                    materials.append(materialFrame)
                    framePasses.append(
                        FrameEffectPass(
                            materialReference: materialFrame.id,
                            binds: effectPass.binds.map { FrameTextureBinding(slot: $0.slot, path: $0.path) },
                            command: nil,
                            source: nil,
                            target: effectPass.target
                        )
                    )
                    if overridePass != nil {
                        overrideIndex += 1
                    }
                } else {
                    framePasses.append(
                        FrameEffectPass(
                            materialReference: nil,
                            binds: effectPass.binds.map { FrameTextureBinding(slot: $0.slot, path: $0.path) },
                            command: effectPass.command,
                            source: effectPass.source,
                            target: effectPass.target
                        )
                    )
                }
            }

            frames.append(
                FrameImageEffect(
                    id: imageEffect.id,
                    sourceIndex: effectIndex,
                    renderTargets: effect.fbos.map {
                        FrameRenderTargetDescriptor(
                            name: $0.name,
                            scale: $0.scale,
                            unique: $0.unique,
                            format: $0.format
                        )
                    },
                    passes: framePasses
                )
            )
        }

        return frames
    }

    private func buildCameraBloom(propertyEvaluator: PropertyEvaluator) -> FrameCameraBloom? {
        guard let camera = scene.scene?.camera else {
            return nil
        }

        let enabled = propertyEvaluator.boolValue(for: camera.bloom.enabled, default: false)
        guard enabled else {
            return nil
        }

        return FrameCameraBloom(
            enabled: enabled,
            strength: propertyEvaluator.scalarDouble(for: camera.bloom.strength, default: 0),
            threshold: propertyEvaluator.scalarDouble(for: camera.bloom.threshold, default: 0)
        )
    }

    private func buildLightFrame(
        node: NodeDescriptor,
        visible: Bool,
        transform: NodeTransformState,
        propertyEvaluator: PropertyEvaluator
    ) -> FrameLight? {
        guard let light = node.light else {
            return nil
        }

        return FrameLight(
            nodeID: node.id,
            type: light.lightType,
            visible: visible,
            position: transform.worldTransform.translation,
            angles: propertyEvaluator.vector3Value(for: light.angles, default: .zero),
            color: propertyEvaluator.vector3Value(for: light.color, default: RuntimeVector3(x: 1, y: 1, z: 1)),
            intensity: propertyEvaluator.scalarDouble(for: light.intensity, default: 1),
            radius: propertyEvaluator.scalarDouble(for: light.radius, default: 0),
            length: propertyEvaluator.scalarDouble(for: light.length, default: 0),
            innerCone: propertyEvaluator.scalarDouble(for: light.innerCone, default: 0),
            outerCone: propertyEvaluator.scalarDouble(for: light.outerCone, default: 0),
            castsShadow: light.castsShadow,
            endPosition: light.controlPoint.map { setting in
                let local = propertyEvaluator.vector3Value(for: setting, default: .zero)
                let world = transform.worldTransform.simdValue * SIMD4(local.x, local.y, local.z, 1)
                return RuntimeVector3(x: world.x, y: world.y, z: world.z)
            },
            exponent: propertyEvaluator.scalarDouble(for: light.exponent, default: 2)
        )
    }

    private func buildParticleFrame(
        node: NodeDescriptor,
        visible: Bool,
        transform: NodeTransformState,
        materialReference: String?,
        childMaterialReferences: [String: String],
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Double,
        cursorPosition: RuntimeVector2?
    ) -> FrameParticleSystem? {
        guard let particle = node.particle else {
            return nil
        }

        guard particleDescriptorIsSupported(particle) else {
            particleStates[node.id] = nil
            sceneScriptRuntime.scriptHost.updateParticlePlaybackStatus(nodeID: node.id, hasLiveParticles: false, hasPendingEmission: false)
            return nil
        }

        let rendererName = particle.renderers.first?.name.lowercased() ?? "sprite"
        let emitDelay = Double(particle.startTime) / 1000.0
        let overrides = resolvedParticleOverrides(for: particle, propertyEvaluator: propertyEvaluator)
        let simulationDelta = deltaTime * Double(overrides.rate)
        let maxParticleCount = resolvedParticleCount(for: particle, overrides: overrides)
        let transport = sceneScriptRuntime.scriptHost.particleTransportSnapshot(nodeID: node.id)
        let transportEmissionEnabled = transport?.mode != .paused && transport?.mode != .stopped
        var state = particleStates[node.id] ?? ParticleSystemState(nodeID: node.id, emitters: particle.emitters)
        if let transport, state.transportResetID != transport.resetID {
            // Includes stop then play within one callback and replay of an exhausted run.
            state = ParticleSystemState(nodeID: node.id, emitters: particle.emitters)
            state.transportResetID = transport.resetID
        }
        if transportEmissionEnabled { state.emissionTime += deltaTime }
        let emissionEnabled = transportEmissionEnabled && visible && state.emissionTime >= emitDelay && maxParticleCount > 0
        state.simulationTime += simulationDelta
        state.emitters = syncedEmitterStates(current: state.emitters, descriptors: particle.emitters)
        state.particles.removeAll { !$0.isAlive }
        state.spawnedThisFrame.removeAll(keepingCapacity: true)
        state.diedThisFrame.removeAll(keepingCapacity: true)

        let controlPoints = resolvedParticleControlPoints(
            for: particle,
            cursorPosition: cursorPosition,
            worldTransform: transform.worldTransform.simdValue,
            instanceID: "scene.node.\(node.id.rawValue).instanceoverride",
            propertyEvaluator: propertyEvaluator
        )

        if emissionEnabled, simulationDelta > 0 {
            updateParticleSystem(
                particle: particle,
                state: &state,
                overrides: overrides,
                maxParticleCount: maxParticleCount,
                controlPoints: controlPoints,
                propertyEvaluator: propertyEvaluator,
                deltaTime: Float(simulationDelta)
            )
        } else if simulationDelta > 0, !state.particles.isEmpty {
            advanceParticleState(
                state: &state,
                particle: particle,
                overrides: overrides,
                propertyEvaluator: propertyEvaluator,
                controlPoints: controlPoints,
                deltaTime: Float(simulationDelta)
            )
        }

        let childSystems = updateChildSystems(
            particle: particle,
            state: &state,
            parentSeed: UInt64(truncatingIfNeeded: node.id.rawValue),
            emissionEnabled: emissionEnabled,
            transportEmissionEnabled: transportEmissionEnabled,
            controlPoints: controlPoints,
            childMaterialReferences: childMaterialReferences,
            childPath: "",
            nodeID: node.id,
            propertyEvaluator: propertyEvaluator,
            cursorPosition: cursorPosition,
            worldTransform: transform.worldTransform.simdValue,
            deltaTime: Float(simulationDelta),
            depth: 0
        )

        particleStates[node.id] = state
        sceneScriptRuntime.scriptHost.updateParticlePlaybackStatus(nodeID: node.id,
            hasLiveParticles: state.hasLiveParticles, hasPendingEmission: state.hasPendingEmission(for: particle))
        let liveEstimate = UInt32(min(state.particles.count, Int(UInt32.max)))
        let instances = state.particles.map { particleInstanceFrame(from: $0) }
        let rendererDescriptor = particle.renderers.first

        return FrameParticleSystem(
            nodeID: node.id,
            visible: visible,
            materialReference: materialReference,
            rendererName: rendererName,
            maxParticleCount: maxParticleCount,
            liveParticleEstimate: liveEstimate,
            emissionEnabled: emissionEnabled,
            sequenceMultiplier: particle.sequenceMultiplier,
            startTime: particle.startTime,
            instances: instances,
            rendererParameters: rendererDescriptor.map {
                FrameParticleRendererParameters(
                    length: $0.length,
                    maxLength: $0.maxLength,
                    minLength: $0.minLength,
                    subdivision: $0.subdivision
                )
            },
            childSystems: childSystems,
            animationMode: particle.animationMode
        )
    }

    private func buildTextFrame(
        node: NodeDescriptor,
        visible: Bool,
        propertyEvaluator: PropertyEvaluator
    ) -> FrameText? {
        guard let text = node.text else {
            return nil
        }

        let content = propertyEvaluator.evaluate(text.content)?.value.stringValue
            .replacingOccurrences(of: "\0", with: "")
            ?? ""
        let color = propertyEvaluator.vector4Value(
            for: text.color,
            default: RuntimeVector4(x: 1, y: 1, z: 1, w: 1)
        )
        let opacity = Float(propertyEvaluator.scalarDouble(for: text.alpha, default: 1))
        let backgroundColor = propertyEvaluator.vector4Value(
            for: text.backgroundColor,
            default: RuntimeVector4(x: 0, y: 0, z: 0, w: 0)
        )

        if textStyles[node.id] == nil {
            textStyles[node.id] = text.resolvedStyleSettings(ownerID: "scene.node.\(node.id.rawValue)")
        }
        let styles = textStyles[node.id] ?? [:]
        func string(_ key: String, _ fallback: String) -> String {
            propertyEvaluator.evaluate(styles[key])?.value.stringValue ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int {
            let value = propertyEvaluator.scalarDouble(for: styles[key], default: Double(fallback))
            guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return fallback }
            return Int(value)
        }
        var frame = FrameText(
            nodeID: node.id,
            visible: visible,
            content: content,
            fontPath: string("font", text.fontPath),
            pointSize: propertyEvaluator.scalarDouble(for: text.pointSize, default: 16),
            size: .zero,
            maxWidth: propertyEvaluator.scalarDouble(for: styles["maxwidth"], default: text.maxWidth),
            maxRows: integer("maxrows", text.maxRows),
            padding: integer("padding", text.padding),
            color: RuntimeVector4(x: color.x, y: color.y, z: color.z, w: color.w * opacity),
            horizontalAlign: string("horizontalalign", text.horizontalAlign),
            verticalAlign: string("verticalalign", text.verticalAlign),
            limitWidth: propertyEvaluator.boolValue(for: styles["limitwidth"], default: text.limitWidth),
            limitRows: propertyEvaluator.boolValue(for: styles["limitrows"], default: text.limitRows),
            limitUseEllipsis: propertyEvaluator.boolValue(for: styles["limituseellipsis"], default: text.limitUseEllipsis),
            blockAlign: propertyEvaluator.boolValue(for: styles["blockalign"], default: text.blockAlign),
            castShadow: propertyEvaluator.boolValue(for: styles["castshadow"], default: text.castShadow),
            opaqueBackground: propertyEvaluator.boolValue(for: styles["opaquebackground"], default: text.opaqueBackground),
            backgroundColor: backgroundColor
        )
        do {
            if let layout = try textLayouts.layout(for: frame) {
                frame.size = RuntimeVector2(x: Float(layout.width), y: Float(layout.height))
            }
        } catch {
            sceneScriptRuntime.scriptHost.reportFailure(error, instanceID: "scene.node.\(node.id.rawValue).text-layout")
        }
        return frame
    }
}

private extension SceneRuntime {
    func particleDescriptorIsSupported(_ particle: ParticleDescriptor) -> Bool {
        ParticleFeatureCatalog.isSupported(particle)
    }

    func resolvedParticleOverrides(
        for particle: ParticleDescriptor,
        propertyEvaluator: PropertyEvaluator
    ) -> ParticleResolvedInstanceOverrides {
        let overrideColor = normalizedColor(
            propertyEvaluator.vector4Value(
                for: particle.instanceOverride.color,
                default: RuntimeVector4(x: 1, y: 1, z: 1, w: 1)
            )
        )
        let colorN = normalizedColor3(
            propertyEvaluator.vector3Value(
                for: particle.instanceOverride.colorn,
                default: RuntimeVector3(x: 1, y: 1, z: 1)
            )
        )

        return ParticleResolvedInstanceOverrides(
            alpha: max(Float(propertyEvaluator.scalarDouble(for: particle.instanceOverride.alpha, default: 1)), 0),
            size: max(Float(propertyEvaluator.scalarDouble(for: particle.instanceOverride.size, default: 1)), 0.0001),
            lifetime: max(Float(propertyEvaluator.scalarDouble(for: particle.instanceOverride.lifetime, default: 1)), 0.0001),
            rate: max(Float(propertyEvaluator.scalarDouble(for: particle.instanceOverride.rate, default: 1)), 0),
            speed: max(Float(propertyEvaluator.scalarDouble(for: particle.instanceOverride.speed, default: 1)), 0),
            count: max(Float(propertyEvaluator.scalarDouble(for: particle.instanceOverride.count, default: 1)), 0),
            color: overrideColor,
            colorN: colorN
        )
    }

    func resolvedParticleCount(
        for particle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides
    ) -> UInt32 {
        // Zero density stops emission. It must not re-enable the default pool.
        // Round positive capacities up so fractional density still accumulates
        // enough emission time to create a particle.
        let base = particle.maxCount > 0 ? particle.maxCount : 256
        let scaled = (Double(base) * Double(overrides.count)).rounded(.up)
        return UInt32(min(max(scaled, 0), Double(UInt32.max)))
    }

    func syncedEmitterStates(
        current: [ParticleEmitterState],
        descriptors: [ParticleEmitterDescriptor]
    ) -> [ParticleEmitterState] {
        descriptors.enumerated().map { index, descriptor in
            if current.indices.contains(index) {
                return current[index]
            }
            return ParticleEmitterState(descriptor: descriptor)
        }
    }

    func resolvedParticleControlPoints(
        for particle: ParticleDescriptor,
        cursorPosition: RuntimeVector2?,
        worldTransform: simd_float4x4,
        instanceID: String,
        propertyEvaluator: PropertyEvaluator
    ) -> [Int: SIMD3<Float>] {
        let determinant = simd_determinant(worldTransform)
        let inverse = determinant.isFinite && determinant != 0 ? simd_inverse(worldTransform) : nil
        func localPosition(_ point: SIMD3<Float>) -> SIMD3<Float> {
            if let inverse {
                let result = inverse * SIMD4(point, 1)
                if result.x.isFinite && result.y.isFinite && result.z.isFinite {
                    return SIMD3(result.x, result.y, result.z)
                }
            }
            // A collapsed layer has no invertible coordinate system. Keep its
            // simulation finite until a script restores a drawable scale.
            let origin = worldTransform.columns.3
            return point - SIMD3(origin.x, origin.y, origin.z)
        }
        return Dictionary(particle.instanceControlPoints.map { controlPoint in
            // Control point zero is the system origin, irrespective of its
            // editor flags, offset, pointer link or scripted value.
            if controlPoint.id == 0 { return (0, SIMD3<Float>.zero) }
            let setting = controlPoint.offsetProperty(runtimeKey: "\(instanceID).controlpoint\(controlPoint.id)")
            let offset = propertyEvaluator.vector3Value(for: setting, default: .zero).simdValue
            // Flag bit 0 links the control point to the pointer position.
            let linkMouse = controlPoint.lockToPointer || (controlPoint.flags & 1) != 0
            if linkMouse, let cursorPosition {
                let world = propertyEvaluator.cursorWorldPosition(cursorPosition) ?? RuntimeVector2(
                    x: cursorPosition.x * propertyEvaluator.canvasSize.x,
                    y: cursorPosition.y * propertyEvaluator.canvasSize.y)
                let pointer = SIMD3<Float>(world.x, world.y, 0)
                return (controlPoint.id, localPosition(pointer + offset))
            }
            return (controlPoint.id, (controlPoint.flags & 2) != 0 ? localPosition(offset) : offset)
        }, uniquingKeysWith: { first, _ in first })
    }

    func updateParticleSystem(
        particle: ParticleDescriptor,
        state: inout ParticleSystemState,
        overrides: ParticleResolvedInstanceOverrides,
        maxParticleCount: UInt32,
        controlPoints: [Int: SIMD3<Float>],
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Float
    ) {
        for (index, emitter) in particle.emitters.enumerated() where state.emitters.indices.contains(index) {
            emitParticles(
                particle: particle,
                emitter: emitter,
                emitterState: &state.emitters[index],
                overrides: overrides,
                maxParticleCount: maxParticleCount,
                controlPoints: controlPoints,
                propertyEvaluator: propertyEvaluator,
                deltaTime: deltaTime,
                systemTime: Float(state.simulationTime),
                rng: &state.rng,
                particles: &state.particles,
                spawned: &state.spawnedThisFrame,
                sequenceCounter: &state.sequenceCounter
            )
        }

        advanceParticleState(
            state: &state,
            particle: particle,
            overrides: overrides,
            propertyEvaluator: propertyEvaluator,
            controlPoints: controlPoints,
            deltaTime: deltaTime
        )
    }

    func advanceParticleState(
        state: inout ParticleSystemState,
        particle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        propertyEvaluator: PropertyEvaluator,
        controlPoints: [Int: SIMD3<Float>],
        deltaTime: Float
    ) {
        guard deltaTime > 0 else {
            return
        }

        for index in state.particles.indices {
            state.particles[index].previousPosition = state.particles[index].position
            state.particles[index].age += deltaTime
            // Visual operators compose from the initialized appearance each
            // step. Multiplicative remaps must not shrink size/alpha forever
            // at a rate that depends on the renderer's frame rate.
            state.particles[index].size = state.particles[index].initial.size
            state.particles[index].color = state.particles[index].initial.color
        }

        applyParticleOperators(
            particle: particle,
            overrides: overrides,
            propertyEvaluator: propertyEvaluator,
            deltaTime: deltaTime,
            currentTime: Float(state.simulationTime),
            controlPoints: controlPoints,
            operatorRandoms: &state.operatorRandoms,
            rng: &state.rng,
            particles: &state.particles
        )

        if let renderer = particle.renderers.first, renderer.name.lowercased() == "ropetrail" {
            // Each particle trails its own history: `segments` samples spread
            // over `length` seconds.
            let segments = max(Int(renderer.segments), 2)
            let interval = Float(max(renderer.length, 0.001)) / Float(segments)
            for index in state.particles.indices {
                state.particles[index].trailTimer += deltaTime
                guard state.particles[index].trailTimer >= interval else { continue }
                state.particles[index].trailTimer = state.particles[index].trailTimer.truncatingRemainder(dividingBy: interval)
                state.particles[index].trail.append(state.particles[index].previousPosition ?? state.particles[index].position)
                if state.particles[index].trail.count > segments {
                    state.particles[index].trail.removeFirst(state.particles[index].trail.count - segments)
                }
            }
        }

        for particleState in state.particles where !particleState.isAlive {
            state.diedThisFrame.append(particleState.position)
        }
        // Order-preserving removal keeps rope/trail chains in spawn order.
        state.particles.removeAll { !$0.isAlive }
    }

    func emitParticles(
        particle: ParticleDescriptor,
        emitter: ParticleEmitterDescriptor,
        emitterState: inout ParticleEmitterState,
        overrides: ParticleResolvedInstanceOverrides,
        maxParticleCount: UInt32,
        controlPoints: [Int: SIMD3<Float>],
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Float,
        systemTime: Float,
        rng: inout ParticleRandomGenerator,
        particles: inout [ParticleInstanceState],
        spawned: inout [SIMD3<Float>],
        sequenceCounter: inout Int,
        originOffset: SIMD3<Float> = .zero
    ) {
        guard particles.count < Int(maxParticleCount), deltaTime > 0 else {
            return
        }

        if emitterState.delayTimer > 0 {
            emitterState.delayTimer -= Double(deltaTime)
            return
        }

        if emitter.duration > 0 {
            emitterState.durationTimer += Double(deltaTime)
            if emitterState.durationTimer >= emitter.duration {
                return
            }
        }

        if (emitter.flags & 4) != 0 {
            emitterState.periodicTimer += Double(deltaTime)
            if !emitterState.emitting {
                if emitterState.periodicTimer >= emitterState.periodicDelay {
                    emitterState.emitting = true
                    emitterState.periodicTimer = 0
                    emitterState.periodicDuration = Double(
                        rng.nextFloat(min: Float(emitter.minPeriodicDuration), max: Float(emitter.maxPeriodicDuration))
                    )
                } else {
                    return
                }
            } else if emitterState.periodicTimer >= emitterState.periodicDuration {
                emitterState.emitting = false
                emitterState.periodicTimer = 0
                emitterState.periodicDelay = Double(
                    rng.nextFloat(min: Float(emitter.minPeriodicDelay), max: Float(emitter.maxPeriodicDelay))
                )
                return
            }
        }

        var toEmit = 0
        if emitter.instantaneous > 0, !emitterState.instantaneousEmitted {
            toEmit += Int(min(Double(emitter.instantaneous) * Double(overrides.count), Double(maxParticleCount)))
            emitterState.instantaneousEmitted = true
        }

        if emitter.rate > 0 {
            // deltaTime already includes the simulation rate. Density scales
            // emission independently, rather than only resizing the pool.
            emitterState.emissionTimer += Double(deltaTime) * emitter.rate * Double(overrides.count)
            var rateEmit = Int(min(emitterState.emissionTimer.rounded(.down), Double(maxParticleCount)))
            emitterState.emissionTimer.formTruncatingRemainder(dividingBy: 1)
            if (emitter.flags & 2) != 0 {
                rateEmit = min(rateEmit, 1)
            }
            toEmit += rateEmit
        }

        guard toEmit > 0 else {
            return
        }

        let limit = Int(maxParticleCount)
        toEmit = min(toEmit, max(limit - particles.count, 0))
        for _ in 0..<toEmit {
            let instance = spawnParticle(
                particle: particle,
                emitter: emitter,
                overrides: overrides,
                controlPoints: controlPoints,
                propertyEvaluator: propertyEvaluator,
                rng: &rng,
                sequenceCounter: &sequenceCounter,
                systemTime: systemTime,
                originOffset: originOffset
            )
            particles.append(instance)
            spawned.append(instance.position)
        }
    }

    func spawnParticle(
        particle: ParticleDescriptor,
        emitter: ParticleEmitterDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        controlPoints: [Int: SIMD3<Float>],
        propertyEvaluator: PropertyEvaluator,
        rng: inout ParticleRandomGenerator,
        sequenceCounter: inout Int,
        systemTime: Float,
        originOffset: SIMD3<Float> = .zero
    ) -> ParticleInstanceState {
        let controlPointOrigin = controlPoints[emitter.controlPoint] ?? .zero
        let emitterOrigin = SIMD3<Float>(
            Float(emitter.origin[safe: 0] ?? 0),
            Float(emitter.origin[safe: 1] ?? 0),
            Float(emitter.origin[safe: 2] ?? 0)
        ) + controlPointOrigin + originOffset

        var position = emitterOrigin
        let directions = SIMD3<Float>(
            Float(emitter.directions[safe: 0] ?? 1),
            Float(emitter.directions[safe: 1] ?? 1),
            Float(emitter.directions[safe: 2] ?? 1)
        )

        switch emitter.name.lowercased() {
        case "boxrandom":
            var offset = SIMD3<Float>(repeating: 0)
            for axis in 0..<3 {
                let minDist = Float(emitter.distanceMin[safe: axis] ?? 0)
                let maxDist = Float(emitter.distanceMax[safe: axis] ?? Double(minDist))
                var value = rng.nextFloat(min: minDist, max: maxDist)
                if rng.nextBool() {
                    value *= -1
                }
                let sign = emitter.sign[safe: axis] ?? 0
                if sign > 0 {
                    value = abs(value)
                } else if sign < 0 {
                    value = -abs(value)
                }
                offset[axis] = value * directions[axis]
            }
            position += offset
        default:
            let radialOffset: SIMD3<Float>
            if (particle.flags & 4) == 0 {
                let angle = rng.nextFloat(min: 0, max: Float.pi * 2)
                let minRadius = Float(emitter.distanceMin[safe: 0] ?? 0)
                let maxRadius = Float(emitter.distanceMax[safe: 0] ?? Double(minRadius))
                let radius = sqrt(rng.nextFloat(min: minRadius * minRadius, max: maxRadius * maxRadius))
                radialOffset = SIMD3<Float>(
                    radius * cos(angle) * directions.x,
                    radius * sin(angle) * directions.y,
                    rng.nextFloat(min: -maxRadius, max: maxRadius) * directions.z
                )
            } else {
                let theta = rng.nextFloat(min: 0, max: Float.pi * 2)
                let cosTheta = rng.nextFloat(min: -1, max: 1)
                let sinTheta = sqrt(Swift.max(1 - cosTheta * cosTheta, 0))
                let minRadius = Float(emitter.distanceMin[safe: 0] ?? 0)
                let maxRadius = Float(emitter.distanceMax[safe: 0] ?? Double(minRadius))
                let radius = pow(rng.nextFloat(min: pow(minRadius, 3), max: pow(maxRadius, 3)), 1.0 / 3.0)
                radialOffset = SIMD3<Float>(
                    sinTheta * cos(theta) * radius * directions.x,
                    sinTheta * sin(theta) * radius * directions.y,
                    cosTheta * radius * directions.z
                )
            }
            var signedOffset = radialOffset
            for axis in 0..<3 {
                let sign = emitter.sign[safe: axis] ?? 0
                if sign > 0 { signedOffset[axis] = abs(signedOffset[axis]) }
                if sign < 0 { signedOffset[axis] = -abs(signedOffset[axis]) }
            }
            position += signedOffset
        }

        var velocity = SIMD3<Float>(repeating: 0)
        if emitter.speedMin != 0 || emitter.speedMax != 0 {
            let direction = simd_length(position - emitterOrigin) > 0.0001
                ? simd_normalize(position - emitterOrigin)
                : SIMD3<Float>(0, 1, 0)
            let speed = rng.nextFloat(min: Float(emitter.speedMin), max: Float(emitter.speedMax))
            velocity = direction * speed
        }

        var instance = ParticleInstanceState(
            position: position,
            velocity: velocity,
            rotation: .zero,
            angularVelocity: .zero,
            color: SIMD4<Float>(overrides.colorN.x, overrides.colorN.y, overrides.colorN.z, overrides.alpha),
            size: 20 * overrides.size,
            lifetime: overrides.lifetime,
            age: 0,
            initial: ParticleInitialState(
                color: SIMD4<Float>(overrides.colorN.x, overrides.colorN.y, overrides.colorN.z, overrides.alpha),
                size: 20 * overrides.size,
                lifetime: overrides.lifetime
            )
        )

        applyParticleInitializers(
            particle: particle,
            overrides: overrides,
            controlPoints: controlPoints,
            propertyEvaluator: propertyEvaluator,
            rng: &rng,
            sequenceCounter: &sequenceCounter,
            systemTime: systemTime,
            instance: &instance
        )
        instance.initial = ParticleInitialState(color: instance.color, size: instance.size, lifetime: instance.lifetime)
        if particle.animationMode.lowercased() == "randomframe" {
            instance.animationRandom = rng.nextFloat(min: 0, max: 1)
        }
        return instance
    }

    func applyParticleInitializers(
        particle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        controlPoints: [Int: SIMD3<Float>],
        propertyEvaluator: PropertyEvaluator,
        rng: inout ParticleRandomGenerator,
        sequenceCounter: inout Int,
        systemTime: Float,
        instance: inout ParticleInstanceState
    ) {
        for initializer in particle.initializers {
            switch initializer.kind.lowercased() {
            case "remapinitialvalue":
                let parameters = ParticleOperatorParameters(values: initializer.parameters, evaluator: propertyEvaluator)
                let flags = Int(parameters.scalar("flags", default: 3))
                let settings = ParticleRemap.Settings.read(parameters, flags: flags)
                let timeOfDay = settings.input == "timeofday" ? ParticleRemap.currentTimeOfDay() : 0
                ParticleRemap.apply(to: &instance, settings: settings,
                                    systemTime: systemTime, timeOfDay: timeOfDay,
                                    controlPoints: controlPoints, initial: true)
            case "lifetimerandom":
                let minValue = Swift.max(parameterScalar("min", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 1), 0.0001)
                let maxValue = Swift.max(parameterScalar("max", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: minValue), minValue)
                instance.lifetime = rng.nextFloat(min: minValue, max: maxValue) * overrides.lifetime
            case "sizerandom":
                let minValue = parameterScalar("min", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let maxValue = parameterScalar("max", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: minValue)
                let exponent = Swift.max(parameterScalar("exponent", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 1), 0.0001)
                let t = pow(rng.nextUnitFloat(), exponent)
                instance.size = (minValue + t * (maxValue - minValue)) * overrides.size / 2
            case "velocityrandom":
                let minValue = parameterVector3("min", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                let maxValue = parameterVector3("max", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: minValue.x, y: minValue.y, z: minValue.z))
                let randomVelocity = randomVector(min: minValue, max: maxValue, rng: &rng) * overrides.speed
                instance.velocity += randomVelocity
            case "colorrandom":
                let minValue = propertyEvaluator.vector3Value(for: initializer.parameters["min"], default: RuntimeVector3(x: 1, y: 1, z: 1))
                let maxValue = propertyEvaluator.vector3Value(for: initializer.parameters["max"], default: RuntimeVector3(x: 1, y: 1, z: 1))
                let min = normalizedColor3(minValue)
                let max = normalizedColor3(maxValue)
                let color = randomVector(min: min, max: max, rng: &rng)
                instance.color = SIMD4<Float>(color.x * overrides.color.x, color.y * overrides.color.y, color.z * overrides.color.z, instance.color.w)
            case "rotationrandom":
                let minValue = parameterVector3("min", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                let maxValue = parameterVector3("max", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: minValue.x, y: minValue.y, z: minValue.z))
                instance.rotation = randomVector(min: minValue, max: maxValue, rng: &rng)
            case "angularvelocityrandom":
                let minValue = parameterVector3("min", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                let maxValue = parameterVector3("max", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: minValue.x, y: minValue.y, z: minValue.z))
                let exponent = Swift.max(parameterScalar("exponent", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 1), 0.0001)
                instance.angularVelocity = randomVector(min: minValue, max: maxValue, exponent: exponent, rng: &rng) * overrides.speed
            case "alpharandom":
                let minValue = parameterScalar("min", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let maxValue = parameterScalar("max", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: minValue)
                instance.color.w = rng.nextFloat(min: minValue, max: maxValue) * overrides.alpha
            case "turbulentvelocityrandom":
                let speedMin = parameterScalar("speedmin", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let speedMax = parameterScalar("speedmax", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: speedMin)
                let offset = parameterScalar("offset", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let scale = parameterScalar("scale", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let timeScale = parameterScalar("timescale", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMin = parameterScalar("phasemin", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phasemax", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
                var forward = parameterVector3("forward", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: 0, y: 1, z: 0))
                var right = parameterVector3("right", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: 1, y: 0, z: 0))
                forward = simd_length(forward) > 0.0001 ? simd_normalize(forward) : SIMD3<Float>(0, 1, 0)
                right = simd_length(right) > 0.0001 ? simd_normalize(right) : SIMD3<Float>(1, 0, 0)

                let speed = rng.nextFloat(min: speedMin, max: speedMax)
                var noisePos = instance.position * 0.1
                noisePos += SIMD3<Float>(repeating: Float(elapsedTime) * timeScale)
                let phase = rng.nextFloat(min: phaseMin, max: phaseMax)
                let samplePos = noisePos + SIMD3<Float>(phase, phase * 0.7, phase * 1.3)

                var direction = ParticleNoise.curl(samplePos)
                let directionLength = simd_length(direction)
                direction = directionLength < 0.0001 ? forward : direction / directionLength

                // Scale limits deviation from the forward direction.
                if scale < 2 {
                    let cosAngle = simd_clamp(simd_dot(direction, forward), -1, 1)
                    let angle = acos(cosAngle) / Float.pi
                    let maxAngle = scale / 2
                    if angle > maxAngle, maxAngle > 0.0001 {
                        var axis = simd_cross(direction, forward)
                        let axisLength = simd_length(axis)
                        if axisLength > 0.0001 {
                            axis /= axisLength
                            let rotation = simd_quatf(angle: (angle - maxAngle) * Float.pi, axis: axis)
                            direction = rotation.act(direction)
                        }
                    }
                }

                // Offset tilts the result around the right axis.
                if abs(offset) > 0.0001 {
                    let rotation = simd_quatf(angle: -offset, axis: right)
                    direction = rotation.act(direction)
                }

                // 2D particles project onto the XY plane so trails stay connected.
                if (particle.flags & 4) == 0 {
                    direction.z = 0
                    let planarLength = simd_length(direction)
                    if planarLength > 0.0001 {
                        direction /= planarLength
                    }
                }

                instance.velocity += direction * speed * overrides.speed
            case "mapsequencearoundcontrolpoint":
                let controlPointIndex = Int(parameterScalar("controlpoint", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 0))
                let count = Swift.max(Int(parameterScalar("count", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: 1)), 1)
                let speedMin = parameterVector3("speedmin", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                let speedMax = parameterVector3("speedmax", from: initializer.parameters, propertyEvaluator: propertyEvaluator, default: .zero)

                let angle = (Float(sequenceCounter) / Float(count)) * 2 * Float.pi
                sequenceCounter = (sequenceCounter + 1) % count

                instance.position = controlPoints[controlPointIndex] ?? .zero
                let speed = randomVector(min: speedMin, max: speedMax, rng: &rng)
                let rotated = SIMD3<Float>(
                    cos(angle) * speed.x - sin(angle) * speed.y,
                    sin(angle) * speed.x + cos(angle) * speed.y,
                    speed.z
                )
                instance.velocity = rotated * overrides.speed
            default:
                continue
            }
        }
    }

    func applyParticleOperators(
        particle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Float,
        currentTime: Float,
        controlPoints: [Int: SIMD3<Float>],
        operatorRandoms: inout [Int: SIMD2<Float>],
        rng: inout ParticleRandomGenerator,
        particles: inout [ParticleInstanceState]
    ) {
        for (operatorIndex, `operator`) in particle.operators.enumerated() {
            switch `operator`.kind.lowercased() {
            case "remapvalue":
                let parameters = ParticleOperatorParameters(values: `operator`.parameters, evaluator: propertyEvaluator)
                let settings = ParticleRemap.Settings.read(parameters, flags: `operator`.flags ?? 3)
                let timeOfDay = settings.input == "timeofday" ? ParticleRemap.currentTimeOfDay() : 0
                for index in particles.indices where particles[index].isAlive {
                    ParticleRemap.apply(to: &particles[index], settings: settings, systemTime: currentTime,
                                        timeOfDay: timeOfDay, controlPoints: controlPoints)
                }
            case "capvelocity":
                let parameters = ParticleOperatorParameters(values: `operator`.parameters, evaluator: propertyEvaluator)
                let maximum = max(0, parameters.scalar("maxspeed", default: 100))
                let blend = ParticleOperatorBlend.read(parameters)
                for index in particles.indices where particles[index].isAlive {
                    let speed = simd_length(particles[index].velocity)
                    if speed > maximum {
                        particles[index].velocity *= 1 + (maximum / speed - 1) * blend.weight(at: particles[index].lifetimePosition)
                    }
                }
            case "boids":
                let parameters = ParticleOperatorParameters(values: `operator`.parameters, evaluator: propertyEvaluator)
                ParticleBoids.apply(to: &particles, settings: .read(parameters, flags: `operator`.flags ?? 1),
                                    deltaTime: deltaTime, speed: overrides.speed)
            case "collisionquad", "collisionplane":
                let parameters = ParticleOperatorParameters(values: `operator`.parameters, evaluator: propertyEvaluator)
                let plane = ParticleCollision.Plane.read(parameters, quad: `operator`.kind.lowercased() == "collisionquad",
                                                         flags: `operator`.flags ?? 0,
                                                         controlPoint: controlPoints[`operator`.controlPoint ?? 0])
                for index in particles.indices { ParticleCollision.apply(to: &particles[index], plane: plane) }
            case "movement":
                let drag = max(parameterScalar("drag", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0), 0)
                let gravity = parameterVector3("gravity", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                for index in particles.indices {
                    particles[index].position += particles[index].velocity * deltaTime
                    particles[index].velocity += gravity * deltaTime * overrides.speed
                    let dragFactor = max(1 - drag * deltaTime, 0)
                    particles[index].velocity *= dragFactor
                }
            case "angularmovement":
                let drag = max(parameterScalar("drag", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0), 0)
                let force = parameterVector3("force", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                for index in particles.indices {
                    particles[index].rotation += particles[index].angularVelocity * deltaTime * overrides.speed
                    particles[index].angularVelocity += force * deltaTime * overrides.speed
                    let dragFactor = max(1 - drag * deltaTime, 0)
                    particles[index].angularVelocity *= dragFactor
                }
            case "alphafade":
                let fadeInTime = parameterScalar("fadeintime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let fadeOutTime = parameterScalar("fadeouttime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                for index in particles.indices {
                    let life = particles[index].lifetimePosition
                    if life <= fadeInTime, fadeInTime > 0.0001 {
                        particles[index].color.w = particles[index].initial.color.w * interpolateFade(value: life, startTime: 0, endTime: fadeInTime)
                    } else if life > fadeOutTime {
                        particles[index].color.w = particles[index].initial.color.w * (1 - interpolateFade(value: life, startTime: fadeOutTime, endTime: 1))
                    } else {
                        particles[index].color.w = particles[index].initial.color.w
                    }
                    particles[index].oscillateAlpha.base = particles[index].color.w
                }
            case "oscillatealpha":
                let frequencyMin = parameterScalar("frequencymin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let frequencyMax = parameterScalar("frequencymax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: frequencyMin)
                let scaleMin = parameterScalar("scalemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let scaleMax = parameterScalar("scalemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: scaleMin)
                let phaseMin = parameterScalar("phasemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phasemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
                for index in particles.indices {
                    if !particles[index].oscillateAlpha.initialized {
                        particles[index].oscillateAlpha.frequency = rng.nextFloat(min: frequencyMin, max: frequencyMax)
                        particles[index].oscillateAlpha.phase = rng.nextFloat(min: phaseMin, max: phaseMax + 2 * .pi)
                        particles[index].oscillateAlpha.base = particles[index].color.w
                        particles[index].oscillateAlpha.initialized = true
                    }
                    let phase = particles[index].oscillateAlpha.phase
                    let omega = particles[index].oscillateAlpha.frequency
                    let t = particles[index].age
                    let cosine = (cos(omega * t + phase) + 1) * 0.5
                    let multiplier = scaleMin + (scaleMax - scaleMin) * cosine
                    particles[index].color.w = particles[index].oscillateAlpha.base * multiplier
                }
            case "oscillatesize":
                let frequencyMin = parameterScalar("frequencymin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let frequencyMax = parameterScalar("frequencymax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: frequencyMin)
                let scaleMin = parameterScalar("scalemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let scaleMax = parameterScalar("scalemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: scaleMin)
                let phaseMin = parameterScalar("phasemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phasemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
                for index in particles.indices {
                    if !particles[index].oscillateSize.initialized {
                        particles[index].oscillateSize.frequency = rng.nextFloat(min: frequencyMin, max: frequencyMax)
                        particles[index].oscillateSize.phase = rng.nextFloat(min: phaseMin, max: phaseMax + 2 * .pi)
                        particles[index].oscillateSize.base = particles[index].size
                        particles[index].oscillateSize.initialized = true
                    }
                    let phase = particles[index].oscillateSize.phase
                    let omega = particles[index].oscillateSize.frequency
                    let t = particles[index].age
                    let cosine = (cos(omega * t + phase) + 1) * 0.5
                    let multiplier = scaleMin + (scaleMax - scaleMin) * cosine
                    particles[index].size = particles[index].oscillateSize.base * multiplier
                }
            case "sizechange":
                let startTime = parameterScalar("starttime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let endTime = parameterScalar("endtime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let startValue = parameterScalar("startvalue", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let endValue = parameterScalar("endvalue", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                for index in particles.indices {
                    let life = particles[index].lifetimePosition
                    let multiplier = fadeValue(life: life, startTime: startTime, endTime: endTime, startValue: startValue, endValue: endValue)
                    particles[index].size = particles[index].initial.size * multiplier
                    particles[index].oscillateSize.base = particles[index].size
                }
            case "alphachange":
                let startTime = parameterScalar("starttime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let endTime = parameterScalar("endtime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let startValue = parameterScalar("startvalue", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let endValue = parameterScalar("endvalue", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                for index in particles.indices {
                    let life = particles[index].lifetimePosition
                    let multiplier = fadeValue(life: life, startTime: startTime, endTime: endTime, startValue: startValue, endValue: endValue)
                    particles[index].color.w = particles[index].initial.color.w * multiplier
                    particles[index].oscillateAlpha.base = particles[index].color.w
                }
            case "colorchange":
                let startTime = parameterScalar("starttime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let endTime = parameterScalar("endtime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let startValue = normalizedColor3(propertyEvaluator.vector3Value(for: `operator`.parameters["startvalue"], default: RuntimeVector3(x: 1, y: 1, z: 1)))
                let endValue = normalizedColor3(propertyEvaluator.vector3Value(for: `operator`.parameters["endvalue"], default: RuntimeVector3(x: 1, y: 1, z: 1)))
                for index in particles.indices {
                    let life = particles[index].lifetimePosition
                    let color = SIMD3<Float>(
                        fadeValue(life: life, startTime: startTime, endTime: endTime, startValue: startValue.x, endValue: endValue.x),
                        fadeValue(life: life, startTime: startTime, endTime: endTime, startValue: startValue.y, endValue: endValue.y),
                        fadeValue(life: life, startTime: startTime, endTime: endTime, startValue: startValue.z, endValue: endValue.z)
                    )
                    particles[index].color.x = particles[index].initial.color.x * color.x
                    particles[index].color.y = particles[index].initial.color.y * color.y
                    particles[index].color.z = particles[index].initial.color.z * color.z
                }
            case "controlpointattract":
                let controlPointIndex = `operator`.controlPoint ?? 0
                let origin = parameterVector3("origin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                let scale = parameterScalar("scale", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let threshold = parameterScalar("threshold", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0) / 2
                let center = (controlPoints[controlPointIndex] ?? .zero) + origin
                for index in particles.indices {
                    let toCenter = center - particles[index].position
                    let distance = simd_length(toCenter)
                    if distance > 0.001, distance < threshold {
                        let direction = toCenter / distance
                        particles[index].velocity += direction * scale * deltaTime * overrides.speed
                    }
                }
            case "turbulence":
                let noiseScale = parameterScalar("scale", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1) * 2
                let speedMin = parameterScalar("speedmin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let speedMax = parameterScalar("speedmax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: speedMin)
                let timeScale = parameterScalar("timescale", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMin = parameterScalar("phasemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phasemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
                let mask = parameterVector3("mask", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: 1, y: 1, z: 1))

                // Phase and speed randomize once per operator, not per particle.
                if operatorRandoms[operatorIndex] == nil {
                    operatorRandoms[operatorIndex] = SIMD2<Float>(
                        rng.nextFloat(min: phaseMin, max: phaseMax),
                        rng.nextFloat(min: speedMin, max: speedMax)
                    )
                }
                let randoms = operatorRandoms[operatorIndex] ?? .zero
                let turbulenceSpeed = randoms.y
                guard turbulenceSpeed > 0.0001 else {
                    continue
                }
                for index in particles.indices {
                    var noisePos = particles[index].position
                    noisePos.x += randoms.x + timeScale * currentTime
                    noisePos *= noiseScale
                    var curlDirection = ParticleNoise.curl(noisePos)
                    let curlLength = simd_length(curlDirection)
                    if curlLength > 0.0001 {
                        curlDirection = (curlDirection / curlLength) * turbulenceSpeed
                    }
                    curlDirection *= mask
                    particles[index].velocity += curlDirection * deltaTime * overrides.speed
                }
            case "vortex":
                let flags = `operator`.flags ?? 0
                let infiniteAxis = (flags & 1) != 0
                let maintainDistance = (flags & 2) != 0
                let ringShape = (flags & 4) != 0
                var axis = parameterVector3("axis", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: 0, y: 0, z: 1))
                let offset = parameterVector3("offset", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: .zero)
                let distanceInner = parameterScalar("distanceinner", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let distanceOuter = parameterScalar("distanceouter", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let speedInner = parameterScalar("speedinner", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let speedOuter = parameterScalar("speedouter", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let centerForce = parameterScalar("centerforce", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let ringRadius = parameterScalar("ringradius", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let ringWidth = parameterScalar("ringwidth", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let ringPullDistance = parameterScalar("ringpulldistance", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let ringPullForce = parameterScalar("ringpullforce", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)

                let controlPointIndex = `operator`.controlPoint ?? -1
                let center = (controlPoints[controlPointIndex] ?? .zero) + offset
                axis = simd_length(axis) > 0.0001 ? simd_normalize(axis) : SIMD3<Float>(0, 0, 1)

                for index in particles.indices {
                    let toParticle = particles[index].position - center
                    var radialVector = toParticle
                    if infiniteAxis {
                        let axialDistance = simd_dot(toParticle, axis)
                        radialVector = toParticle - axis * axialDistance
                    }
                    let distance = simd_length(radialVector)
                    var tangent = simd_cross(axis, radialVector)
                    let tangentLength = simd_length(tangent)
                    guard tangentLength > 0.001 else {
                        continue
                    }
                    tangent /= tangentLength

                    var speed: Float = 0
                    var radialForce = SIMD3<Float>(repeating: 0)
                    if ringShape {
                        let ringInner = ringRadius - ringWidth * 0.5
                        let ringOuter = ringRadius + ringWidth * 0.5
                        if distance < ringInner {
                            speed = 0
                        } else if distance <= ringOuter, ringWidth > 0.0001 {
                            let t = (distance - ringInner) / ringWidth
                            speed = speedInner + (speedOuter - speedInner) * t
                        } else if distance <= ringOuter + ringPullDistance, ringPullDistance > 0.0001 {
                            let pullT = (distance - ringOuter) / ringPullDistance
                            speed = speedOuter * (1 - pullT)
                            if distance > 0.001 {
                                radialForce = -simd_normalize(radialVector) * ringPullForce * pullT
                            }
                        }
                    } else {
                        let spanMid = distanceOuter - distanceInner + 0.1
                        if spanMid < 0 || distance < distanceInner {
                            speed = speedInner
                        } else if distance > distanceOuter {
                            speed = speedOuter
                        } else {
                            let t = (distance - distanceInner) / spanMid
                            speed = speedInner + (speedOuter - speedInner) * t
                        }
                    }

                    particles[index].velocity += tangent * speed * deltaTime * overrides.speed
                    particles[index].velocity += radialForce * deltaTime * overrides.speed
                    if maintainDistance, distance > 0.001 {
                        particles[index].velocity += -simd_normalize(radialVector) * centerForce * deltaTime * overrides.speed
                    }
                }
            case "oscillateposition":
                let frequencyMin = parameterScalar("frequencymin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let frequencyMax = parameterScalar("frequencymax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: frequencyMin)
                let scaleMin = parameterScalar("scalemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let scaleMax = parameterScalar("scalemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: scaleMin)
                let phaseMin = parameterScalar("phasemin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phasemax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
                let mask = parameterVector3("mask", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: RuntimeVector3(x: 1, y: 1, z: 1))
                for index in particles.indices {
                    if !particles[index].oscillatePosition.initialized {
                        particles[index].oscillatePosition.frequency = SIMD3<Float>(
                            rng.nextFloat(min: frequencyMin, max: frequencyMax),
                            rng.nextFloat(min: frequencyMin, max: frequencyMax),
                            rng.nextFloat(min: frequencyMin, max: frequencyMax)
                        )
                        particles[index].oscillatePosition.phase = SIMD3<Float>(
                            rng.nextFloat(min: phaseMin, max: phaseMax + 2 * .pi),
                            rng.nextFloat(min: phaseMin, max: phaseMax + 2 * .pi),
                            rng.nextFloat(min: phaseMin, max: phaseMax + 2 * .pi)
                        )
                        particles[index].oscillatePosition.scale = SIMD3<Float>(
                            rng.nextFloat(min: scaleMin, max: scaleMax),
                            rng.nextFloat(min: scaleMin, max: scaleMax),
                            rng.nextFloat(min: scaleMin, max: scaleMax)
                        )
                        particles[index].oscillatePosition.initialized = true
                    }
                    let age = particles[index].age
                    var delta = SIMD3<Float>(repeating: 0)
                    for axis in 0..<3 {
                        let omega = particles[index].oscillatePosition.frequency[axis]
                        let phase = particles[index].oscillatePosition.phase[axis]
                        let scale = particles[index].oscillatePosition.scale[axis]
                        let movement = -scale * omega * sin(omega * age + phase) * deltaTime
                        delta[axis] = movement * mask[axis] * overrides.speed
                    }
                    particles[index].position += delta
                }
            default:
                continue
            }
        }
    }

    func particleInstanceFrame(from state: ParticleInstanceState) -> FrameParticleInstance {
        FrameParticleInstance(
            position: RuntimeVector3(x: state.position.x, y: state.position.y, z: state.position.z),
            rotation: RuntimeVector3(x: state.rotation.x, y: state.rotation.y, z: state.rotation.z),
            size: state.size,
            color: RuntimeVector4(x: state.color.x, y: state.color.y, z: state.color.z, w: state.color.w),
            velocity: RuntimeVector3(x: state.velocity.x, y: state.velocity.y, z: state.velocity.z),
            lifetimePosition: state.lifetimePosition,
            animationRandom: state.animationRandom,
            trail: state.trail.isEmpty ? nil : state.trail.map { RuntimeVector3(x: $0.x, y: $0.y, z: $0.z) }
        )
    }

    func parameterScalar(
        _ key: String,
        from parameters: [String: UserSettingDescriptor],
        propertyEvaluator: PropertyEvaluator,
        default defaultValue: Float
    ) -> Float {
        Float(propertyEvaluator.scalarDouble(for: parameters[key], default: Double(defaultValue)))
    }

    func parameterVector3(
        _ key: String,
        from parameters: [String: UserSettingDescriptor],
        propertyEvaluator: PropertyEvaluator,
        default defaultValue: RuntimeVector3
    ) -> SIMD3<Float> {
        let resolved = propertyEvaluator.vector3Value(for: parameters[key], default: defaultValue)
        return SIMD3<Float>(resolved.x, resolved.y, resolved.z)
    }

    func randomVector(min: SIMD3<Float>, max: SIMD3<Float>, rng: inout ParticleRandomGenerator) -> SIMD3<Float> {
        SIMD3<Float>(
            rng.nextFloat(min: min.x, max: max.x),
            rng.nextFloat(min: min.y, max: max.y),
            rng.nextFloat(min: min.z, max: max.z)
        )
    }

    func randomVector(
        min: SIMD3<Float>,
        max: SIMD3<Float>,
        exponent: Float,
        rng: inout ParticleRandomGenerator
    ) -> SIMD3<Float> {
        var value = SIMD3<Float>(repeating: 0)
        for axis in 0..<3 {
            let t = pow(rng.nextUnitFloat(), exponent)
            value[axis] = min[axis] + (max[axis] - min[axis]) * t
        }
        return value
    }

    func normalizedColor(_ color: RuntimeVector4) -> SIMD4<Float> {
        let maxComponent = Swift.max(Swift.max(color.x, color.y), Swift.max(color.z, color.w))
        let scale: Float = maxComponent > 1.5 ? 255 : 1
        return SIMD4<Float>(color.x / scale, color.y / scale, color.z / scale, color.w / scale)
    }

    func normalizedColor3(_ color: RuntimeVector3) -> SIMD3<Float> {
        let scale: Float = Swift.max(Swift.max(color.x, color.y), color.z) > 1.5 ? 255 : 1
        return SIMD3<Float>(color.x / scale, color.y / scale, color.z / scale)
    }

    func interpolateFade(value: Float, startTime: Float, endTime: Float) -> Float {
        let duration = max(endTime - startTime, 0.0001)
        return min(max((value - startTime) / duration, 0), 1)
    }

    func fadeValue(life: Float, startTime: Float, endTime: Float, startValue: Float, endValue: Float) -> Float {
        if life <= startTime {
            return startValue
        }
        if life >= endTime {
            return endValue
        }
        let t = (life - startTime) / max(endTime - startTime, 0.0001)
        return startValue + t * (endValue - startValue)
    }

    // MARK: - Child particle systems

    func updateChildSystems(
        particle: ParticleDescriptor,
        state: inout ParticleSystemState,
        parentSeed: UInt64,
        emissionEnabled: Bool,
        transportEmissionEnabled: Bool,
        controlPoints: [Int: SIMD3<Float>],
        childMaterialReferences: [String: String],
        childPath: String,
        nodeID: NodeID,
        propertyEvaluator: PropertyEvaluator,
        cursorPosition: RuntimeVector2?,
        worldTransform: simd_float4x4,
        deltaTime: Float,
        depth: Int
    ) -> [FrameParticleSystem] {
        guard depth < 3, !particle.children.isEmpty else {
            return []
        }

        let liveParentPositions = state.particles.map(\.position)
        let spawnedPositions = state.spawnedThisFrame
        let diedPositions = state.diedThisFrame
        var systems: [FrameParticleSystem] = []

        for (index, child) in particle.children.enumerated() {
            guard let childParticle = child.particle.first,
                  !childParticle.emitters.isEmpty || !childParticle.initializers.isEmpty else {
                continue
            }

            let path = childPath.isEmpty ? "\(index)" : "\(childPath)/\(index)"
            let childSeed = parentSeed &* 31 &+ UInt64(index) &+ 0x9E3779B97F4A7C15
            var childState = state.childStates[index]
                ?? ParticleSystemState(seed: childSeed, emitters: childParticle.emitters)
            childState.emitters = syncedEmitterStates(current: childState.emitters, descriptors: childParticle.emitters)
            childState.particles.removeAll { !$0.isAlive }
            childState.spawnedThisFrame.removeAll(keepingCapacity: true)
            childState.diedThisFrame.removeAll(keepingCapacity: true)

            let childOverrides = resolvedParticleOverrides(for: childParticle, propertyEvaluator: propertyEvaluator)
            let deltaTime = deltaTime * childOverrides.rate
            childState.simulationTime += Double(deltaTime)
            let childBudget = child.maxCount > 0
                ? UInt32(child.maxCount)
                : resolvedParticleCount(for: childParticle, overrides: childOverrides)
            let childControlPoints = resolvedParticleControlPoints(
                for: childParticle,
                cursorPosition: cursorPosition,
                worldTransform: worldTransform,
                instanceID: "scene.node.\(nodeID.rawValue).particle.child.\(path).instanceoverride",
                propertyEvaluator: propertyEvaluator
            )
            let childOrigin = SIMD3<Float>(
                Float(child.origin[safe: 0] ?? 0),
                Float(child.origin[safe: 1] ?? 0),
                Float(child.origin[safe: 2] ?? 0)
            )
            let probability = Float(min(max(child.probability, 0), 1))

            if deltaTime > 0 {
                switch child.type.lowercased() {
                case "eventspawn", "eventdeath":
                    // Transport pauses every automatic emitter in the definition tree.
                    // Preserve the existing event behavior of ordinary visibility gates.
                    guard transportEmissionEnabled else { break }
                    let events = child.type.lowercased() == "eventspawn" ? spawnedPositions : diedPositions
                    for eventPosition in events {
                        guard probability >= 1 || childState.rng.nextUnitFloat() <= probability else {
                            continue
                        }
                        emitChildBurst(
                            childParticle: childParticle,
                            overrides: childOverrides,
                            budget: childBudget,
                            controlPoints: childControlPoints,
                            origin: eventPosition + childOrigin,
                            propertyEvaluator: propertyEvaluator,
                            state: &childState
                        )
                    }
                case "eventfollow":
                    if emissionEnabled, !liveParentPositions.isEmpty {
                        emitChildFollow(
                            childParticle: childParticle,
                            overrides: childOverrides,
                            budget: childBudget,
                            controlPoints: childControlPoints,
                            parentPositions: liveParentPositions,
                            childOrigin: childOrigin,
                            propertyEvaluator: propertyEvaluator,
                            deltaTime: deltaTime,
                            state: &childState
                        )
                    }
                default:
                    // "static"/"" children emit continuously from their fixed offset.
                    if emissionEnabled {
                        for (emitterIndex, emitter) in childParticle.emitters.enumerated()
                        where childState.emitters.indices.contains(emitterIndex) {
                            emitParticles(
                                particle: childParticle,
                                emitter: emitter,
                                emitterState: &childState.emitters[emitterIndex],
                                overrides: childOverrides,
                                maxParticleCount: childBudget,
                                controlPoints: childControlPoints,
                                propertyEvaluator: propertyEvaluator,
                                deltaTime: deltaTime,
                                systemTime: Float(childState.simulationTime),
                                rng: &childState.rng,
                                particles: &childState.particles,
                                spawned: &childState.spawnedThisFrame,
                                sequenceCounter: &childState.sequenceCounter,
                                originOffset: childOrigin
                            )
                        }
                    }
                }

                advanceParticleState(
                    state: &childState,
                    particle: childParticle,
                    overrides: childOverrides,
                    propertyEvaluator: propertyEvaluator,
                    controlPoints: childControlPoints,
                    deltaTime: deltaTime
                )
            }

            let grandchildren = updateChildSystems(
                particle: childParticle,
                state: &childState,
                parentSeed: childSeed,
                emissionEnabled: emissionEnabled,
                transportEmissionEnabled: transportEmissionEnabled,
                controlPoints: childControlPoints,
                childMaterialReferences: childMaterialReferences,
                childPath: path,
                nodeID: nodeID,
                propertyEvaluator: propertyEvaluator,
                cursorPosition: cursorPosition,
                worldTransform: worldTransform,
                deltaTime: deltaTime,
                depth: depth + 1
            )

            state.childStates[index] = childState

            guard !childState.particles.isEmpty || !grandchildren.isEmpty else {
                continue
            }

            let rendererDescriptor = childParticle.renderers.first
            systems.append(
                FrameParticleSystem(
                    nodeID: nodeID,
                    visible: true,
                    materialReference: childMaterialReferences[path],
                    rendererName: rendererDescriptor?.name.lowercased() ?? "sprite",
                    maxParticleCount: childBudget,
                    liveParticleEstimate: UInt32(min(childState.particles.count, Int(UInt32.max))),
                    emissionEnabled: transportEmissionEnabled,
                    sequenceMultiplier: childParticle.sequenceMultiplier,
                    startTime: childParticle.startTime,
                    instances: childState.particles.map { particleInstanceFrame(from: $0) },
                    rendererParameters: rendererDescriptor.map {
                        FrameParticleRendererParameters(
                            length: $0.length,
                            maxLength: $0.maxLength,
                            minLength: $0.minLength,
                            subdivision: $0.subdivision
                        )
                    },
                    childSystems: grandchildren,
                    animationMode: childParticle.animationMode
                )
            )
        }

        return systems
    }

    /// Burst emission for eventspawn/eventdeath children: each emitter fires its
    /// instantaneous count (at least one particle) at the event position.
    func emitChildBurst(
        childParticle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        budget: UInt32,
        controlPoints: [Int: SIMD3<Float>],
        origin: SIMD3<Float>,
        propertyEvaluator: PropertyEvaluator,
        state: inout ParticleSystemState
    ) {
        let limit = Int(budget)
        for emitter in childParticle.emitters {
            let burstCount = Int(min(Double(max(emitter.instantaneous, 1)) * Double(overrides.count), Double(budget)))
            for _ in 0..<burstCount where state.particles.count < limit {
                let instance = spawnParticle(
                    particle: childParticle,
                    emitter: emitter,
                    overrides: overrides,
                    controlPoints: controlPoints,
                    propertyEvaluator: propertyEvaluator,
                    rng: &state.rng,
                    sequenceCounter: &state.sequenceCounter,
                    systemTime: Float(state.simulationTime),
                    originOffset: origin
                )
                state.particles.append(instance)
                state.spawnedThisFrame.append(instance.position)
            }
        }
    }

    /// Continuous emission for eventfollow children: emission rate scales with
    /// the number of live parent particles and each spawn tracks one of them.
    func emitChildFollow(
        childParticle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        budget: UInt32,
        controlPoints: [Int: SIMD3<Float>],
        parentPositions: [SIMD3<Float>],
        childOrigin: SIMD3<Float>,
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Float,
        state: inout ParticleSystemState
    ) {
        let limit = Int(budget)
        for (emitterIndex, emitter) in childParticle.emitters.enumerated()
        where state.emitters.indices.contains(emitterIndex) {
            guard emitter.rate > 0 else {
                continue
            }
            state.emitters[emitterIndex].emissionTimer +=
                Double(deltaTime) * emitter.rate * Double(overrides.count) * Double(parentPositions.count)
            var toEmit = Int(min(state.emitters[emitterIndex].emissionTimer.rounded(.down), Double(budget)))
            state.emitters[emitterIndex].emissionTimer.formTruncatingRemainder(dividingBy: 1)
            toEmit = min(toEmit, max(limit - state.particles.count, 0))

            for _ in 0..<toEmit {
                let parentIndex = state.rng.nextInt(max: parentPositions.count)
                let parentPosition = parentPositions[min(parentIndex, parentPositions.count - 1)]
                let instance = spawnParticle(
                    particle: childParticle,
                    emitter: emitter,
                    overrides: overrides,
                    controlPoints: controlPoints,
                    propertyEvaluator: propertyEvaluator,
                    rng: &state.rng,
                    sequenceCounter: &state.sequenceCounter,
                    systemTime: Float(state.simulationTime),
                    originOffset: parentPosition + childOrigin
                )
                state.particles.append(instance)
                state.spawnedThisFrame.append(instance.position)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
