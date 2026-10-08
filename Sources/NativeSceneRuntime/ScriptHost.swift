import CScriptHost
import Foundation
import NativeSceneCore
import simd

public enum ScriptHostError: LocalizedError {
    case evaluationFailed(String)
    case invalidUTF8Result
    case invalidJSONResult(String)

    public var errorDescription: String? {
        switch self {
        case .evaluationFailed(let message):
            return message
        case .invalidUTF8Result:
            return "QuickJS host returned invalid UTF-8"
        case .invalidJSONResult(let message):
            return "QuickJS host returned invalid JSON: \(message)"
        }
    }
}

public enum SceneScriptCallback: String, Sendable {
    case initialize = "init"
    case applyUserProperties
    case destroy
}

public struct SceneScriptEngineState: Equatable, Sendable {
    public let runtime: Double
    public let screenResolution: RuntimeVector2
    public let canvasSize: RuntimeVector2
    public let frametime: Double
    public let frameIndex: UInt64?
    public let isPaused: Bool

    public init(runtime: Double, screenResolution: RuntimeVector2, canvasSize: RuntimeVector2? = nil, frametime: Double = 1.0 / 60.0, frameIndex: UInt64? = nil, isPaused: Bool = false) {
        self.runtime = runtime
        self.screenResolution = screenResolution
        self.canvasSize = canvasSize ?? screenResolution
        self.frametime = frametime
        self.frameIndex = frameIndex
        self.isPaused = isPaused
    }
}

public struct SceneScriptCursorEvent: Equatable, Sendable {
    public let position: RuntimeVector2
    public let worldPosition: RuntimeVector2
    public let screenPosition: RuntimeVector2
    public let leftDown: Bool
}

public struct SceneScriptInputState: Equatable, Sendable {
    public let cursorPosition: RuntimeVector2?
    public let cursorWorldPosition: RuntimeVector2?
    public let cursorScreenPosition: RuntimeVector2?
    public let cursorLeftDown: Bool
    public let cursorEvents: [SceneScriptCursorEvent]
    public let resetCursorEvents: Bool

    public init(cursorPosition: RuntimeVector2?, cursorWorldPosition: RuntimeVector2? = nil,
                cursorScreenPosition: RuntimeVector2? = nil, cursorLeftDown: Bool = false,
                cursorEvents: [SceneScriptCursorEvent] = [], resetCursorEvents: Bool = false) {
        self.cursorPosition = cursorPosition
        self.cursorWorldPosition = cursorWorldPosition
        self.cursorScreenPosition = cursorScreenPosition
        self.cursorLeftDown = cursorLeftDown
        self.cursorEvents = cursorEvents
        self.resetCursorEvents = resetCursorEvents
    }
}

/// Immutable host input. Script objects are still copied by the native bridge.
final class SceneScriptUserProperties: Equatable, Sendable {
    let values: [String: FrameValue]
    init(_ values: [String: FrameValue]) { self.values = values }
    static func == (lhs: SceneScriptUserProperties, rhs: SceneScriptUserProperties) -> Bool { lhs === rhs }
}

public final class ScriptHost: @unchecked Sendable {
    public static let shared = ScriptHost()

    private let nativeHost = we_script_host_create()
    private let lock = NSRecursiveLock()
    private let storage: SceneScriptStorage
    private var reportedFailures: Set<String> = []
    private struct SceneBinding {
        let ownerID: String
        let property: String
        let key: String
        let setting: UserSettingDescriptor
        var usesDegrees: Bool { property == "angles" }
    }
    private var sceneBindings: [String: SceneBinding] = [:]
    private var descriptorBindings: [ObjectIdentifier: SceneBinding] = [:]
    private var sceneMutations: [String: (value: FrameValue, frame: UInt64)] = [:]
    private struct ParentOverride {
        let parent: NodeID?
        let attachment: AttachmentReference?
    }
    private var parentOverrides: [NodeID: ParentOverride] = [:]
    private var publishedSceneValues: [String: FrameValue] = [:]
    private var sceneFrame: UInt64 = 0
    private var hasSceneBindings = false
    private var valueScriptUpdates: [String: Bool] = [:]
    private var sceneAnimations: [String: ScenePropertyAnimation] = [:]
    private var skeletalAnimations: [String: SceneSkeletalAnimation] = [:]
    private var attachmentModels: [String: PuppetModel] = [:]
    private var textLayouts: TextLayoutEngine?
    private var textNodeIDs: [String: NodeID] = [:]
    private var attachmentAnimationIDs: [String: [Int]] = [:]
    private var sceneTime: Double = 0
    private var textureAnimations: [String: SceneTextureAnimation] = [:]
    private var videoTextures: [String: SceneVideoTexture] = [:]
    private var videoTexturePaths: [String: String] = [:]
    private var videoTextureLibrary: SceneVideoTextureLibrary?
    private var animationDescriptors: [ObjectIdentifier: String] = [:]
    private struct EvaluationInputs: Equatable {
        let source: String
        let baseValue: FrameValue
        let properties: [String: FrameValue]
        let engine: SceneScriptEngineState?
        let input: SceneScriptInputState?
        let audioSpectrum: [Float]
        let userProperties: SceneScriptUserProperties
        let bindingKey: String?
    }
    private var cachedEvaluationFrame: UInt64?
    private var cachedEvaluations: [String: (inputs: EvaluationInputs, value: FrameValue)] = [:]
    // Script properties rarely change between frames; reuse their encoding.
    private var cachedPropertiesJSON: [String: (properties: [String: FrameValue], json: String)] = [:]
    private var cachedTimeOfDay: (frame: UInt64, value: Double)?
    private var initializingScene = false
    private var loadingSceneModules = false
    private var mediaState = SceneMediaState()
    private var mediaObject = SceneMediaState().scriptObject
    private var cachedUserProperties: SceneScriptUserProperties?
    private var lastUserPropertiesArgument: SceneScriptUserProperties?
    private var canonicalUserProperties: SceneScriptUserProperties?
    private var cachedInputJSON: (input: SceneScriptInputState?, json: String)?
    private struct EngineSnapshotKey: Equatable {
        let engine: SceneScriptEngineState?
        let audio: [Float]
    }
    private var cachedEngineSnapshot: EngineSnapshotKey?
    private var userPropertiesRevision: UInt64 = 0
    private struct SoundTransport {
        var state: FrameSoundTransportState
        var runID: UInt64
        var gain: Float
    }
    private var soundTransports: [String: SoundTransport] = [:]
    private var particleTransports: [String: ParticleTransportState] = [:]
    var sceneLayerRequest: (([String: Any]) throws -> [String: Any])?

