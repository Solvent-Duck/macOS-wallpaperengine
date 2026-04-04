import Foundation
import NativeSceneCore
import simd

public final class SceneRuntime: @unchecked Sendable {
    public let scene: SceneDescription

    public private(set) var frameIndex: UInt64 = 0
    public private(set) var elapsedTime: Double = 0
    public private(set) var isPaused = false
    public private(set) var parallaxDisplacement = RuntimeVector2.zero
    private var particleStates: [NodeID: ParticleSystemState] = [:]

    public init(scene: SceneDescription) {
        self.scene = scene
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    @discardableResult
    public func step(
        deltaTime: Double,
        propertyOverrides: [String: FrameValue] = [:],
        audioInput: AudioInputState = .silent,
        cursorPosition: RuntimeVector2? = nil
    ) -> FramePacket {
        let clampedDelta = max(0, deltaTime)
        if !isPaused {
            elapsedTime += clampedDelta
        }

        let context = PropertyEvaluationContext(
            elapsedTime: elapsedTime,
            deltaTime: clampedDelta,
            frameIndex: frameIndex,
            cursorPosition: cursorPosition,
            propertyOverrides: propertyOverrides,
            audio: audioInput
        )
        let propertyEvaluator = PropertyEvaluator(scene: scene, context: context)
        updateParallaxDisplacement(
            deltaTime: clampedDelta,
            propertyEvaluator: propertyEvaluator,
            cursorPosition: cursorPosition
        )
        let transformStates = TransformEvaluator.evaluate(
            scene: scene,
            propertyEvaluator: propertyEvaluator,
            parallaxDisplacement: parallaxDisplacement
        )
        let orderedNodes = TransformEvaluator.evaluationOrder(for: scene.nodes)

        var nodeVisibility: [NodeID: Bool] = [:]
        var nodeFrames: [FrameNode] = []
        var materials: [FrameMaterial] = []
        var lights: [FrameLight] = []
        var particleSystems: [FrameParticleSystem] = []
        var texts: [FrameText] = []

        for node in orderedNodes {
            let animationState = AnimationEvaluator.evaluate(
                node: node,
                elapsedTime: elapsedTime,
                propertyEvaluator: propertyEvaluator
            )
            let visible = resolveVisibility(
                for: node,
                propertyEvaluator: propertyEvaluator,
                parentVisibility: node.parentId.flatMap { nodeVisibility[$0] } ?? true,
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
                materialReference: materialCollection.references.first,
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
                    parentID: node.parentId,
                    dependencyIDs: node.dependencyIds,
                    localTransform: transform.localTransform,
                    worldTransform: transform.worldTransform,
                    worldPosition: transform.worldTransform.translation,
                    visible: visible,
                    opacity: resolveOpacity(for: node, propertyEvaluator: propertyEvaluator),
                    renderItemReferences: materialCollection.references,
                    imageEffects: materialCollection.imageEffects,
                    animationLayers: animationState.layers
                )
            )
        }

        let cameraBloom = buildCameraBloom(propertyEvaluator: propertyEvaluator)

        let packet = FramePacket(
            metadata: scene.metadata,
            timing: RuntimeClock(
                frameIndex: frameIndex,
                deltaTime: clampedDelta,
                elapsedTime: elapsedTime,
                isPaused: isPaused
            ),
            cursor: cursorPosition.map {
                RuntimeCursorState(normalized: $0, parallaxDisplacement: parallaxDisplacement)
            },
            cameraBloom: cameraBloom,
            properties: propertyEvaluator.resolvedUserProperties(),
            nodes: nodeFrames,
            materials: materials,
            lights: lights,
            particleSystems: particleSystems,
            texts: texts
        )

        frameIndex += 1
        return packet
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
            x: (cursorPosition.x - 0.5) * 2,
            y: (cursorPosition.y - 0.5) * 2
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

    private func resolveVisibility(
        for node: NodeDescriptor,
        propertyEvaluator: PropertyEvaluator,
        parentVisibility: Bool,
        animationState: AnimationState
    ) -> Bool {
        let ownVisibility: Bool
        switch node.kind {
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
    ) -> (references: [String], imageEffects: [FrameImageEffect]) {
        var references: [String] = []
        var imageEffects: [FrameImageEffect] = []

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

        if let image = node.image {
            imageEffects = buildImageEffects(
                for: node,
                image: image,
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

        return (references, imageEffects)
    }

    private func materialFrame(
        idPrefix: String,
        nodeID: NodeID,
        material: MaterialDescriptor,
        propertyEvaluator: PropertyEvaluator,
        overridePass: EffectOverridePassDescriptor? = nil
    ) -> FrameMaterial {
        let passes: [FrameMaterialPass] = material.passes.enumerated().map { index, pass in
            let appliesOverride = overridePass.map { $0.id < 0 || $0.id == index } ?? false
            let resolvedTextures = appliesOverride && !(overridePass?.textures.isEmpty ?? true)
                ? overridePass?.textures ?? []
                : pass.textures
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
                textures: resolvedTextures.map { FrameTextureBinding(slot: $0.slot, path: $0.path) },
                userTextures: pass.userTextures.map { FrameTextureBinding(slot: $0.slot, path: $0.path) },
                constants: resolvedConstants,
                combos: pass.combos.merging(
                    appliesOverride ? (overridePass?.combos ?? [:]) : [:],
                    uniquingKeysWith: { _, override in override }
                )
            )
        }

        return FrameMaterial(
            id: "\(idPrefix):\(material.filename)",
            sourceNodeID: nodeID,
            sourceFile: material.filename,
            passOrdering: passes.map(\.index),
            passes: passes
        )
    }

    private func buildImageEffects(
        for node: NodeDescriptor,
        image: ImageDescriptor,
        propertyEvaluator: PropertyEvaluator,
        materials: inout [FrameMaterial]
    ) -> [FrameImageEffect] {
        var frames: [FrameImageEffect] = []

        for imageEffect in image.effects {
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
                        idPrefix: "node\(node.id.rawValue)-effect\(imageEffect.id)-pass\(passIndex)",
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
                    renderTargets: effect.fbos.map {
                        FrameRenderTargetDescriptor(
                            name: $0.name,
                            scale: $0.scale,
                            unique: $0.unique
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
            castsShadow: light.castsShadow
        )
    }

    private func buildParticleFrame(
        node: NodeDescriptor,
        visible: Bool,
        materialReference: String?,
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Double,
        cursorPosition: RuntimeVector2?
    ) -> FrameParticleSystem? {
        guard let particle = node.particle else {
            return nil
        }

        guard particleDescriptorIsSupported(particle) else {
            particleStates[node.id] = nil
            return nil
        }

        let rendererName = particle.renderers.first?.name.lowercased() ?? "sprite"
        let emitDelay = Double(particle.startTime) / 1000.0
        let overrides = resolvedParticleOverrides(for: particle, propertyEvaluator: propertyEvaluator)
        let maxParticleCount = resolvedParticleCount(for: particle, overrides: overrides)
        let emissionEnabled = visible && elapsedTime >= emitDelay && maxParticleCount > 0

        var state = particleStates[node.id] ?? ParticleSystemState(nodeID: node.id, emitters: particle.emitters)
        state.emitters = syncedEmitterStates(current: state.emitters, descriptors: particle.emitters)
        state.particles.removeAll { !$0.isAlive }

        if emissionEnabled, deltaTime > 0 {
            let controlPoints = resolvedParticleControlPoints(
                for: particle,
                cursorPosition: cursorPosition
            )
            updateParticleSystem(
                particle: particle,
                state: &state,
                overrides: overrides,
                maxParticleCount: maxParticleCount,
                controlPoints: controlPoints,
                propertyEvaluator: propertyEvaluator,
                deltaTime: Float(deltaTime)
            )
        } else if deltaTime > 0, !state.particles.isEmpty {
            advanceParticleState(
                state: &state,
                particle: particle,
                overrides: overrides,
                propertyEvaluator: propertyEvaluator,
                deltaTime: Float(deltaTime)
            )
        }

        particleStates[node.id] = state
        let liveEstimate = UInt32(min(state.particles.count, Int(UInt32.max)))
        let instances = state.particles.map { particleInstanceFrame(from: $0) }

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
            instances: instances
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

        return FrameText(
            nodeID: node.id,
            visible: visible,
            content: content,
            fontPath: text.fontPath,
            pointSize: propertyEvaluator.scalarDouble(for: text.pointSize, default: 16),
            size: RuntimeVector2(text.size, default: RuntimeVector2(x: 256, y: 64)),
            maxWidth: text.maxWidth,
            maxRows: text.maxRows,
            padding: text.padding,
            color: RuntimeVector4(x: color.x, y: color.y, z: color.z, w: color.w * opacity),
            horizontalAlign: text.horizontalAlign,
            verticalAlign: text.verticalAlign,
            limitWidth: text.limitWidth,
            limitRows: text.limitRows,
            limitUseEllipsis: text.limitUseEllipsis,
            blockAlign: text.blockAlign,
            castShadow: text.castShadow,
            opaqueBackground: text.opaqueBackground,
            backgroundColor: backgroundColor
        )
    }
}

private extension SceneRuntime {
    func particleDescriptorIsSupported(_ particle: ParticleDescriptor) -> Bool {
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

        guard !particle.renderers.isEmpty,
              particle.renderers.allSatisfy({ supportedRenderers.contains($0.name.lowercased()) }),
              particle.emitters.allSatisfy({ supportedEmitters.contains($0.name.lowercased()) }),
              particle.initializers.allSatisfy({ supportedInitializers.contains($0.kind.lowercased()) }),
              particle.operators.allSatisfy({ supportedOperators.contains($0.kind.lowercased()) }),
              particle.children.isEmpty,
              particle.controlPoints.allSatisfy({ !$0.lockToPointer }) else {
            return false
        }

        return true
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
        let scaled = UInt32((Float(particle.maxCount) * overrides.count).rounded(.toNearestOrEven))
        return scaled > 0 ? scaled : max(particle.maxCount, 256)
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
        cursorPosition: RuntimeVector2?
    ) -> [Int: SIMD3<Float>] {
        Dictionary(uniqueKeysWithValues: particle.controlPoints.map { controlPoint in
            let offset = SIMD3<Float>(
                Float(controlPoint.offset[safe: 0] ?? 0),
                Float(controlPoint.offset[safe: 1] ?? 0),
                Float(controlPoint.offset[safe: 2] ?? 0)
            )
            if controlPoint.lockToPointer, let cursorPosition {
                let projection = scene.scene?.camera.projection
                let width = Float(max(projection?.width ?? 1, 1))
                let height = Float(max(projection?.height ?? 1, 1))
                let pointer = SIMD3<Float>(
                    cursorPosition.x * width,
                    cursorPosition.y * height,
                    0
                )
                return (controlPoint.id, pointer + offset)
            }
            return (controlPoint.id, offset)
        })
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
                rng: &state.rng,
                particles: &state.particles
            )
        }

        advanceParticleState(
            state: &state,
            particle: particle,
            overrides: overrides,
            propertyEvaluator: propertyEvaluator,
            deltaTime: deltaTime
        )
    }

    func advanceParticleState(
        state: inout ParticleSystemState,
        particle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        propertyEvaluator: PropertyEvaluator,
        deltaTime: Float
    ) {
        guard deltaTime > 0 else {
            return
        }

        for index in state.particles.indices {
            state.particles[index].age += deltaTime
        }

        applyParticleOperators(
            particle: particle,
            overrides: overrides,
            propertyEvaluator: propertyEvaluator,
            deltaTime: deltaTime,
            rng: &state.rng,
            particles: &state.particles
        )

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
        rng: inout ParticleRandomGenerator,
        particles: inout [ParticleInstanceState]
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
            toEmit += Int(emitter.instantaneous)
            emitterState.instantaneousEmitted = true
        }

        if emitter.rate > 0 {
            emitterState.emissionTimer += Double(deltaTime) * Double(Float(emitter.rate) * overrides.rate)
            var rateEmit = Int(emitterState.emissionTimer)
            emitterState.emissionTimer -= Double(rateEmit)
            if (emitter.flags & 2) != 0 {
                rateEmit = min(rateEmit, 1)
            }
            toEmit += rateEmit
        }

        guard toEmit > 0 else {
            return
        }

        let limit = Int(maxParticleCount)
        for _ in 0..<toEmit where particles.count < limit {
            particles.append(
                spawnParticle(
                    particle: particle,
                    emitter: emitter,
                    overrides: overrides,
                    controlPoints: controlPoints,
                    propertyEvaluator: propertyEvaluator,
                    rng: &rng
                )
            )
        }
    }

    func spawnParticle(
        particle: ParticleDescriptor,
        emitter: ParticleEmitterDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        controlPoints: [Int: SIMD3<Float>],
        propertyEvaluator: PropertyEvaluator,
        rng: inout ParticleRandomGenerator
    ) -> ParticleInstanceState {
        let controlPointOrigin = controlPoints[emitter.controlPoint] ?? .zero
        let emitterOrigin = SIMD3<Float>(
            Float(emitter.origin[safe: 0] ?? 0),
            Float(emitter.origin[safe: 1] ?? 0),
            Float(emitter.origin[safe: 2] ?? 0)
        ) + controlPointOrigin

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
            position += radialOffset
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
            propertyEvaluator: propertyEvaluator,
            rng: &rng,
            instance: &instance
        )
        instance.initial = ParticleInitialState(color: instance.color, size: instance.size, lifetime: instance.lifetime)
        return instance
    }

    func applyParticleInitializers(
        particle: ParticleDescriptor,
        overrides: ParticleResolvedInstanceOverrides,
        propertyEvaluator: PropertyEvaluator,
        rng: inout ParticleRandomGenerator,
        instance: inout ParticleInstanceState
    ) {
        for initializer in particle.initializers {
            switch initializer.kind.lowercased() {
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
        rng: inout ParticleRandomGenerator,
        particles: inout [ParticleInstanceState]
    ) {
        for `operator` in particle.operators {
            switch `operator`.kind.lowercased() {
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
                let fadeInTime = parameterScalar("fadeInTime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let fadeOutTime = parameterScalar("fadeOutTime", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
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
                let frequencyMin = parameterScalar("frequencyMin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let frequencyMax = parameterScalar("frequencyMax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: frequencyMin)
                let scaleMin = parameterScalar("scaleMin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 1)
                let scaleMax = parameterScalar("scaleMax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: scaleMin)
                let phaseMin = parameterScalar("phaseMin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phaseMax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
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
            case "oscillateposition":
                let frequencyMin = parameterScalar("frequencyMin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let frequencyMax = parameterScalar("frequencyMax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: frequencyMin)
                let scaleMin = parameterScalar("scaleMin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let scaleMax = parameterScalar("scaleMax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: scaleMin)
                let phaseMin = parameterScalar("phaseMin", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: 0)
                let phaseMax = parameterScalar("phaseMax", from: `operator`.parameters, propertyEvaluator: propertyEvaluator, default: phaseMin)
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
            lifetimePosition: state.lifetimePosition
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
