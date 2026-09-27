import Foundation
import NativeSceneCore

struct SceneScriptOwner {
    let id: String
    let settings: [String: UserSettingDescriptor]
    let layerID: String?

    init(id: String, settings: [String: UserSettingDescriptor], layerID: String? = nil) {
        self.id = id
        self.settings = settings
        self.layerID = layerID
    }
}

final class SceneScriptRuntime: @unchecked Sendable {
    let scriptHost: ScriptHost
    var scene: SceneDescription { layers.scene }
    var sceneRevision: UInt64 { layers.revision }
    private let layers: SceneLayerCollection
    private let puppetModels: PuppetModelLibrary
    private let textureAnimations: TextureAnimationLibrary
    private let textLayouts: TextLayoutEngine
    private var scriptedSettings: [UserSettingDescriptor]
    private let initialScriptedSettings: [UserSettingDescriptor]
    private var pendingSettings: [UserSettingDescriptor] = []
    private var currentContext: PropertyEvaluationContext?
    private(set) var removedThisFrame: Set<NodeID> = []
    private var initialized = false

    init(scene: SceneDescription, storage: SceneScriptStorage? = nil, puppetModels: PuppetModelLibrary,
         textureAnimations: TextureAnimationLibrary, textLayouts: TextLayoutEngine, assetRoots: [URL]) {
        self.scriptHost = ScriptHost(storage: storage)
        self.layers = SceneLayerCollection(scene: scene, assetRoots: assetRoots)
        self.puppetModels = puppetModels
        self.textureAnimations = textureAnimations
        self.textLayouts = textLayouts
        let (owners, ownerOrder) = Self.buildOwners(scene: scene)
        // Keep every layer's component scripts with that layer. Later layers
        // can consume shared values published by its materials and effects in
        // the same frame, including during module initialization.
        self.scriptedSettings = ownerOrder.flatMap { id in
            guard let owner = owners[id] else { return [UserSettingDescriptor]() }
            return owner.settings.keys.sorted().compactMap { name in
                guard let setting = owner.settings[name], setting.value?.kind == .scripted else { return nil }
                return setting
            }
        }
        self.initialScriptedSettings = scriptedSettings
        do { try scriptHost.configureScene(scene, owners: owners, puppetModels: puppetModels, textureAnimations: textureAnimations, textLayouts: textLayouts) }
        catch { scriptHost.reportFailure(error, instanceID: "scene-bindings") }
        scriptHost.sceneLayerRequest = { [weak self] command in
            guard let self else { throw ScriptHostError.evaluationFailed("Scene has been removed") }
            return try self.layerRequest(command)
        }
    }

    func step(context: PropertyEvaluationContext) {
        currentContext = context
        removedThisFrame = layers.commitRemovals()
        if !removedThisFrame.isEmpty {
            let prefixes = removedThisFrame.map { "scene.node.\($0.rawValue)." }
            func wasRemoved(_ setting: UserSettingDescriptor) -> Bool {
                guard let descriptor = setting.value else { return false }
                let key = scriptHost.label(for: descriptor)
                return prefixes.contains { key.hasPrefix($0) }
            }
            scriptedSettings.removeAll(where: wasRemoved)
            pendingSettings.removeAll(where: wasRemoved)
            scriptHost.removeSceneLayers(removedThisFrame)
        }
        do { try scriptHost.beginSceneFrame(context, scene: scene) }
        catch { scriptHost.reportFailure(error, instanceID: "scene-frame") }
        let evaluator = PropertyEvaluator(scene: scene, context: context)
        if !initialized {
            // Evaluate authored module bodies first so top-level shared
            // publications exist before any owner runs its init callback.
            scriptHost.loadSceneScriptModules {
                for setting in scriptedSettings { _ = evaluator.evaluate(setting) }
            }
            initializeCreatedLayers(context: context, update: false)
            // A final authored initializer may consume values collected by
            // earlier layers. Initial property/media events must see that result.
            scriptHost.initializeSceneScripts {
                for setting in scriptedSettings { _ = evaluator.evaluate(setting) }
            }
            initializeCreatedLayers(context: context, update: false)
            initialized = true
        }
        // Finish all script side effects before transforms and visibility.
        for setting in scriptedSettings { _ = evaluator.evaluate(setting) }
        initializeCreatedLayers(context: context, update: true)
    }

    func endFrame() { currentContext = nil }

    private func initializeCreatedLayers(context: PropertyEvaluationContext, update: Bool) {
        // Creation during init/update is drained in batches. Existing modules
        // keep their state and run once; only the new owners are initialized.
        while !pendingSettings.isEmpty {
            let batch = pendingSettings
            pendingSettings.removeAll(keepingCapacity: true)
            scriptedSettings.append(contentsOf: batch)
            let evaluator = PropertyEvaluator(scene: scene, context: context)
            scriptHost.loadSceneScriptModules { for setting in batch { _ = evaluator.evaluate(setting) } }
            scriptHost.initializeSceneScripts { for setting in batch { _ = evaluator.evaluate(setting) } }
            if update { for setting in batch { _ = evaluator.evaluate(setting) } }
        }
    }