    public init(storage: SceneScriptStorage? = nil) {
        // An in-memory backend cannot fail to initialize.
        self.storage = storage ?? (try! SceneScriptStorage())
        we_script_host_set_storage_handler(nativeHost, Unmanaged.passUnretained(self.storage).toOpaque()) { opaque, request in
            var result = WEScriptHostEvaluation()
            guard let opaque, let request else { return result }
            do {
                let storage = Unmanaged<SceneScriptStorage>.fromOpaque(opaque).takeUnretainedValue()
                result.result_json = try storage.request(String(cString: request)).flatMap { strdup($0) }
            } catch { result.error_message = strdup(error.localizedDescription) }
            return result
        }
        we_script_host_set_scene_layer_handler(nativeHost, Unmanaged.passUnretained(self).toOpaque()) { opaque, request in
            var result = WEScriptHostEvaluation()
            guard let opaque, let request else { return result }
            do {
                let host = Unmanaged<ScriptHost>.fromOpaque(opaque).takeUnretainedValue()
                guard let handler = host.sceneLayerRequest,
                      let command = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] else {
                    throw ScriptHostError.invalidJSONResult("Scene layer request is unavailable")
                }
                result.result_json = strdup(try host.jsonString(for: handler(command)))
            } catch { result.error_message = strdup(error.localizedDescription) }
            return result
        }
    }

    @discardableResult
    func configureScene(_ scene: SceneDescription, owners: [String: SceneScriptOwner], puppetModels: PuppetModelLibrary,
                        textureAnimations textureLibrary: TextureAnimationLibrary, textLayouts: TextLayoutEngine,
                        publishBindings: Bool = true, context: PropertyEvaluationContext? = nil) throws -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        self.textLayouts = textLayouts
        self.textNodeIDs.merge(Dictionary(uniqueKeysWithValues: scene.nodes.compactMap { node in
            node.text.map { _ in ("scene.node.\(node.id.rawValue)", node.id) }
        }), uniquingKeysWith: { _, added in added })
        we_script_host_set_text_layout_handler(nativeHost, Unmanaged.passUnretained(self).toOpaque()) { opaque, request in
            var result = WEScriptHostEvaluation()
            guard let opaque, let request else { return result }
            do {
                let host = Unmanaged<ScriptHost>.fromOpaque(opaque).takeUnretainedValue()
                result.result_json = strdup(try host.textSize(String(cString: request)))
            } catch { result.error_message = strdup(error.localizedDescription) }
            return result
        }
        we_script_host_set_attachment_handler(nativeHost, Unmanaged.passUnretained(self).toOpaque()) { opaque, request in
            var result = WEScriptHostEvaluation()
            guard let opaque, let request else { return result }
            do {
                let host = Unmanaged<ScriptHost>.fromOpaque(opaque).takeUnretainedValue()
                result.result_json = strdup(try host.attachmentMatrix(String(cString: request)))
            } catch { result.error_message = strdup(error.localizedDescription) }
            return result
        }
        we_script_host_set_animation_handler(nativeHost, Unmanaged.passUnretained(self).toOpaque()) { opaque, request in
            var result = WEScriptHostEvaluation()
            guard let opaque, let request else { return result }
            do {
                let host = Unmanaged<ScriptHost>.fromOpaque(opaque).takeUnretainedValue()
                result.result_json = strdup(try host.applyAnimationRequest(String(cString: request)))
            } catch { result.error_message = strdup(error.localizedDescription) }
            return result
        }
        let nodes = Dictionary(uniqueKeysWithValues: scene.nodes.map { ("scene.node.\($0.id.rawValue)", $0) })
        let nodeIDs = scene.nodes.map { "scene.node.\($0.id.rawValue)" }
        let nodeIDSet = Set(nodeIDs)
        if videoTextureLibrary == nil { videoTextureLibrary = SceneVideoTextureLibrary(assets: textureLibrary) }
        videoTexturePaths.merge(Dictionary(uniqueKeysWithValues: scene.nodes.compactMap { node in
            guard let path = node.image?.model?.material?.passes.first?.textures.first(where: { $0.slot == 0 })?.path else { return nil }
            return ("scene.node.\(node.id.rawValue)", path)
        }), uniquingKeysWith: { _, added in added })
        soundTransports.merge(Dictionary(uniqueKeysWithValues: scene.nodes.compactMap { node in
            guard let sound = node.sound else { return nil }
            let id = "scene.node.\(node.id.rawValue)"
            return (id, SoundTransport(state: sound.startSilent ? .stopped : .playing, runID: sound.startSilent ? 0 : 1,
                                       gain: Float(min(max(sound.volume, 0), 1))))
        }), uniquingKeysWith: { _, added in added })
        particleTransports.merge(Dictionary(uniqueKeysWithValues: scene.nodes.compactMap { node in
            node.particle.map { ("scene.node.\(node.id.rawValue)", ParticleTransportState(particle: $0, nodeID: node.id)) }
        }), uniquingKeysWith: { _, added in added })
        var skeletalNames: [String: String] = [:]
        var skeletalLayers: [String: [String]] = [:]
        var layerEffects: [String: [String]] = [:]
        var effectNames: [String: String] = [:]
        var effectMaterials: [String: [[String]]] = [:]
        var materialViews: [String: [String: Any]] = [:]
        for (id, node) in nodes {
            if node.image != nil || node.text != nil { layerEffects[id] = [] }
            for (index, effect) in (node.image?.effects ?? node.text?.effects ?? []).enumerated() {
                let effectID = "\(id).effect.\(index)"
                layerEffects[id, default: []].append(effectID)
                effectNames[effectID] = effect.name
                var materials: [[String]] = []
                for (passIndex, pass) in (effect.effect?.passes ?? []).enumerated() {
                    guard let material = pass.material else { continue }
                    // Match the renderer: command passes do not consume an override.
                    let overrideID = "\(effectID).override.\(materials.count)"
                    var ids = owners[overrideID] == nil ? [] : [overrideID]
                    ids += material.passes.indices.map { "\(effectID).material.\(passIndex).pass.\($0)" }
                    for ownerID in ids {
                        materialViews[ownerID] = ["effect": effectID, "index": materials.count]
                    }
                    materials.append(ids)
                }
                effectMaterials[effectID] = materials
            }
            if let path = node.image?.model?.material?.passes.first?.textures.first(where: { $0.slot == 0 })?.path,
               let animation = textureLibrary.animation(for: path) {
                textureAnimations[id] = SceneTextureAnimation(descriptor: animation)
            }
            let model = node.image?.model
            let path = model?.puppet ?? model.flatMap { $0.filename.lowercased().hasSuffix(".mdl") ? $0.filename : nil }
            let puppet = path.flatMap { puppetModels.model(for: $0) }
            if let puppet, !puppet.attachments.isEmpty { attachmentModels[id] = puppet }
            guard let animations = node.image?.animationLayers, !animations.isEmpty else { continue }
            attachmentAnimationIDs[id] = animations.map(\.animation)
            for (index, animation) in animations.enumerated() {
                let ownerID = "\(id).animation.\(index)"
                skeletalNames[ownerID] = animation.name ?? ""
                skeletalLayers[id, default: []].append(ownerID)
                skeletalAnimations[ownerID] = SceneSkeletalAnimation(clip: puppet?.animation(withID: animation.animation))
            }
        }
        let orderedIDs = ["scene.general"] + nodeIDs + owners.keys.filter { $0 != "scene.general" && !nodeIDSet.contains($0) }.sorted()
        let registrationEvaluator = context.map { context in
            PropertyEvaluator(scene: scene, context: PropertyEvaluationContext(
                elapsedTime: context.elapsedTime, deltaTime: context.deltaTime, frameIndex: context.frameIndex,
                propertyOverrides: context.propertyOverrides, runtimeOverrides: context.runtimeOverrides,
                scriptHost: self, scriptsEnabled: false))
        }
        var configs: [[String: Any]] = []
        for id in orderedIDs {
            guard let owner = owners[id] else { continue }
            var values: [String: Any] = [:]
            var keys: [String: String] = [:]
            var animations: [String: [String: Any]] = [:]
            for (property, setting) in owner.settings {
                let key = setting.runtimeKey ?? "\(id).\(property)"
                let binding = SceneBinding(ownerID: id, property: property, key: key, setting: setting)
                sceneBindings[key] = binding
                if let descriptor = setting.value { descriptorBindings[ObjectIdentifier(descriptor)] = binding }
                var animated = setting.value
                while let descriptor = animated {
                    if let animation = descriptor.animation {
                        sceneAnimations[key] = ScenePropertyAnimation(animation)
                        animationDescriptors[ObjectIdentifier(descriptor)] = key
                        animations[property] = ["key": key, "name": animation.name ?? "",
                            "fps": animation.fps, "length": animation.length, "mode": animation.mode.rawValue,
                            "state": sceneAnimations[key]!.snapshot]
                        break
                    }
                    animated = descriptor.baseValue
                }
                let descriptor = setting.value?.baseValue ?? setting.value
                let value = registrationEvaluator?.evaluate(setting)?.value
                    ?? descriptor.map { FrameValue(sceneValue: $0.value) } ?? .null
                values[property] = jsValueObject(for: sceneValue(value, binding: binding, toScript: true))
                keys[property] = key
            }
            if let node = nodes[id] {
                values["name"] = node.name
                if let image = node.image {
                    values["alignment"] = image.alignment
                    keys["alignment"] = "\(id).alignment"
                    let intrinsic = [Double(image.model?.width ?? 0), Double(image.model?.height ?? 0)]
                    let size = (0..<2).map { image.size.indices.contains($0) && image.size[$0] >= 0 ? image.size[$0] : intrinsic[$0] }
                    values["size"] = jsValueObject(for: .vec2(size))
                }
            }
            let soundTransport = soundTransports[id].map { transport in
                ["key": id, "state": transport.state.rawValue, "runID": transport.runID, "gain": transport.gain] as [String: Any]
            }
            if soundTransport != nil { values.removeValue(forKey: "volume"); keys.removeValue(forKey: "volume") }
            if let name = effectNames[id] { values["name"] = name }
            configs.append([
                "id": id, "layer": nodes[id] != nil, "text": nodes[id]?.text != nil,
                "cursorEnabled": nodes[id]?.solid != false && (nodes[id]?.image != nil || nodes[id]?.text != nil)
                    && scene.scene?.camera.projection.isPerspective != true,
                "layerID": owner.layerID as Any? ?? NSNull(),
                "particleInstance": nodes[id]?.particle.map { _ in "\(id).instanceoverride" } as Any? ?? NSNull(),
                "parent": nodes[id]?.parentId.map { "scene.node.\($0.rawValue)" } as Any? ?? NSNull(),
                "attachment": nodes[id]?.attachment.map { reference -> Any in
                    switch reference { case .name(let name): return name; case .index(let index): return index }
                } ?? NSNull(),
                "attachments": attachmentModels[id]?.attachments.map(\.name) ?? [],
                "textureAnimation": textureAnimations[id].map { animation in
                    ["key": id, "frameCount": animation.descriptor.frames.count, "duration": animation.descriptor.duration,
                     "state": animation.snapshot] as [String: Any]
                } as Any? ?? NSNull(),
                "values": values, "keys": keys, "animations": animations,
                "effects": layerEffects[id] as Any? ?? NSNull(),
                "materials": effectMaterials[id] as Any? ?? NSNull(),
                "materialView": materialViews[id] as Any? ?? NSNull(),
                "soundTransport": soundTransport as Any? ?? NSNull(),
                "particleTransport": particleTransports[id].map { _ in id } as Any? ?? NSNull(),
                "skeletalName": skeletalNames[id] as Any? ?? NSNull(),
                "skeletalPlayback": skeletalAnimations[id].map { animation in
                    ["key": id, "fps": animation.clip?.fps ?? 0,
                     "frameCount": animation.clip?.frameCount ?? 0,
                     "duration": animation.clip?.duration ?? 0, "state": animation.snapshot] as [String: Any]
                } as Any? ?? NSNull(),
                "skeletalLayers": skeletalLayers[id] ?? [],
            ])
        }
        if publishBindings {
            try exchangeScene(["owners": configs], source: SceneLayerBindings.source)
            hasSceneBindings = true
        }
        return configs
    }

    private func textSize(_ json: String) throws -> String {
        struct Request: Decodable { let id: String; let configuration: TextLayoutConfiguration }
        let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
        guard let nodeID = textNodeIDs[request.id], let textLayouts else {
            throw ScriptHostError.evaluationFailed("Unknown text layer")
        }
        let layout = try textLayouts.layout(nodeID: nodeID, configuration: request.configuration)
        return String(decoding: try JSONEncoder().encode(["x": layout?.width ?? 0, "y": layout?.height ?? 0]), as: UTF8.self)
    }

    private func attachmentMatrix(_ json: String) throws -> String {
        struct Layer: Decodable { let frame: Double; let visible: Bool; let blend: Double; let rate: Double }
        struct Request: Decodable { let id: String; let index: Int; let layers: [Layer] }
        let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
        guard let model = attachmentModels[request.id], model.attachments.indices.contains(request.index) else {
            throw ScriptHostError.evaluationFailed("Unknown puppet attachment")
        }
        let active = request.layers.firstIndex { $0.visible && $0.blend > 0 }
        let bones: [simd_float4x4]
        if let active {
            let layer = request.layers[active]
            let ids = attachmentAnimationIDs[request.id] ?? []
            bones = model.boneTransforms(at: sceneTime, animationID: ids.indices.contains(active) ? ids[active] : nil,
                                         rate: layer.rate, blend: layer.blend, frame: layer.frame)
        } else if !request.layers.isEmpty {
            bones = model.bindWorldTransforms
        } else {
            bones = model.boneTransforms(at: sceneTime, animationID: nil, rate: 1)
        }
        let attachment = model.attachments[request.index]
        let bone = bones.indices.contains(attachment.bone) ? bones[attachment.bone] : matrix_identity_float4x4
        let matrix = bone * attachment.localTransform
        let values = (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
        return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    func beginSceneFrame(_ context: PropertyEvaluationContext, scene: SceneDescription) throws {
        lock.lock()
        defer { lock.unlock() }
        guard hasSceneBindings else { return }
        sceneFrame = context.frameIndex
        sceneTime = context.elapsedTime
        for id in textureAnimations.keys { textureAnimations[id]?.advance(context.deltaTime, sharedTime: sceneTime) }
        if !textureAnimations.isEmpty { try exchangeScene(["textureAnimations": textureAnimations.mapValues(\.snapshot)]) }
        var videoEnded: [String: Double] = [:]
        for id in videoTextures.keys {
            let count = videoTextures[id]?.advance(context.deltaTime) ?? 0
            if count > 0 { videoEnded[id] = count }
        }
        if !videoTextures.isEmpty {
            try exchangeScene(["videoTextures": videoTextures.mapValues(\.snapshot), "videoEnded": videoEnded])
        }
        for key in sceneAnimations.keys { sceneAnimations[key]?.advance(context.deltaTime) }
        if !sceneAnimations.isEmpty {
            try exchangeScene(["animations": sceneAnimations.mapValues(\.snapshot)])
        }
        let evaluator = PropertyEvaluator(scene: scene, context: PropertyEvaluationContext(
            elapsedTime: context.elapsedTime, deltaTime: context.deltaTime, frameIndex: context.frameIndex,
            propertyOverrides: context.propertyOverrides, runtimeOverrides: context.runtimeOverrides,
            scriptHost: self, scriptsEnabled: false
        ))
        var values: [String: [String: Any]] = [:]
        for binding in sceneBindings.values {
            // Until a scripted property runs, retained layer references see its
            // last result. Static bindings and timelines refresh every frame.
            if binding.setting.value?.kind == .scripted, publishedSceneValues[binding.key] != nil { continue }
            guard let value = evaluator.evaluate(binding.setting)?.value else { continue }
            guard publishedSceneValues[binding.key] != value else { continue }
            values[binding.ownerID, default: [:]][binding.property] = jsValueObject(for: sceneValue(value, binding: binding, toScript: true))
            publishedSceneValues[binding.key] = value
            updateSoundGain(value, binding: binding)
        }
        if !values.isEmpty { try exchangeScene(["values": values]) }
        // Integrate each layer independently. Multiplying all elapsed time by
        // a newly assigned rate jumps to an unrelated point in the animation.
        var ended: [String: Double] = [:]
        for id in skeletalAnimations.keys {
            let rate = publishedSceneValues["\(id).rate"]?.doubleValue ?? 1
            let count = skeletalAnimations[id]?.advance(context.deltaTime, rate: rate) ?? 0
            if count > 0 { ended[id] = count }
        }
        if !skeletalAnimations.isEmpty {
            try exchangeScene(["skeletalAnimations": skeletalAnimations.mapValues(\.snapshot), "skeletalEnded": ended])
        }
    }

    func skeletalAnimationFrame(nodeID: NodeID, layerIndex: Int) -> (frame: Double, progress: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let animation = skeletalAnimations["scene.node.\(nodeID.rawValue).animation.\(layerIndex)"],
              let clip = animation.clip else { return nil }
        return (animation.frame, clip.frameCount > 0 ? animation.frame / Double(clip.frameCount) : 0)
    }

    func publishedSceneValue(for setting: UserSettingDescriptor) -> FrameValue? {
        lock.lock(); defer { lock.unlock() }
        return binding(for: setting).flatMap { publishedSceneValues[$0.key] }
    }

    func sceneOverride(for setting: UserSettingDescriptor) -> FrameValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let binding = binding(for: setting), let mutation = sceneMutations[binding.key] else { return nil }
        // An active value script keeps executing after another script writes
        // its property. Writes to ordinary properties persist until replaced.
        if setting.value?.kind == .scripted, valueScriptUpdates[binding.key] == true,
           mutation.frame != sceneFrame { return nil }
        return mutation.value
    }

    func animationValue(for descriptor: DynamicValueDescriptor, base: FrameValue) -> FrameValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = animationDescriptors[ObjectIdentifier(descriptor)], let animation = sceneAnimations[key] else { return nil }
        return PropertyAnimationEvaluator.evaluate(animation.descriptor, base: base, frame: animation.frame)
    }

    private func applyAnimationRequest(_ request: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let values = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              let key = values["key"] as? String else {
            throw ScriptHostError.invalidJSONResult("invalid animation request")
        }
        if values["kind"] as? String == "particle", var transport = particleTransports[key] {
            switch values["action"] as? String ?? "" {
            case "play":
                if transport.mode == .stopped || !transport.hasPendingEmission { transport.reset() }
                transport.mode = .playing
            case "pause": if transport.mode == .playing { transport.mode = .paused }
            case "stop":
                if transport.mode != .stopped { transport.reset() }
                transport.mode = .stopped
            case "isPlaying": break
            default: throw ScriptHostError.invalidJSONResult("unknown particle action")
            }
            particleTransports[key] = transport
            return try jsonString(for: ["playing": transport.isPlaying])
        }
        if values["kind"] as? String == "sound", var transport = soundTransports[key] {
            let action = values["action"] as? String ?? ""
            switch action {
            case "play":
                if transport.state == .failed { break }
                if transport.state == .stopped { transport.runID &+= 1 }
                transport.state = .playing
            case "pause": if transport.state == .playing { transport.state = .paused }
            case "stop": if transport.state != .failed { transport.state = .stopped }
            case "volume":
                if let volume = values["volume"] as? Double, volume.isFinite { transport.gain = Float(min(max(volume, 0), 1)) }
            default: throw ScriptHostError.invalidJSONResult("unknown sound action")
            }
            soundTransports[key] = transport
            if action == "volume", let binding = sceneBindings["\(key).volume"] {
                let value = FrameValue.double(Double(transport.gain))
                sceneMutations[binding.key] = (value, sceneFrame)
                // Match ordinary layer setters: a later value-script result
                // must be compared with the value this setter actually exposed.
                publishedSceneValues[binding.key] = value
            }
            return try jsonString(for: ["state": ["state": transport.state.rawValue, "volume": transport.gain]])
        }
        if values["kind"] as? String == "video" {
            if videoTextures[key] == nil, values["action"] as? String == "resolve",
               let path = videoTexturePaths[key], let duration = videoTextureLibrary?.duration(for: path) {
                videoTextures[key] = SceneVideoTexture(duration: duration,
                    time: sceneTime.truncatingRemainder(dividingBy: duration))
            }
            guard var video = videoTextures[key] else { return try jsonString(for: ["state": NSNull()]) }
            video.apply(values)
            videoTextures[key] = video
            return try jsonString(for: ["state": video.snapshot])
        }
        if values["kind"] as? String == "texture", var animation = textureAnimations[key] {
            animation.apply(values, sharedTime: sceneTime)
            textureAnimations[key] = animation
            return try jsonString(for: ["state": animation.snapshot])
        }
        if values["kind"] as? String == "skeletal", var animation = skeletalAnimations[key] {
            animation.apply(action: values["action"] as? String ?? "", frame: values["frame"] as? Double,
                            rate: values["rate"] as? Double ?? 1)
            skeletalAnimations[key] = animation
            return try jsonString(for: ["state": animation.snapshot])
        }
        guard var animation = sceneAnimations[key] else {
            throw ScriptHostError.invalidJSONResult("unknown property animation")
        }
        let previousFrame = animation.frame
        animation.apply(values)
        sceneAnimations[key] = animation
        var response: [String: Any] = ["state": animation.snapshot]
        if animation.frame != previousFrame || values["sample"] as? Bool == true, let binding = sceneBindings[key] {
            let descriptor = binding.setting.value?.baseValue ?? binding.setting.value
            if let descriptor {
                let value = PropertyAnimationEvaluator.evaluate(animation.descriptor,
                    base: FrameValue(sceneValue: descriptor.value), frame: animation.frame)
                publishedSceneValues[key] = value
                sceneMutations[key] = nil
                response["value"] = jsValueObject(for: sceneValue(value, binding: binding, toScript: true))
            }
        }
        return try jsonString(for: response)
    }

    func particleTransportSnapshot(nodeID: NodeID) -> ParticleTransportState? {
        lock.lock(); defer { lock.unlock() }
        return particleTransports["scene.node.\(nodeID.rawValue)"]
    }

    func updateParticlePlaybackStatus(nodeID: NodeID, hasLiveParticles: Bool, hasPendingEmission: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = "scene.node.\(nodeID.rawValue)"
        guard var transport = particleTransports[key] else { return }
        transport.hasLiveParticles = hasLiveParticles
        transport.hasPendingEmission = hasPendingEmission
        particleTransports[key] = transport
    }

    func soundTransportSnapshot() -> [FrameSoundTransport] {
        lock.lock(); defer { lock.unlock() }
        return soundTransports.compactMap { key, transport in
            guard let rawID = Int(key.replacingOccurrences(of: "scene.node.", with: "")) else { return nil }
            return FrameSoundTransport(nodeID: NodeID(rawValue: rawID), state: transport.state, runID: transport.runID, gain: transport.gain)
        }.sorted { $0.nodeID < $1.nodeID }
    }

    func updateSoundPlaybackStatus(nodeID: NodeID, runID: UInt64, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = "scene.node.\(nodeID.rawValue)"
        guard var transport = soundTransports[key], transport.runID == runID, transport.state == .playing else { return }
        transport.state = finished ? .stopped : .failed
        soundTransports[key] = transport
        do { try exchangeScene(["soundTransports": [key: ["state": transport.state.rawValue, "volume": transport.gain]]]) }
        catch { reportFailure(error, instanceID: key) }
    }

    func textureAnimationTime(nodeID: NodeID) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return textureAnimations["scene.node.\(nodeID.rawValue)"]?.time
    }

    func videoTextureTime(nodeID: NodeID) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return videoTextures["scene.node.\(nodeID.rawValue)"]?.time
    }

    private func updateSoundGain(_ value: FrameValue, binding: SceneBinding) {
        guard binding.property == "volume", var transport = soundTransports[binding.ownerID],
              let gain = value.doubleValue, gain.isFinite else { return }
        transport.gain = Float(min(max(gain, 0), 1))
        soundTransports[binding.ownerID] = transport
    }

    func publishSceneValue(_ value: FrameValue, for setting: UserSettingDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        guard hasSceneBindings, let binding = binding(for: setting), publishedSceneValues[binding.key] != value else { return }
        updateSoundGain(value, binding: binding)
        do {
            try exchangeScene(["values": [binding.ownerID: [binding.property: jsValueObject(for: sceneValue(value, binding: binding, toScript: true))]]])
            publishedSceneValues[binding.key] = value
        } catch { reportFailure(error, instanceID: binding.key) }
    }

    private func binding(for setting: UserSettingDescriptor) -> SceneBinding? {
        setting.runtimeKey.flatMap { sceneBindings[$0] }
            ?? setting.value.flatMap { descriptorBindings[ObjectIdentifier($0)] }
    }

    func label(for descriptor: DynamicValueDescriptor) -> String {
        lock.lock()
        defer { lock.unlock() }
        return descriptorBindings[ObjectIdentifier(descriptor)]?.key ?? String(describing: ObjectIdentifier(descriptor))
    }

    private func sceneValue(_ value: FrameValue, binding: SceneBinding, toScript: Bool) -> FrameValue {
        guard binding.usesDegrees else { return value }
        let components: [Double]
        switch value {
        case .vec3(let values): components = values
        case .ivec3(let values): components = values.map(Double.init)
        default: return value
        }
        let factor = toScript ? 180 / Double.pi : Double.pi / 180
        return .vec3(components.map { $0 * factor })
    }

    private func exchangeScene(_ command: [String: Any], source: String? = nil) throws {
        let json = try jsonString(for: command)
        let result = json.withCString { command in
            if let source { return source.withCString { we_script_host_scene_json(nativeHost, $0, command) } }
            return we_script_host_scene_json(nativeHost, nil, command)
        }
        defer { we_script_host_free_evaluation(result) }
        receiveSceneMutations(result)
        if let message = result.error_message { throw ScriptHostError.evaluationFailed(String(cString: message)) }
    }

    func removeSceneLayers(_ ids: Set<NodeID>) {
        lock.lock(); defer { lock.unlock() }
        let prefixes = ids.map { "scene.node.\($0.rawValue)" }
        func belongs(_ key: String) -> Bool { prefixes.contains { key == $0 || key.hasPrefix($0 + ".") } }
        do { try exchangeScene(["removeLayers": prefixes]) }
        catch { reportFailure(error, instanceID: "layer-destroy") }
        sceneBindings = sceneBindings.filter { !belongs($0.value.ownerID) }
        descriptorBindings = descriptorBindings.filter { !belongs($0.value.ownerID) }
        animationDescriptors = animationDescriptors.filter { !belongs($0.value) }
        sceneMutations = sceneMutations.filter { !belongs($0.key) }
        publishedSceneValues = publishedSceneValues.filter { !belongs($0.key) }
        valueScriptUpdates = valueScriptUpdates.filter { !belongs($0.key) }
        cachedEvaluations = cachedEvaluations.filter { !belongs($0.key) }
        cachedPropertiesJSON = cachedPropertiesJSON.filter { !belongs($0.key) }
        reportedFailures = reportedFailures.filter { failure in
            !prefixes.contains { failure.hasPrefix($0 + ".") || failure.hasPrefix($0 + ":") }
        }
        parentOverrides = parentOverrides.filter { !ids.contains($0.key) }
        for prefix in prefixes {
            attachmentModels[prefix] = nil; attachmentAnimationIDs[prefix] = nil
            textNodeIDs[prefix] = nil; textureAnimations[prefix] = nil
            videoTextures[prefix] = nil; videoTexturePaths[prefix] = nil
            soundTransports[prefix] = nil; particleTransports[prefix] = nil
        }
        sceneAnimations = sceneAnimations.filter { !belongs($0.key) }
        skeletalAnimations = skeletalAnimations.filter { !belongs($0.key) }
        textLayouts?.remove(nodeIDs: ids)
    }

    func imageAlignment(for node: NodeDescriptor) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let image = node.image else { return nil }
        return sceneMutations["scene.node.\(node.id.rawValue).alignment"]?.value.stringValue ?? image.alignment
    }

    private func receiveSceneMutations(_ evaluation: WEScriptHostEvaluation) {
        guard let json = evaluation.mutations_json else { return }
        do {
            let data = Data(String(cString: json).utf8)
            guard let changes = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let hierarchy = changes["__hierarchy"] as? [String: [String: Any]] {
                func nodeID(_ value: String) -> NodeID? {
                    guard value.hasPrefix("scene.node."), let raw = Int(value.dropFirst("scene.node.".count)) else { return nil }
                    return NodeID(rawValue: raw)
                }
                for (key, change) in hierarchy {
                    guard let id = nodeID(key) else { continue }
                    let parent = (change["parent"] as? String).flatMap(nodeID)
                    let attachment = (change["attachment"] as? String).map(AttachmentReference.name)
                        ?? (change["attachment"] as? Int).map(AttachmentReference.index)
                    parentOverrides[id] = ParentOverride(parent: parent, attachment: attachment)
                }
            }
            for (key, jsonValue) in changes {
                guard let binding = sceneBindings[key] else { continue }
                let value = sceneValue(try frameValue(fromUntypedJSON: jsonValue), binding: binding, toScript: false)
                sceneMutations[key] = (value, sceneFrame)
                publishedSceneValues[key] = value
            }
        } catch { reportFailure(error, instanceID: "scene-mutations") }
    }

    func parentID(for node: NodeDescriptor) -> NodeID? {
        lock.lock()
        defer { lock.unlock() }
        if let override = parentOverrides[node.id] { return override.parent }
        return node.parentId
    }

    func attachment(for node: NodeDescriptor) -> AttachmentReference? {
        lock.lock()
        defer { lock.unlock() }
        if let override = parentOverrides[node.id] { return override.attachment }
        return node.attachment
    }

    deinit { we_script_host_destroy(nativeHost) }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        we_script_host_shutdown(nativeHost)
        cachedEvaluations.removeAll()
        cachedEvaluationFrame = nil
        cachedUserProperties = nil
        lastUserPropertiesArgument = nil
        canonicalUserProperties = nil
        cachedInputJSON = nil
        cachedEngineSnapshot = nil
        valueScriptUpdates.removeAll()
    }

    func reportFailure(_ error: Error, instanceID: String) {
        lock.lock()
        defer { lock.unlock() }
        let message = error.localizedDescription
        let summary = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        if reportedFailures.insert(instanceID + ":" + summary).inserted {
            print("[NativeSceneRuntime] Script \(instanceID) evaluation failed: \(message)")
        }
    }

    /// Initialize all authored owners before dispatching their first property,
    /// media, timer or frame callbacks. Keep results out of the frame-read cache.
    func initializeSceneScripts(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = initializingScene
        initializingScene = true
        cachedEvaluations.removeAll(keepingCapacity: true)
        defer {
            initializingScene = previous
            cachedEvaluations.removeAll(keepingCapacity: true)
        }
        body()
    }

    /// Evaluate authored module bodies before lifecycle callbacks run. Results
    /// stay outside the frame-read cache because phase flags are internal.
    func loadSceneScriptModules(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = loadingSceneModules
        loadingSceneModules = true
        cachedEvaluations.removeAll(keepingCapacity: true)
        defer {
            loadingSceneModules = previous
            cachedEvaluations.removeAll(keepingCapacity: true)
        }
        body()
    }

    /// Changes are delivered in each module's own layer context on its next evaluation.
    public func updateMediaState(_ state: SceneMediaState) {
        lock.lock()
        defer { lock.unlock() }
        guard state != mediaState else { return }
        mediaState = state
        mediaObject = state.scriptObject
        cachedEngineSnapshot = nil
        cachedEvaluations.removeAll(keepingCapacity: true)
    }

    private func canonicalSnapshot(_ snapshot: SceneScriptUserProperties) -> SceneScriptUserProperties {
        if snapshot === lastUserPropertiesArgument, let canonicalUserProperties { return canonicalUserProperties }
        lastUserPropertiesArgument = snapshot
        if let canonicalUserProperties, canonicalUserProperties.values == snapshot.values { return canonicalUserProperties }
        canonicalUserProperties = snapshot
        return snapshot
    }

    private func updateEngineSnapshot(_ engine: SceneScriptEngineState?, audioSpectrum: [Float]) throws {
        let key = EngineSnapshotKey(engine: engine, audio: audioSpectrum)
        guard cachedEngineSnapshot != key else { return }
        var snapshot: [String: Any] = ["__media": mediaObject]
        if let engine {
            snapshot["runtime"] = engine.runtime
            snapshot["frametime"] = engine.frametime
            snapshot["frameIndex"] = engine.frameIndex.map(String.init)
            snapshot["isPaused"] = engine.isPaused
            snapshot["screenResolution"] = jsValueObject(
                for: .vec2([Double(engine.screenResolution.x), Double(engine.screenResolution.y)])
            )
            snapshot["canvasSize"] = jsValueObject(for: .vec2([Double(engine.canvasSize.x), Double(engine.canvasSize.y)]))
        }
        // WE band layout: first half left channel, second half right.
        let half = audioSpectrum.count / 2
        snapshot["audioLeft"] = audioSpectrum.prefix(half).map(Double.init)
        snapshot["audioRight"] = audioSpectrum.suffix(from: half).map(Double.init)
        let json = try jsonString(for: snapshot)
        let result = json.withCString { we_script_host_set_engine_snapshot_json(nativeHost, $0) }
        defer { we_script_host_free_evaluation(result) }
        if let message = result.error_message {
            throw ScriptHostError.evaluationFailed(String(cString: message))
        }
        cachedEngineSnapshot = key
    }

    private func inputJSONString(_ input: SceneScriptInputState?) throws -> String {
        if let cachedInputJSON, cachedInputJSON.input == input { return cachedInputJSON.json }
        let position = input?.cursorPosition ?? .zero
        let world = input?.cursorWorldPosition ?? .zero
        let screen = input?.cursorScreenPosition ?? .zero
        let json = try jsonString(for: [
            "__hasCursor": input?.cursorPosition != nil,
            "__resetCursorEvents": input?.resetCursorEvents ?? false,
            "__cursorEvents": (input?.cursorEvents ?? []).map { event -> [String: Any] in
                ["__hasCursor": true,
                 "cursorPosition": jsValueObject(for: .vec2([Double(event.position.x), Double(event.position.y)])),
                 "cursorWorldPosition": jsValueObject(for: .vec3([Double(event.worldPosition.x), Double(event.worldPosition.y), 0])),
                 "cursorScreenPosition": jsValueObject(for: .vec2([Double(event.screenPosition.x), Double(event.screenPosition.y)])),
                 "cursorLeftDown": event.leftDown]
            },
            "cursorPosition": jsValueObject(for: .vec2([Double(position.x), Double(position.y)])),
            "cursorWorldPosition": jsValueObject(for: .vec3([Double(world.x), Double(world.y), 0])),
            "cursorScreenPosition": jsValueObject(for: .vec2([Double(screen.x), Double(screen.y)])),
            "cursorLeftDown": input?.cursorLeftDown ?? false,
        ])
        cachedInputJSON = (input, json)
        return json
    }

    public func evaluate(
        source: String,
        baseValue: FrameValue,
        properties: [String: FrameValue],
        engine: SceneScriptEngineState? = nil,
        input: SceneScriptInputState? = nil,
        audioSpectrum: [Float] = [],
        instanceID: String? = nil,
        userProperties: [String: FrameValue] = [:],
        descriptor: DynamicValueDescriptor? = nil
    ) throws -> FrameValue {
        try evaluate(source: source, baseValue: baseValue, properties: properties, engine: engine,
            input: input, audioSpectrum: audioSpectrum, instanceID: instanceID,
            userProperties: SceneScriptUserProperties(userProperties), descriptor: descriptor)
    }

    func evaluate(
        source: String,
        baseValue: FrameValue,
        properties: [String: FrameValue],
        engine: SceneScriptEngineState? = nil,
        input: SceneScriptInputState? = nil,
        audioSpectrum: [Float] = [],
        instanceID: String? = nil,
        userProperties: SceneScriptUserProperties,
        descriptor: DynamicValueDescriptor? = nil
    ) throws -> FrameValue {
        lock.lock()
        defer { lock.unlock() }
        let userProperties = canonicalSnapshot(userProperties)
        let binding = descriptor.flatMap { descriptorBindings[ObjectIdentifier($0)] }
        let key = binding?.key ?? instanceID ?? source
        let inputs = EvaluationInputs(source: source, baseValue: baseValue, properties: properties,
            engine: engine, input: input, audioSpectrum: audioSpectrum,
            userProperties: userProperties, bindingKey: binding?.key)
        if cachedEvaluationFrame != engine?.frameIndex {
            cachedEvaluations.removeAll(keepingCapacity: true)
            cachedEvaluationFrame = engine?.frameIndex
        }
        // The JS host already runs update once per frame. Avoid repeating its
        // JSON round-trip when transforms/materials request the same result.
        // Changed inputs and failed evaluations must still reach the host.
        if engine?.frameIndex != nil, let cached = cachedEvaluations[key], cached.inputs == inputs {
            return cached.value
        }
        cachedEvaluations[key] = nil
        let propertiesJSON: String
        if let cached = cachedPropertiesJSON[key], cached.properties == properties {
            propertiesJSON = cached.json
        } else {
            propertiesJSON = try jsonString(for: properties.mapValues(jsValueObject(for:)))
            cachedPropertiesJSON[key] = (properties, propertiesJSON)
        }
        let scriptBaseValue = binding.map { sceneValue(baseValue, binding: $0, toScript: true) } ?? baseValue
        let currentJSON = try jsonString(for: jsValueObject(for: scriptBaseValue))
        try updateEngineSnapshot(engine, audioSpectrum: audioSpectrum)
        var engineObject: [String: Any] = ["timeOfDay": timeOfDay(frame: engine?.frameIndex)]
        engineObject["__ownerID"] = binding?.ownerID
        engineObject["__property"] = binding?.property
        engineObject["__loadOnly"] = loadingSceneModules
        engineObject["__initializeOnly"] = initializingScene
        if cachedUserProperties != userProperties {
            let json = try jsonString(for: userProperties.values.mapValues(jsValueObject(for:)))
            let result = json.withCString { we_script_host_set_user_properties_json(nativeHost, $0) }
            defer { we_script_host_free_evaluation(result) }
            if let message = result.error_message {
                throw ScriptHostError.evaluationFailed(String(cString: message))
            }
            cachedUserProperties = userProperties
            userPropertiesRevision &+= 1
        }
        engineObject["__userPropertiesRevision"] = String(userPropertiesRevision)
        // The native host supplies fresh values from its private snapshot.
        let engineJSON = try jsonString(for: engineObject)
        let inputJSON = try inputJSONString(input)

        let evaluation = key.withCString { instanceCString in
            source.withCString { sourceCString in
                propertiesJSON.withCString { propertiesCString in
                    currentJSON.withCString { currentCString in
                        engineJSON.withCString { engineCString in
                            inputJSON.withCString { inputCString in
                                we_script_host_evaluate_json(
                                    nativeHost,
                                    instanceCString,
                                    sourceCString,
                                    propertiesCString,
                                    currentCString,
                                    engineCString,
                                    inputCString
                                )
                            }
                        }
                    }
                }
            }
        }
        defer { we_script_host_free_evaluation(evaluation) }
        receiveSceneMutations(evaluation)
        if let binding, valueScriptUpdates[binding.key] == nil {
            let updates = key.withCString { we_script_host_value_instance_has_update(nativeHost, $0) }
            if updates >= 0 { valueScriptUpdates[binding.key] = updates != 0 }
        }

        if let errorPointer = evaluation.error_message {
            guard let message = String(validatingCString: errorPointer) else {
                throw ScriptHostError.invalidUTF8Result
            }
            throw ScriptHostError.evaluationFailed(message)
        }

        guard let resultPointer = evaluation.result_json,
              let resultString = String(validatingCString: resultPointer) else {
            throw ScriptHostError.invalidUTF8Result
        }

        guard let data = resultString.data(using: .utf8) else {
            throw ScriptHostError.invalidUTF8Result
        }

        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let value: FrameValue
        if json is NSNull {
            // WE semantics: update() returning nothing keeps the current value.
            value = baseValue
        } else {
            let decoded = try frameValue(from: json, hint: scriptBaseValue)
            value = binding.map { sceneValue(decoded, binding: $0, toScript: false) } ?? decoded
        }
        if engine?.frameIndex != nil { cachedEvaluations[key] = (inputs, value) }
        return value
    }

    /// Time of day, sampled once per frame: evaluating dozens of scripts must
    /// not build calendar components for each one.
    private func timeOfDay(frame: UInt64?) -> Double {
        guard let frame else { return Self.currentTimeOfDay() }
        if let cachedTimeOfDay, cachedTimeOfDay.frame == frame { return cachedTimeOfDay.value }
        let value = Self.currentTimeOfDay()
        cachedTimeOfDay = (frame, value)
        return value
    }

    /// Fraction of the local day in [0, 1), matching WE's engine.timeOfDay.
    private static func currentTimeOfDay() -> Double {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second], from: Date())
        let seconds = Double((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
        return seconds / 86_400.0
    }

    public func executeSceneCallback(
        source: String,
        callback: SceneScriptCallback,
        thisObject: [String: FrameValue],
        changedUserProperties: [String: FrameValue],
        engine: SceneScriptEngineState,
        input: SceneScriptInputState,
        instanceID: String? = nil,
        ownerID: String? = nil
    ) throws -> [String: FrameValue] {
        lock.lock()
        defer { lock.unlock() }
        let thisObjectJSON = try jsonString(for: thisObject.mapValues(jsValueObject(for:)))
        let changedPropertiesJSON = try jsonString(for: changedUserProperties.mapValues(jsValueObject(for:)))
        var engineObject: [String: Any] = [
            "runtime": engine.runtime,
            "frametime": engine.frametime,
            "timeOfDay": Self.currentTimeOfDay(),
            "__media": mediaObject,
            "screenResolution": jsValueObject(for: .vec2([Double(engine.screenResolution.x), Double(engine.screenResolution.y)])),
            "canvasSize": jsValueObject(for: .vec2([Double(engine.canvasSize.x), Double(engine.canvasSize.y)])),
        ]
        engineObject["__ownerID"] = ownerID
        let engineJSON = try jsonString(for: engineObject)
        let inputJSON = try inputJSONString(input)

        let evaluation = (instanceID ?? source).withCString { instanceCString in
            source.withCString { sourceCString in
                callback.rawValue.withCString { callbackCString in
                    thisObjectJSON.withCString { thisObjectCString in
                        changedPropertiesJSON.withCString { changedPropertiesCString in
                            engineJSON.withCString { engineCString in
                                inputJSON.withCString { inputCString in
                                    we_scene_script_host_execute_json(
                                        nativeHost,
                                        instanceCString,
                                        sourceCString,
                                        callbackCString,
                                        thisObjectCString,
                                        changedPropertiesCString,
                                        engineCString,
                                        inputCString
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        defer { we_script_host_free_evaluation(evaluation) }
        receiveSceneMutations(evaluation)

        if let errorPointer = evaluation.error_message {
            guard let message = String(validatingCString: errorPointer) else {
                throw ScriptHostError.invalidUTF8Result
            }
            throw ScriptHostError.evaluationFailed(message)
        }

        guard let resultPointer = evaluation.result_json,
              let resultString = String(validatingCString: resultPointer),
              let data = resultString.data(using: .utf8) else {
            throw ScriptHostError.invalidUTF8Result
        }

        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let object = json as? [String: Any] else {
            throw ScriptHostError.invalidJSONResult("scene callback did not return an object")
        }
        return try object.mapValues(frameValue(fromUntypedJSON:))
    }

    public func isSceneCallbackScript(_ source: String?) -> Bool {
        guard let source else {
            return false
        }
        // Scripted dynamic-value scripts run through the value host, which
        // provides createScriptProperties(); executing them as scene
        // callbacks throws every frame (and has destabilized QuickJS).
        if source.contains("createScriptProperties") {
            return false
        }
        // A value script can also initialize state, access thisObject and
        // handle property changes. Keep all of its callbacks in one instance.
        if source.range(of: #"\bfunction\s+update\s*\("#, options: .regularExpression) != nil {
            return false
        }
        if source.range(of: #"\bfunction\s+init\s*\(\s*[A-Za-z_$]"#, options: .regularExpression) != nil {
            return false
        }
        return source.contains("applyUserProperties") ||
               source.contains("thisObject") ||
               source.contains("export function init") ||
               source.contains("export function destroy") ||
               source.contains("function init") ||
               source.contains("function destroy")
    }

    private func jsonString(for object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
        // JSONSerialization always emits UTF-8. Decode into a native Swift
        // string: `String(data:encoding:)` returns a bridged NSString whose
        // `withCString` copies one character at a time on every evaluation.
        return String(decoding: data, as: UTF8.self)
    }

    private func jsValueObject(for value: FrameValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .double(let scalar):
            return scalar
        case .int(let scalar):
            return scalar
        case .bool(let scalar):
            return scalar
        case .string(let scalar):
            return scalar
        case .vec2(let values):
            return [
                "x": number(at: 0, in: values),
                "y": number(at: 1, in: values),
            ]
        case .ivec2(let values):
            return [
                "x": number(at: 0, in: values),
                "y": number(at: 1, in: values),
            ]
        case .vec3(let values):
            return [
                "x": number(at: 0, in: values),
                "y": number(at: 1, in: values),
                "z": number(at: 2, in: values),
            ]
        case .ivec3(let values):
            return [
                "x": number(at: 0, in: values),
                "y": number(at: 1, in: values),
                "z": number(at: 2, in: values),
            ]
        case .vec4(let values):
            return [
                "x": number(at: 0, in: values),
                "y": number(at: 1, in: values),
                "z": number(at: 2, in: values),
                "w": number(at: 3, in: values),
            ]
        case .ivec4(let values):
            return [
                "x": number(at: 0, in: values),
                "y": number(at: 1, in: values),
                "z": number(at: 2, in: values),
                "w": number(at: 3, in: values),
            ]
        }
    }

    private func frameValue(from json: Any, hint: FrameValue) throws -> FrameValue {
        switch json {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            // SceneScript broadcasts a numeric return to vector properties.
            switch hint {
            case .vec2: return .vec2(Array(repeating: number.doubleValue, count: 2))
            case .vec3: return .vec3(Array(repeating: number.doubleValue, count: 3))
            case .vec4: return .vec4(Array(repeating: number.doubleValue, count: 4))
            case .ivec2: return .ivec2(Array(repeating: number.intValue, count: 2))
            case .ivec3: return .ivec3(Array(repeating: number.intValue, count: 3))
            case .ivec4: return .ivec4(Array(repeating: number.intValue, count: 4))
            default: break
            }
            if number.isIntegerLike {
                switch hint {
                case .double:
                    return .double(number.doubleValue)
                case .int:
                    return .int(number.intValue)
                default:
                    return .int(number.intValue)
                }
            }
            return .double(number.doubleValue)
        case let object as [String: Any]:
            return vectorValue(from: object, hint: hint)
        case let array as [Any]:
            let values = array.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            switch hint {
            case .vec2, .ivec2:
                return .vec2(Array(values.prefix(2)))
            case .vec4, .ivec4:
                return .vec4(Array(values.prefix(4)))
            default:
                return .vec3(Array(values.prefix(3)))
            }
        default:
            throw ScriptHostError.invalidJSONResult("unsupported JS result type \(type(of: json))")
        }
    }

    private func frameValue(fromUntypedJSON json: Any) throws -> FrameValue {
        switch json {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if number.isIntegerLike {
                return .int(number.intValue)
            }
            return .double(number.doubleValue)
        case let object as [String: Any]:
            let keys = Set(object.keys)
            if keys == ["x", "y"] {
                return .vec2([(object["x"] as? NSNumber)?.doubleValue ?? 0, (object["y"] as? NSNumber)?.doubleValue ?? 0])
            }
            if keys == ["x", "y", "z"] {
                return .vec3([
                    (object["x"] as? NSNumber)?.doubleValue ?? 0,
                    (object["y"] as? NSNumber)?.doubleValue ?? 0,
                    (object["z"] as? NSNumber)?.doubleValue ?? 0,
                ])
            }
            if keys == ["x", "y", "z", "w"] {
                return .vec4([
                    (object["x"] as? NSNumber)?.doubleValue ?? 0,
                    (object["y"] as? NSNumber)?.doubleValue ?? 0,
                    (object["z"] as? NSNumber)?.doubleValue ?? 0,
                    (object["w"] as? NSNumber)?.doubleValue ?? 0,
                ])
            }
            throw ScriptHostError.invalidJSONResult("unsupported scene callback object payload")
        default:
            throw ScriptHostError.invalidJSONResult("unsupported scene callback result type \(type(of: json))")
        }
    }

    private func vectorValue(from object: [String: Any], hint: FrameValue) -> FrameValue {
        func readDouble(_ key: String) -> Double {
            (object[key] as? NSNumber)?.doubleValue ?? 0
        }

        func readInt(_ key: String) -> Int {
            (object[key] as? NSNumber)?.intValue ?? 0
        }

        switch hint {
        case .vec2:
            return .vec2([readDouble("x"), readDouble("y")])
        case .vec3:
            return .vec3([readDouble("x"), readDouble("y"), readDouble("z")])
        case .vec4:
            return .vec4([readDouble("x"), readDouble("y"), readDouble("z"), readDouble("w")])
        case .ivec2:
            return .ivec2([readInt("x"), readInt("y")])
        case .ivec3:
            return .ivec3([readInt("x"), readInt("y"), readInt("z")])
        case .ivec4:
            return .ivec4([readInt("x"), readInt("y"), readInt("z"), readInt("w")])
        default:
            return .vec3([readDouble("x"), readDouble("y"), readDouble("z")])
        }
    }

    private func number<T: BinaryInteger>(at index: Int, in values: [T]) -> NSNumber {
        NSNumber(value: Int(values[safe: index] ?? 0))
    }

    private func number(at index: Int, in values: [Double]) -> NSNumber {
        NSNumber(value: values[safe: index] ?? 0)
    }
}

private extension NSNumber {
    var isIntegerLike: Bool {
        let doubleValue = self.doubleValue
        return floor(doubleValue) == doubleValue
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