    private func layerRequest(_ command: [String: Any]) throws -> [String: Any] {
        if command["action"] as? String == "create" {
            guard let context = currentContext, let configuration = command["configuration"] else {
                throw ScriptHostError.evaluationFailed("Cannot create a layer outside scene playback")
            }
            let prepared = try layers.prepare(configuration, workshopID: command["workshopID"] as? String)
            let node = prepared.node
            let subset = scene.replacingNodes([node])
            let (owners, order) = Self.buildOwners(scene: subset, includeGeneral: false)
            let configs: [[String: Any]]
            do {
                configs = try scriptHost.configureScene(subset, owners: owners, puppetModels: puppetModels,
                    textureAnimations: textureAnimations, textLayouts: textLayouts, publishBindings: false, context: context)
                // Registration must be serializable before publishing the node.
                _ = try JSONSerialization.data(withJSONObject: configs)
            } catch {
                scriptHost.removeSceneLayers([node.id])
                throw error
            }
            layers.insert(prepared)
            pendingSettings.append(contentsOf: order.flatMap { id in
                guard let owner = owners[id] else { return [UserSettingDescriptor]() }
                return owner.settings.keys.sorted().compactMap { name in
                    guard let setting = owner.settings[name], setting.value?.kind == .scripted else { return nil }
                    return setting
                }
            })
            return ["owners": configs, "id": "scene.node.\(node.id.rawValue)"]
        }
        guard let key = command["id"] as? String, key.hasPrefix("scene.node."),
              let raw = Int(key.dropFirst("scene.node.".count)) else {
            throw ScriptHostError.invalidJSONResult("Invalid layer reference")
        }
        let id = NodeID(rawValue: raw)
        switch command["action"] as? String {
        case "configuration": return ["configuration": try layers.initialConfiguration(for: id) ?? NSNull()]
        case "destroy": return ["result": layers.destroy(id)]
        case "sort":
            guard let index = command["index"] as? Double, index.isFinite else { return ["result": false] }
            return ["result": layers.sort(id, at: Int(min(max(index, 0), Double(scene.nodes.count))))]
        default: throw ScriptHostError.invalidJSONResult("Unknown layer operation")
        }
    }

    func shutdown() {
        scriptHost.shutdown()
        removedThisFrame = Set(scene.nodes.map(\.id))
        scriptHost.removeSceneLayers(removedThisFrame)
        layers.reset()
        scriptedSettings = initialScriptedSettings
        pendingSettings.removeAll()
        let (owners, _) = Self.buildOwners(scene: scene)
        do {
            try scriptHost.configureScene(scene, owners: owners, puppetModels: puppetModels,
                textureAnimations: textureAnimations, textLayouts: textLayouts)
        } catch { scriptHost.reportFailure(error, instanceID: "scene-bindings") }
        initialized = false
    }

    private static func buildOwners(scene: SceneDescription, includeGeneral: Bool = true) -> (owners: [String: SceneScriptOwner], order: [String]) {
        var owners: [String: SceneScriptOwner] = [:]
        var order: [String] = []
        func addOwner(_ owner: SceneScriptOwner) {
            if owners[owner.id] == nil { order.append(owner.id) }
            owners[owner.id] = owner
        }

        if includeGeneral, let graph = scene.scene {
            let cameraSettings: [String: UserSettingDescriptor?] = [
                "clearcolor": graph.clearColor,
                "zoom": graph.camera.zoom,
                "bloom": graph.camera.bloom.enabled,
                "bloomstrength": graph.camera.bloom.strength,
                "bloomthreshold": graph.camera.bloom.threshold,
                "cameraparallax": graph.camera.parallax.enabled,
                "cameraparallaxamount": graph.camera.parallax.amount,
                "cameraparallaxdelay": graph.camera.parallax.delay,
                "cameraparallaxmouseinfluence": graph.camera.parallax.mouseInfluence,
                "camerashake": graph.camera.shake.enabled,
                "camerashakeamplitude": graph.camera.shake.amplitude,
                "camerashakeroughness": graph.camera.shake.roughness,
                "camerashakespeed": graph.camera.shake.speed,
            ]
            addOwner(SceneScriptOwner(
                id: "scene.general",
                settings: compactSettingMap(cameraSettings)
            ))
        }

        for node in scene.nodes {
            let ownerID = "scene.node.\(node.id.rawValue)"
            var settings: [String: UserSettingDescriptor?] = [
                "origin": node.origin,
            ]

            if let group = node.group {
                settings["scale"] = group.scale
                settings["angles"] = group.angles
                settings["visible"] = group.visible
            }

            if let image = node.image {
                settings["alignment"] = UserSettingDescriptor(
                    value: DynamicValueDescriptor(kind: .static, value: .string(image.alignment)),
                    runtimeKey: "\(ownerID).alignment")
                settings["scale"] = image.scale
                settings["angles"] = image.angles
                settings["visible"] = image.visible
                settings["alpha"] = image.alpha
                settings["color"] = image.color
                settings["parallaxDepth"] = image.parallaxDepth
            }
            if let sound = node.sound {
                settings["volume"] = sound.volumeSetting
            }
            if let light = node.light {
                settings["visible"] = light.visible
                settings["angles"] = light.angles
                settings["scale"] = light.scale
                settings["color"] = light.color
                settings["intensity"] = light.intensity
                settings["radius"] = light.radius
                settings["exponent"] = light.exponent
                settings["length"] = light.length
                settings["controlpoint"] = light.controlPoint
                settings["innercone"] = light.innerCone
                settings["outercone"] = light.outerCone
            }
            var instanceOwner: SceneScriptOwner?
            if let particle = node.particle {
                settings["scale"] = particle.scale
                settings["angles"] = particle.angles
                settings["visible"] = particle.visible
                settings["parallaxDepth"] = particle.parallaxDepth
                let id = "\(ownerID).instanceoverride"
                var instanceSettings = compactSettingMap([
                    "enabled": particle.instanceOverride.enabled,
                    "alpha": particle.instanceOverride.alpha,
                    "size": particle.instanceOverride.size,
                    "lifetime": particle.instanceOverride.lifetime,
                    "rate": particle.instanceOverride.rate,
                    "speed": particle.instanceOverride.speed,
                    "count": particle.instanceOverride.count,
                    "color": particle.instanceOverride.color,
                    "colorn": particle.instanceOverride.colorn,
                ])
                for point in particle.instanceControlPoints {
                    let property = "controlpoint\(point.id)"
                    instanceSettings[property] = point.offsetProperty(runtimeKey: "\(id).\(property)")
                }
                instanceOwner = SceneScriptOwner(id: id, settings: instanceSettings, layerID: ownerID)
            }
            if let text = node.text {
                settings["scale"] = text.scale
                settings["angles"] = text.angles
                settings["visible"] = text.visible
                settings["alpha"] = text.alpha
                settings["color"] = text.color
                settings["text"] = text.content
                settings["backgroundcolor"] = text.backgroundColor
                settings["parallaxDepth"] = text.parallaxDepth
                settings["pointsize"] = text.pointSize
                for (key, setting) in text.resolvedStyleSettings(ownerID: ownerID) { settings[key] = setting }
            }

            addOwner(SceneScriptOwner(id: ownerID, settings: compactSettingMap(settings)))
            if let instanceOwner { addOwner(instanceOwner) }

            for (index, animation) in (node.image?.animationLayers ?? []).enumerated() {
                let id = "\(ownerID).animation.\(index)"
                addOwner(SceneScriptOwner(id: id, settings: compactSettingMap([
                    "rate": animation.rateSetting, "blend": animation.blendSetting, "visible": animation.visible,
                ]), layerID: ownerID))
            }

            func addMaterial(_ material: MaterialDescriptor?, id: String) {
                guard let material else { return }
                for (index, pass) in material.passes.enumerated() {
                    let id = "\(id).pass.\(index)"
                    addOwner(SceneScriptOwner(id: id, settings: pass.constants, layerID: ownerID))
                }
            }
            addMaterial(node.image?.model?.material, id: "\(ownerID).material")
            for (index, material) in (node.image?.model?.meshMaterials ?? []).enumerated() where index > 0 {
                addMaterial(material, id: "\(ownerID).mesh.\(index).material")
            }
            for (index, effect) in (node.image?.effects ?? node.text?.effects ?? []).enumerated() {
                let id = "\(ownerID).effect.\(index)"
                addOwner(SceneScriptOwner(id: id, settings: compactSettingMap(["visible": effect.visible]), layerID: ownerID))
                for (pass, material) in (effect.effect?.passes ?? []).enumerated() {
                    addMaterial(material.material, id: "\(id).material.\(pass)")
                }
                for (pass, override) in effect.passOverrides.enumerated() {
                    let id = "\(id).override.\(pass)"
                    addOwner(SceneScriptOwner(id: id, settings: override.constants, layerID: ownerID))
                }
            }
            func addParticle(_ particle: ParticleDescriptor, id: String) {
                addMaterial(particle.material?.material, id: "\(id).material")
                for (index, initializer) in particle.initializers.enumerated() {
                    let id = "\(id).initializer.\(index)"
                    addOwner(SceneScriptOwner(id: id, settings: initializer.parameters, layerID: ownerID))
                }
                for (index, operation) in particle.operators.enumerated() {
                    let id = "\(id).operator.\(index)"
                    addOwner(SceneScriptOwner(id: id, settings: operation.parameters, layerID: ownerID))
                }
                for (index, child) in particle.children.enumerated() {
                    if let nested = child.particle.first { addParticle(nested, id: "\(id).child.\(index)") }
                }
            }
            if let particle = node.particle { addParticle(particle, id: "\(ownerID).particle") }
        }

        return (owners, order)
    }

    private static func compactSettingMap(_ source: [String: UserSettingDescriptor?]) -> [String: UserSettingDescriptor] {
        source.reduce(into: [String: UserSettingDescriptor]()) { result, entry in
            if let setting = entry.value {
                result[entry.key] = setting
            }
        }
    }
}
