import Foundation
import ImageIO

public enum SceneDescriptionLoaderError: LocalizedError {
    case fileNotFound(String)
    case invalidJSON(String)
    case invalidProject(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Could not resolve required scene asset: \(path)"
        case .invalidJSON(let path):
            return "Failed to parse Wallpaper Engine JSON file: \(path)"
        case .invalidProject(let message):
            return message
        }
    }
}

public enum SceneDescriptionLoader {
    /// Parse a SceneScript-created layer with the same rules as authored nodes.
    /// Asset roots are already resolved by the owning runtime; no packages are
    /// extracted and no files are written for an individual layer.
    public static func loadLayer(configurationJSON: Data, nodeID: NodeID,
                                 userProperties: [UserProperty], assetRoots: [URL], workshopID: String? = nil) throws -> (node: NodeDescriptor, configuration: Data) {
        let parser = NativeSceneProjectParser(assetRoots: assetRoots)
        func assetPath(_ path: String) -> String {
            let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard let workshopID, !workshopID.isEmpty, workshopID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  !path.hasPrefix("/"), parts.count > 1, parts[1] != "workshop", !parts.contains("..") else { return path }
            let imported = ([parts[0], "workshop", workshopID] + parts.dropFirst()).joined(separator: "/")
            return parser.resolveURL(path: imported, allowAssetsFallback: true) != nil ? imported : path
        }
        let value = try JSONSerialization.jsonObject(with: configurationJSON, options: .fragmentsAllowed)
        var object: JSONObject
        if let file = value as? String {
            let path = assetPath(file)
            guard parser.resolveURL(path: path, allowAssetsFallback: true) != nil else {
                throw SceneDescriptionLoaderError.fileNotFound(path)
            }
            if path.lowercased().hasSuffix(".json") {
                let asset = try parser.loadJSONObject(path: path)
                if asset["image"] != nil || asset["text"] != nil || asset["particle"] != nil || asset["sound"] != nil {
                    object = asset
                } else if ["initializer", "emitter", "operator", "initializers", "emitters", "operators"].contains(where: { asset[$0] != nil }) {
                    object = ["particle": path]
                } else { object = ["image": path] }
            } else { object = ["image": path] }
        } else if let configuration = value as? JSONObject { object = configuration }
        else { throw SceneDescriptionLoaderError.invalidProject("Layer configuration must be an asset path or object") }
        for key in ["image", "model", "particle", "font"] {
            if let path = object[key] as? String { object[key] = assetPath(path) }
        }
        if let sounds = object["sound"] as? [String] { object["sound"] = sounds.map(assetPath) }
        for key in ["image", "model", "particle"] {
            if let path = object[key] as? String {
                guard parser.resolveURL(path: path, allowAssetsFallback: true) != nil else {
                    throw SceneDescriptionLoaderError.fileNotFound(path)
                }
                if path.lowercased().hasSuffix(".json") { _ = try parser.loadJSONObject(path: path) }
            }
        }
        object["id"] = nodeID.rawValue
        var node = parser.parseNode(object, properties: userProperties)
        if let image = node.image, image.size.isEmpty, image.model?.width == nil,
           let path = image.model?.material?.passes.first?.textures.first(where: { $0.slot == 0 })?.path,
           let size = initialImageSize(path: path, assetRoots: assetRoots) {
            object["size"] = size
            node = parser.parseNode(object, properties: userProperties)
        }
        guard node.kind != .unknown else {
            throw SceneDescriptionLoaderError.invalidProject("Layer configuration has no supported layer type")
        }
        if let image = node.image, image.model == nil {
            throw SceneDescriptionLoaderError.invalidProject("Layer image does not resolve to a supported model")
        }
        return (node, try JSONSerialization.data(withJSONObject: object))
    }

    private static func initialImageSize(path: String, assetRoots: [URL]) -> [Int]? {
        let roots = assetRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard let url = TextureAnimationLibrary.candidateURLs(for: path, roots: roots).first(where: { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return roots.contains { resolved.path.hasPrefix($0.path + "/") } && FileManager.default.fileExists(atPath: resolved.path)
        }) else { return nil }
        let width: Int, height: Int
        if url.pathExtension.lowercased() == "tex" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 46), header.count == 46,
                  header.prefix(18) == Data("TEXV0005\0TEXI0001\0".utf8) else { return nil }
            func word(_ index: Int) -> Int {
                Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 18 + index * 4, as: UInt32.self) }))
            }
            width = word(4) > 0 ? word(4) : word(2)
            height = word(5) > 0 ? word(5) : word(3)
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            width = w; height = h
        }
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        return [width, height]
    }

    /// Preserve authored values and scripts when getInitialLayerConfig is cloned.
    public static func loadInitialLayerConfigurations(sceneFile: String, assetRoots: [URL]) throws -> [NodeID: Data] {
        let scene = try NativeSceneProjectParser(assetRoots: assetRoots).loadJSONObject(path: sceneFile)
        var result: [NodeID: Data] = [:]
        for object in (scene["objects"] as? [JSONObject]) ?? [] {
            guard let id = object["id"] as? Int else { continue }
            result[NodeID(rawValue: id)] = try JSONSerialization.data(withJSONObject: object)
        }
        return result
    }

    public static func loadSceneDescription(
        wallpaperPath: String,
        assetsPath: String,
        packageTemporaryRoot: URL? = nil
    ) throws -> SceneDescription {
        try NativeSceneProjectParser(
            wallpaperRoot: URL(fileURLWithPath: wallpaperPath, isDirectory: true),
            assetsRoot: URL(fileURLWithPath: assetsPath, isDirectory: true),
            packageTemporaryRoot: packageTemporaryRoot
        ).load()
    }
}

private typealias JSONObject = [String: Any]
private typealias JSONArray = [Any]

private struct NativeSceneProjectParser {
    let wallpaperRoot: URL
    let assetsRoot: URL
    let packageRoots: [URL]
    let packageLease: ScenePackageLease
    let packageFailures: [String]
    let workingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let fileManager = FileManager.default
    private let explicitAssetRoots: [URL]?

    init(assetRoots: [URL]) {
        wallpaperRoot = assetRoots.first ?? URL(fileURLWithPath: "/")
        assetsRoot = wallpaperRoot
        packageRoots = []
        packageFailures = []
        packageLease = ScenePackageLease(roots: [])
        explicitAssetRoots = assetRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    init(wallpaperRoot: URL, assetsRoot: URL, packageTemporaryRoot: URL?) {
        explicitAssetRoots = nil
        self.wallpaperRoot = wallpaperRoot
        self.assetsRoot = assetsRoot
        var roots: [URL] = []
        var failures: [String] = []
        for packageName in ["scene.pkg", "gifscene.pkg"] {
            let packageURL = wallpaperRoot.appendingPathComponent(packageName)
            guard FileManager.default.fileExists(atPath: packageURL.path) else { continue }
            do {
                roots.append(try NativeScenePackageParser.extract(pkgURL: packageURL, temporaryRoot: packageTemporaryRoot))
            } catch {
                failures.append("Package \(packageName) extraction failed: \(error.localizedDescription)")
            }
        }
        self.packageRoots = roots
        self.packageFailures = failures
        self.packageLease = ScenePackageLease(roots: self.packageRoots)
    }

    func load() throws -> SceneDescription {
        let project = try loadJSONObject(path: "project.json", allowAssetsFallback: false)
        let projectFile = requiredString(in: project, key: "file", context: "project.json")
        let projectType = parseProjectType(project["type"])
        let properties = parseUserProperties(project)

        var sceneGraph: SceneGraph?
        var defaultResolution: IntSize?
        if projectType == .scene {
            let sceneObject = try loadJSONObject(path: projectFile)
            let parsedScene = try parseSceneGraph(sceneObject, properties: properties)
            sceneGraph = parsedScene
            if !parsedScene.camera.projection.isAuto,
               parsedScene.camera.projection.width > 0,
               parsedScene.camera.projection.height > 0 {
                defaultResolution = IntSize(
                    width: parsedScene.camera.projection.width,
                    height: parsedScene.camera.projection.height
                )
            }
        }

        let metadata = SceneMetadata(
            title: string(in: project, key: "title") ?? wallpaperRoot.lastPathComponent,
            projectType: projectType,
            workshopId: parseWorkshopID(project["workshopid"]),
            supportsAudioProcessing: boolValue((project["general"] as? JSONObject)?["supportsaudioprocessing"], default: false),
            schemaVersion: 1,
            wallpaperFile: projectFile,
            defaultResolution: defaultResolution
        )

        return SceneDescription(metadata: metadata, userProperties: properties, scene: sceneGraph, extractedRoots: packageRoots)
            .retainingPackages(packageLease)
    }

    private func parseSceneGraph(
        _ scene: JSONObject,
        properties: [UserProperty]
    ) throws -> SceneGraph {
        guard let cameraObject = scene["camera"] as? JSONObject,
              let generalObject = scene["general"] as? JSONObject else {
            throw SceneDescriptionLoaderError.invalidProject("Scene file is missing camera/general sections")
        }

        let nodes = ((scene["objects"] as? JSONArray) ?? []).compactMap { value -> NodeDescriptor? in
            guard let object = value as? JSONObject else {
                return nil
            }
            return parseNode(object, properties: properties)
        }

        return SceneGraph(
            ambientColor: doubleArray(from: generalObject["ambientcolor"], default: [0, 0, 0], expectedCount: 3),
            skylightColor: doubleArray(from: generalObject["skylightcolor"], default: [0, 0, 0], expectedCount: 3),
            clearColor: userSetting(from: generalObject["clearcolor"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "scene.general.clearcolor"),
            camera: parseCamera(cameraObject, general: generalObject),
            nodes: nodes
        )
    }

    private func parseCamera(_ camera: JSONObject, general: JSONObject) -> CameraDescriptor {
        let projection = general["orthogonalprojection"] as? JSONObject
        return CameraDescriptor(
            fade: boolValue(general["camerafade"], default: false),
            preview: boolValue(general["camerapreview"], default: false),
            bloom: CameraBloomDescriptor(
                enabled: userSetting(from: general["bloom"], defaultValue: .bool(false), runtimeKey: "scene.general.bloom"),
                strength: userSetting(from: general["bloomstrength"], defaultValue: .float(1), runtimeKey: "scene.general.bloomstrength"),
                threshold: userSetting(from: general["bloomthreshold"], defaultValue: .float(1), runtimeKey: "scene.general.bloomthreshold")
            ),
            parallax: CameraParallaxDescriptor(
                enabled: userSetting(from: general["cameraparallax"], defaultValue: .bool(false), runtimeKey: "scene.general.cameraparallax"),
                amount: userSetting(from: general["cameraparallaxamount"], defaultValue: .float(0.5), runtimeKey: "scene.general.cameraparallaxamount"),
                delay: userSetting(from: general["cameraparallaxdelay"], defaultValue: .float(0.1), runtimeKey: "scene.general.cameraparallaxdelay"),
                mouseInfluence: userSetting(from: general["cameraparallaxmouseinfluence"], defaultValue: .float(0), runtimeKey: "scene.general.cameraparallaxmouseinfluence")
            ),
            shake: CameraShakeDescriptor(
                enabled: userSetting(from: general["camerashake"], defaultValue: .bool(false), runtimeKey: "scene.general.camerashake"),
                amplitude: userSetting(from: general["camerashakeamplitude"], defaultValue: .float(0.5), runtimeKey: "scene.general.camerashakeamplitude"),
                roughness: userSetting(from: general["camerashakeroughness"], defaultValue: .float(1), runtimeKey: "scene.general.camerashakeroughness"),
                speed: userSetting(from: general["camerashakespeed"], defaultValue: .float(3), runtimeKey: "scene.general.camerashakespeed")
            ),
            configuration: CameraConfigurationDescriptor(
                center: doubleArray(from: camera["center"], default: [0, 0, -1], expectedCount: 3),
                eye: doubleArray(from: camera["eye"], default: [0, 0, 0], expectedCount: 3),
                up: doubleArray(from: camera["up"], default: [0, 1, 0], expectedCount: 3)
            ),
            projection: CameraProjectionDescriptor(
                width: intValue(projection?["width"], default: 0),
                height: intValue(projection?["height"], default: 0),
                isAuto: projection.map { boolValue($0["auto"], default: false) } ?? true,
                nearZ: doubleValue(general["nearz"], default: 0.01),
                farZ: doubleValue(general["farz"], default: 1000),
                fov: doubleValue(general["fov"], default: 50),
                isPerspective: general["orthogonalprojection"] is NSNull,
                perspectiveOverrideFOV: (general["perspectiveoverridefov"] as? NSNumber)?.doubleValue
            ),
            zoom: userSetting(from: general["zoom"], defaultValue: .float(1), runtimeKey: "scene.general.zoom")
        )
    }

    func parseNode(_ object: JSONObject, properties: [UserProperty]) -> NodeDescriptor {
        let kind = nodeKind(for: object)
        let nodeID = intValue(object["id"], default: -1)
        let nodePrefix = "scene.node.\(nodeID)"
        return NodeDescriptor(
            id: NodeID(rawValue: nodeID),
            name: string(in: object, key: "name") ?? "unknown",
            parentId: optionalInt(object["parent"]).map(NodeID.init(rawValue:)),
            attachment: (object["attachment"] as? String).map(AttachmentReference.name)
                ?? optionalInt(object["attachment"]).map(AttachmentReference.index),
            dependencyIds: ((object["dependencies"] as? JSONArray) ?? []).compactMap { optionalInt($0).map(NodeID.init(rawValue:)) },
            origin: userSetting(from: object["origin"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(nodePrefix).origin"),
            kind: kind,
            image: kind == .image ? parseImage(object, prefix: nodePrefix) : nil,
            sound: kind == .sound ? parseSound(object, prefix: nodePrefix) : nil,
            light: kind == .light ? parseLight(object, prefix: nodePrefix) : nil,
            particle: kind == .particle ? parseParticle(object, properties: properties, prefix: nodePrefix) : nil,
            text: kind == .text ? parseText(object, prefix: nodePrefix) : nil,
            group: kind == .group ? GroupDescriptor(
                scale: userSetting(from: object["scale"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(nodePrefix).scale"),
                angles: userSetting(from: object["angles"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(nodePrefix).angles"),
                visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: "\(nodePrefix).visible")
            ) : nil,
            solid: object["solid"].map { boolValue($0, default: false) }
        )
    }

    private func parseImage(_ object: JSONObject, prefix: String) -> ImageDescriptor {
        let modelReference = string(in: object, key: "image") ?? string(in: object, key: "model")
        return ImageDescriptor(
            scale: userSetting(from: object["scale"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).scale"),
            angles: userSetting(from: object["angles"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(prefix).angles"),
            visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: "\(prefix).visible"),
            alpha: userSetting(from: object["alpha"], defaultValue: .float(1), runtimeKey: "\(prefix).alpha"),
            color: userSetting(from: object["color"], defaultValue: .vec4([1, 1, 1, 1]), runtimeKey: "\(prefix).color"),
            alignment: string(in: object, key: "alignment") ?? "center",
            // An omitted size requests fallback sizing. Explicit zero dimensions
            // are used by script-only helpers and must remain non-drawing.
            size: object["size"] == nil ? [] : doubleArray(from: object["size"], default: [0, 0], expectedCount: 2),
            parallaxDepth: userSetting(from: object["parallaxDepth"], defaultValue: .vec2([0, 0]), runtimeKey: "\(prefix).parallaxDepth"),
            colorBlendMode: intValue(object["colorBlendMode"], default: 0),
            brightness: doubleValue(object["brightness"], default: 1),
            model: modelReference.flatMap { parseModelReference($0, instance: object["instance"] as? JSONObject) },
            effects: parseImageEffects(object["effects"]),
            animationLayers: parseAnimationLayers(object["animationlayers"], prefix: prefix),
            perspective: object["perspective"].map { boolValue($0, default: false) }
        )
    }

    private func parseSound(_ object: JSONObject, prefix: String) -> SoundDescriptor {
        let volume = userSetting(from: object["volume"], defaultValue: .float(1), runtimeKey: "\(prefix).volume")
        return SoundDescriptor(
            playbackMode: string(in: object, key: "playbackmode"),
            sounds: ((object["sound"] as? JSONArray) ?? []).compactMap { $0 as? String },
            volume: soundVolume(volume, fallback: doubleValue(object["volume"], default: 1)),
            volumeSetting: volume,
            startSilent: boolValue(object["startsilent"], default: false),
            minTime: doubleValue(object["mintime"], default: 0),
            maxTime: doubleValue(object["maxtime"], default: 0)
        )
    }

    private func soundVolume(_ setting: UserSettingDescriptor?, fallback: Double) -> Double {
        guard let value = setting?.value?.value else { return fallback }
        switch value {
        case .float(let number): return number
        case .int(let number): return Double(number)
        default: return fallback
        }
    }

    private func parseLight(_ object: JSONObject, prefix: String) -> LightDescriptor {
        LightDescriptor(
            lightType: parseLightType(string(in: object, key: "light")),
            visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: "\(prefix).visible"),
            angles: userSetting(from: object["angles"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(prefix).angles"),
            scale: userSetting(from: object["scale"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).scale"),
            color: userSetting(from: object["color"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).color"),
            intensity: userSetting(from: object["intensity"], defaultValue: .float(1), runtimeKey: "\(prefix).intensity"),
            radius: userSetting(from: object["radius"], defaultValue: .float(100), runtimeKey: "\(prefix).radius"),
            length: userSetting(from: object["length"], defaultValue: .float(100), runtimeKey: "\(prefix).length"),
            controlPoint: object["controlpoint"] == nil ? nil : userSetting(from: object["controlpoint"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(prefix).controlpoint"),
            innerCone: userSetting(from: object["innercone"], defaultValue: .float(0.61086524), runtimeKey: "\(prefix).innercone"),
            outerCone: userSetting(from: object["outercone"], defaultValue: .float(0.78539816), runtimeKey: "\(prefix).outercone"),
            castsShadow: boolValue(object["castshadow"], default: false),
            exponent: userSetting(from: object["exponent"], defaultValue: .float(2), runtimeKey: "\(prefix).exponent")
        )
    }

    private func parseText(_ object: JSONObject, prefix: String) -> TextDescriptor {
        let defaults: [String: SceneValue] = [
            "font": .string("fonts/NotoSans-Regular.ttf"), "padding": .int(0),
            "horizontalalign": .string("center"), "verticalalign": .string("center"),
            "limitwidth": .bool(false), "maxwidth": .float(0),
            "limitrows": .bool(false), "maxrows": .int(1),
            "limituseellipsis": .bool(false), "blockalign": .bool(false),
            "castshadow": .bool(false), "opaquebackground": .bool(false),
        ]
        let styles = defaults.reduce(into: [String: UserSettingDescriptor]()) { result, entry in
            result[entry.key] = userSetting(from: object[entry.key], defaultValue: entry.value,
                                           runtimeKey: "\(prefix).\(entry.key)")
        }
        return TextDescriptor(
            scale: userSetting(from: object["scale"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).scale"),
            angles: userSetting(from: object["angles"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(prefix).angles"),
            visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: "\(prefix).visible"),
            alpha: userSetting(from: object["alpha"], defaultValue: .float(1), runtimeKey: "\(prefix).alpha"),
            color: userSetting(from: object["color"], defaultValue: .vec4([1, 1, 1, 1]), runtimeKey: "\(prefix).color"),
            content: userSetting(from: object["text"], defaultValue: .string(""), runtimeKey: "\(prefix).text"),
            backgroundColor: userSetting(from: object["backgroundcolor"], defaultValue: .vec4([0, 0, 0, 0]), runtimeKey: "\(prefix).backgroundcolor"),
            parallaxDepth: userSetting(from: object["parallaxDepth"], defaultValue: .vec2([0, 0]), runtimeKey: "\(prefix).parallaxDepth"),
            anchor: string(in: object, key: "anchor") ?? "none",
            backgroundBrightness: doubleValue(object["backgroundbrightness"], default: 1),
            blockAlign: boolValue(object["blockalign"], default: false),
            castShadow: boolValue(object["castshadow"], default: false),
            depthTest: string(in: object, key: "depthtest") ?? "enabled",
            fontPath: string(in: object, key: "font") ?? "fonts/NotoSans-Regular.ttf",
            horizontalAlign: string(in: object, key: "horizontalalign") ?? "center",
            limitRows: boolValue(object["limitrows"], default: false),
            limitUseEllipsis: boolValue(object["limituseellipsis"], default: false),
            limitWidth: boolValue(object["limitwidth"], default: false),
            lockTransforms: boolValue(object["locktransforms"], default: true),
            maxRows: intValue(object["maxrows"], default: 1),
            maxWidth: doubleValue(object["maxwidth"], default: 0),
            opaqueBackground: boolValue(object["opaquebackground"], default: false),
            padding: intValue(object["padding"], default: 0),
            pointSize: userSetting(from: object["pointsize"], defaultValue: .float(16), runtimeKey: "\(prefix).pointsize"),
            size: doubleArray(from: object["size"], default: [0, 0], expectedCount: 2),
            verticalAlign: string(in: object, key: "verticalalign") ?? "center",
            effects: parseImageEffects(object["effects"]),
            styleSettings: styles
        )
    }

    private func parseParticle(
        _ object: JSONObject,
        properties: [UserProperty],
        prefix: String,
        depth: Int = 0
    ) -> ParticleDescriptor {
        let particleSource = object["particle"]
        let particleFile: String
        let particleObject: JSONObject
        if let path = particleSource as? String {
            particleFile = path
            particleObject = (try? loadJSONObject(path: path)) ?? [:]
        } else {
            particleFile = ""
            particleObject = particleSource as? JSONObject ?? [:]
        }

        let renderers = parseParticleRenderers(particleObject["renderer"])
        return ParticleDescriptor(
            scale: userSetting(from: object["scale"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).scale"),
            angles: userSetting(from: object["angles"], defaultValue: .vec3([0, 0, 0]), runtimeKey: "\(prefix).angles"),
            visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: "\(prefix).visible"),
            parallaxDepth: userSetting(from: object["parallaxDepth"], defaultValue: .vec2([0, 0]), runtimeKey: "\(prefix).parallaxDepth"),
            particleFile: particleFile,
            animationMode: string(in: particleObject, key: "animationmode") ?? "sequence",
            sequenceMultiplier: doubleValue(particleObject["sequencemultiplier"], default: 1),
            maxCount: UInt32(max(intValue(particleObject["maxcount"], default: 100), 0)),
            startTime: UInt32(max(intValue(particleObject["starttime"], default: 0), 0)),
            flags: UInt32(max(intValue(particleObject["flags"], default: 0), 0)),
            material: string(in: particleObject, key: "material").flatMap(parseParticleMaterial),
            emitters: parseParticleEmitters(particleObject["emitter"]),
            initializers: parseParticleInitializers(particleObject["initializer"]),
            operators: parseParticleOperators(particleObject["operator"]),
            renderers: renderers.isEmpty ? [defaultParticleRenderer()] : renderers,
            controlPoints: parseParticleControlPoints(particleObject["controlpoint"], prefix: "\(prefix).instanceoverride"),
            children: parseParticleChildren(particleObject["children"], prefix: prefix, depth: depth),
            instanceOverride: parseParticleInstanceOverride(object["instanceoverride"], prefix: "\(prefix).instanceoverride")
        )
    }

    private func parseParticleEmitters(_ raw: Any?) -> [ParticleEmitterDescriptor] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject else { return nil }
            return ParticleEmitterDescriptor(
                id: intValue(object["id"], default: -1),
                name: string(in: object, key: "name") ?? "",
                directions: doubleArray(from: object["directions"], default: [1, 1, 0], expectedCount: 3),
                distanceMin: doubleArray(from: object["distancemin"], default: [0, 0, 0], expectedCount: 3),
                distanceMax: doubleArray(from: object["distancemax"], default: [0, 0, 0], expectedCount: 3),
                origin: doubleArray(from: object["origin"], default: [0, 0, 0], expectedCount: 3),
                sign: intArray(from: object["sign"], default: [0, 0, 0], expectedCount: 3),
                instantaneous: UInt32(max(intValue(object["instantaneous"], default: 0), 0)),
                speedMin: doubleValue(object["speedmin"], default: 0),
                speedMax: doubleValue(object["speedmax"], default: 0),
                rate: doubleValue(object["rate"], default: 1),
                controlPoint: intValue(object["controlpoint"], default: 0),
                flags: UInt32(max(intValue(object["flags"], default: 0), 0)),
                cone: doubleValue(object["cone"], default: 0),
                delay: doubleValue(object["delay"], default: 0),
                duration: doubleValue(object["duration"], default: 0),
                audioProcessingBounds: doubleArray(from: object["audioprocessingbounds"], default: [0, 1], expectedCount: 2),
                audioProcessingExponent: intValue(object["audioprocessingexponent"], default: 1),
                audioProcessingFrequencyStart: intValue(object["audioprocessingfrequencystart"], default: 0),
                audioProcessingFrequencyEnd: intValue(object["audioprocessingfrequencyend"], default: 0),
                audioProcessingMode: intValue(object["audioprocessingmode"], default: 0),
                minPeriodicDelay: doubleValue(object["minperiodicdelay"], default: 0),
                maxPeriodicDelay: doubleValue(object["maxperiodicdelay"], default: 0),
                minPeriodicDuration: doubleValue(object["minperiodicduration"], default: 0),
                maxPeriodicDuration: doubleValue(object["maxperiodicduration"], default: 0)
            )
        }
    }

    private func parseParticleInitializers(_ raw: Any?) -> [ParticleInitializerDescriptor] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject else { return nil }
            return ParticleInitializerDescriptor(
                kind: string(in: object, key: "name")?.lowercased() ?? "unknown",
                parameters: lowercasedKeys(parseSettingMap(object, excluding: ["name"]))
            )
        }
    }

    /// Particle initializer/operator parameters are matched case-insensitively;
    /// workshop JSON uses all-lowercase keys ("fadeintime") while some older
    /// data uses camelCase. Normalize so runtime lookups are stable.
    private func lowercasedKeys(_ map: [String: UserSettingDescriptor]) -> [String: UserSettingDescriptor] {
        map.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key.lowercased()] = entry.value
        }
    }

    private func parseParticleOperators(_ raw: Any?) -> [ParticleOperatorDescriptor] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject else { return nil }
            var excluded: Set<String> = ["name", "controlpoint", "flags"]
            if object["controlPoint"] != nil {
                excluded.insert("controlPoint")
            }
            return ParticleOperatorDescriptor(
                kind: string(in: object, key: "name")?.lowercased() ?? "unknown",
                controlPoint: optionalInt(object["controlpoint"] ?? object["controlPoint"]),
                flags: optionalInt(object["flags"]),
                parameters: lowercasedKeys(parseSettingMap(object, excluding: excluded))
            )
        }
    }

    private func parseParticleRenderers(_ raw: Any?) -> [ParticleRendererDescriptor] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject else { return nil }
            return ParticleRendererDescriptor(
                name: string(in: object, key: "name") ?? "sprite",
                length: doubleValue(object["length"], default: 0.05),
                maxLength: doubleValue(object["maxlength"], default: 10),
                minLength: doubleValue(object["minlength"], default: 0),
                subdivision: doubleValue(object["subdivision"], default: 1),
                segments: doubleValue(object["segments"], default: 4),
                uvScale: doubleValue(object["uvscale"], default: 1),
                uvScrolling: boolValue(object["uvscrolling"], default: false),
                uvSmoothing: boolValue(object["uvsmoothing"], default: true),
                fadeAlpha: boolValue(object["fadealpha"], default: false),
                fadeSize: boolValue(object["fadesize"], default: false)
            )
        }
    }

    private func parseParticleControlPoints(_ raw: Any?, prefix: String) -> [ParticleControlPointDescriptor] {
        let authored = ((raw as? JSONArray) ?? []).compactMap { $0 as? JSONObject }
        // Materialize default bindings once when loading, so the simulation
        // does not allocate new dynamic descriptors for omitted points per frame.
        return (0..<8).map { id in
            let object = authored.first { intValue($0["id"], default: 0) == id } ?? [:]
            return ParticleControlPointDescriptor(
                id: id,
                flags: UInt32(max(intValue(object["flags"], default: 0), 0)),
                offset: doubleArray(from: object["offset"], default: [0, 0, 0], expectedCount: 3),
                lockToPointer: boolValue(object["locktopointer"], default: false),
                offsetSetting: userSetting(from: object["offset"], defaultValue: .vec3([0, 0, 0]),
                    runtimeKey: "\(prefix).controlpoint\(id)")
            )
        }
    }

    private func parseParticleChildren(_ raw: Any?, prefix: String, depth: Int) -> [ParticleChildDescriptor] {
        ((raw as? JSONArray) ?? []).enumerated().compactMap { index, value in
            guard let object = value as? JSONObject else { return nil }
            // Workshop data stores the child definition path in "name";
            // some authors use "particle" instead.
            let childFile = string(in: object, key: "particle") ?? string(in: object, key: "name") ?? ""
            var resolved: [ParticleDescriptor] = []
            if depth < 4, !childFile.isEmpty, childFile.hasSuffix(".json") {
                resolved = [
                    parseParticle(
                        ["particle": childFile],
                        properties: [],
                        prefix: "\(prefix).child\(index)",
                        depth: depth + 1
                    ),
                ]
            }
            return ParticleChildDescriptor(
                type: string(in: object, key: "type") ?? "",
                name: string(in: object, key: "name") ?? "",
                maxCount: intValue(object["maxcount"], default: 0),
                controlPointStartIndex: intValue(object["controlpointstartindex"], default: 0),
                probability: doubleValue(object["probability"], default: 1),
                angles: doubleArray(from: object["angles"], default: [0, 0, 0], expectedCount: 3),
                origin: doubleArray(from: object["origin"], default: [0, 0, 0], expectedCount: 3),
                scale: doubleArray(from: object["scale"], default: [1, 1, 1], expectedCount: 3),
                particleFile: childFile,
                particle: resolved
            )
        }
    }

    private func parseParticleInstanceOverride(_ raw: Any?, prefix: String) -> ParticleInstanceOverrideDescriptor {
        let object = raw as? JSONObject ?? [:]
        let defaultsEnabled: SceneValue = raw == nil ? .bool(false) : .bool(true)
        return ParticleInstanceOverrideDescriptor(
            enabled: userSetting(from: object["enabled"], defaultValue: defaultsEnabled, runtimeKey: "\(prefix).enabled"),
            alpha: userSetting(from: object["alpha"], defaultValue: .float(1), runtimeKey: "\(prefix).alpha"),
            size: userSetting(from: object["size"], defaultValue: .float(1), runtimeKey: "\(prefix).size"),
            lifetime: userSetting(from: object["lifetime"], defaultValue: .float(1), runtimeKey: "\(prefix).lifetime"),
            rate: userSetting(from: object["rate"], defaultValue: .float(1), runtimeKey: "\(prefix).rate"),
            speed: userSetting(from: object["speed"], defaultValue: .float(1), runtimeKey: "\(prefix).speed"),
            count: userSetting(from: object["count"], defaultValue: .float(1), runtimeKey: "\(prefix).count"),
            color: userSetting(from: object["color"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).color"),
            colorn: userSetting(from: object["colorn"], defaultValue: .vec3([1, 1, 1]), runtimeKey: "\(prefix).colorn")
        )
    }

    private func defaultParticleRenderer() -> ParticleRendererDescriptor {
        ParticleRendererDescriptor(
            name: "sprite",
            length: 0.05,
            maxLength: 10,
            minLength: 0,
            subdivision: 1,
            segments: 4,
            uvScale: 1,
            uvScrolling: false,
            uvSmoothing: true,
            fadeAlpha: false,
            fadeSize: false
        )
    }

    private func parseImageEffects(_ raw: Any?) -> [ImageEffectDescriptor] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject,
                  let file = string(in: object, key: "file") else {
                return nil
            }
            return ImageEffectDescriptor(
                id: intValue(object["id"], default: -1),
                name: string(in: object, key: "name") ?? "Effect without name",
                visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: nil),
                passOverrides: parseEffectOverrides(object["passes"]),
                effect: try? parseEffectDescriptor(path: file)
            )
        }
    }

    private func parseAnimationLayers(_ raw: Any?, prefix: String) -> [AnimationLayerDescriptor] {
        ((raw as? JSONArray) ?? []).enumerated().compactMap { index, value in
            guard let object = value as? JSONObject else { return nil }
            let owner = "\(prefix).animation.\(index)"
            let rate = userSetting(from: object["rate"], defaultValue: .float(1), runtimeKey: "\(owner).rate")!
            let blend = userSetting(from: object["blend"], defaultValue: .float(1), runtimeKey: "\(owner).blend")!
            return AnimationLayerDescriptor(
                id: intValue(object["id"], default: -1),
                rate: doubleValue((object["rate"] as? JSONObject)?["value"] ?? object["rate"], default: 1),
                visible: userSetting(from: object["visible"], defaultValue: .bool(true), runtimeKey: "\(owner).visible"),
                blend: doubleValue((object["blend"] as? JSONObject)?["value"] ?? object["blend"], default: 1),
                animation: intValue(object["animation"], default: 0),
                name: string(in: object, key: "name"), rateSetting: rate, blendSetting: blend
            )
        }
    }

    private func parseModelReference(_ path: String, instance: JSONObject? = nil) -> ModelDescriptor? {
        let lowercased = path.lowercased()
        if lowercased.hasSuffix(".json") {
            return try? parseModelDescriptor(path: path, materialPathOverride: nil, instance: instance)
        }
        if lowercased.hasSuffix(".mdl"), let data = try? loadData(path: path),
           let meshes = try? DirectModelDecoder.decode(data) {
            var model = try? parseModelDescriptor(path: path, materialPathOverride: meshes.first?.material, instance: instance)
            model?.meshMaterials = meshes.map { try? parseMaterialDescriptor(path: $0.material, instance: instance) }
            return model
        }
        if lowercased.hasSuffix(".mdl") || lowercased.hasSuffix(".obj") {
            let materialPath = extractMaterialPath(fromModelBinaryAt: path)
            return try? parseModelDescriptor(
                path: path,
                materialPathOverride: materialPath,
                instance: instance
            )
        }
        return nil
    }

    private func parseParticleMaterial(_ path: String) -> ModelDescriptor? {
        guard let material = try? parseMaterialDescriptor(path: path) else {
            return nil
        }
        return ModelDescriptor(
            filename: path,
            material: material,
            solidLayer: false,
            fullscreen: false,
            passthrough: false,
            autoSize: false,
            noPadding: false,
            width: nil,
            height: nil,
            puppet: nil
        )
    }

    private func parseModelDescriptor(
        path: String,
        materialPathOverride: String?,
        instance: JSONObject? = nil
    ) throws -> ModelDescriptor {
        let descriptorPath: String
        if path.lowercased().hasSuffix(".json") {
            descriptorPath = path
        } else {
            descriptorPath = NSString(string: path).deletingPathExtension + ".json"
        }
        let object = (try? loadJSONObject(path: descriptorPath)) ?? [:]
        guard let materialPath = materialPathOverride ?? string(in: object, key: "material") else {
            throw SceneDescriptionLoaderError.invalidProject("Model is missing material: \(path)")
        }
        return ModelDescriptor(
            filename: path,
            material: try? parseMaterialDescriptor(path: materialPath, instance: instance),
            solidLayer: boolValue(object["solidlayer"], default: false),
            fullscreen: boolValue(object["fullscreen"], default: false),
            passthrough: boolValue(object["passthrough"], default: false),
            autoSize: boolValue(object["autosize"], default: false),
            noPadding: boolValue(object["nopadding"], default: false),
            width: optionalInt(object["width"]),
            height: optionalInt(object["height"]),
            puppet: string(in: object, key: "puppet")
        )
    }

    private func parseMaterialDescriptor(path: String, instance: JSONObject? = nil) throws -> MaterialDescriptor {
        let object = try loadJSONObject(path: path)
        let passes = ((object["passes"] as? JSONArray) ?? []).compactMap { value -> PassDescriptor? in
            guard let authoredPass = value as? JSONObject else { return nil }
            let pass = materialPass(authoredPass, applying: instance)
            return PassDescriptor(
                blending: parseBlendMode(string(in: pass, key: "blending")),
                culling: parseCullMode(string(in: pass, key: "cullmode")),
                depthTest: parseDepthMode(string(in: pass, key: "depthtest")),
                depthWrite: parseDepthMode(string(in: pass, key: "depthwrite")),
                shader: ShaderReference(path: requiredString(in: pass, key: "shader", context: path)),
                textures: parseTextureReferences(pass["textures"]),
                userTextures: parseTextureReferences(pass["usertextures"]),
                combos: parseCombos(pass["combos"]),
                constants: parseSettingMap(pass["constantshadervalues"] as? JSONObject ?? [:], excluding: [])
            )
        }
        return MaterialDescriptor(filename: path, passes: passes)
    }

    private func parseEffectDescriptor(path: String) throws -> EffectDescriptor {
        let object = try loadJSONObject(path: path)
        let passes = ((object["passes"] as? JSONArray) ?? []).compactMap { value -> EffectPassDescriptor? in
            guard let pass = value as? JSONObject else { return nil }
            let command = parseEffectCommand(string(in: pass, key: "command"))
            return EffectPassDescriptor(
                material: string(in: pass, key: "material").flatMap { try? parseMaterialDescriptor(path: $0) },
                binds: parseEffectBinds(pass["bind"]),
                command: command ?? -1,
                source: string(in: pass, key: "source"),
                target: string(in: pass, key: "target")
            )
        }
        let fbos = ((object["fbos"] as? JSONArray) ?? []).compactMap { value -> FBODescriptor? in
            guard let fbo = value as? JSONObject else { return nil }
            return FBODescriptor(
                name: requiredString(in: fbo, key: "name", context: path),
                format: string(in: fbo, key: "format") ?? "rgba8888",
                scale: doubleValue(fbo["scale"], default: 1),
                unique: boolValue(fbo["unique"], default: false)
            )
        }
        return EffectDescriptor(
            name: string(in: object, key: "name") ?? "",
            description: string(in: object, key: "description") ?? "",
            group: string(in: object, key: "group") ?? "",
            preview: string(in: object, key: "preview") ?? "",
            dependencies: ((object["dependencies"] as? JSONArray) ?? []).compactMap { $0 as? String },
            passes: passes,
            fbos: fbos
        )
    }

    private func parseEffectOverrides(_ raw: Any?) -> [EffectOverridePassDescriptor] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject else { return nil }
            return EffectOverridePassDescriptor(
                id: intValue(object["id"], default: -1),
                combos: parseCombos(object["combos"]),
                constants: parseSettingMap(object["constantshadervalues"] as? JSONObject ?? [:], excluding: []),
                textures: parseTextureReferences(object["textures"]),
                userTextures: parseTextureReferences(object["usertextures"]),
                shaderOverride: string(in: object, key: "shaderOverride")
            )
        }
    }

    /// A model's material is reusable. Each image may override selected slots,
    /// combos and constants without changing the material used by its siblings.
    private func materialPass(_ authored: JSONObject, applying instance: JSONObject?) -> JSONObject {
        guard let instance else { return authored }
        var pass = authored
        for key in ["combos", "constantshadervalues"] {
            guard let overrides = instance[key] as? JSONObject else { continue }
            pass[key] = (authored[key] as? JSONObject ?? [:]).merging(overrides) { _, replacement in replacement }
        }
        for key in ["textures", "usertextures"] {
            guard let overrides = instance[key] as? JSONArray else { continue }
            var slots = authored[key] as? JSONArray ?? []
            for (index, value) in overrides.enumerated() where !(value is NSNull) {
                if let name = value as? String, name.isEmpty { continue }
                while slots.count <= index { slots.append(NSNull()) }
                slots[index] = value
            }
            pass[key] = slots
        }
        return pass
    }

    private func parseTextureReferences(_ raw: Any?) -> [TextureReference] {
        ((raw as? JSONArray) ?? []).enumerated().compactMap { index, value in
            if let path = value as? String, !path.isEmpty {
                return TextureReference(slot: index, path: path)
            }
            guard let binding = value as? JSONObject,
                  let name = string(in: binding, key: "name"), !name.isEmpty else { return nil }
            return TextureReference(slot: index, path: name, sourceType: string(in: binding, key: "type"))
        }
    }

    private func parseEffectBinds(_ raw: Any?) -> [TextureReference] {
        ((raw as? JSONArray) ?? []).compactMap { value in
            guard let object = value as? JSONObject,
                  let name = string(in: object, key: "name") else {
                return nil
            }
            return TextureReference(slot: intValue(object["index"], default: 0), path: name)
        }
    }

    private func parseCombos(_ raw: Any?) -> [String: Int] {
        guard let object = raw as? JSONObject else {
            return [:]
        }
        return object.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = intValue(entry.value, default: 0)
        }
    }

    private func parseSettingMap(_ object: JSONObject, excluding: Set<String>) -> [String: UserSettingDescriptor] {
        object.reduce(into: [:]) { partialResult, entry in
            guard !excluding.contains(entry.key),
                  let setting = userSetting(from: entry.value, defaultValue: nil, runtimeKey: nil) else {
                return
            }
            partialResult[entry.key] = setting
        }
    }

    private func parseUserProperties(_ project: JSONObject) -> [UserProperty] {
        let propertyBlock = ((project["general"] as? JSONObject)?["properties"] as? JSONObject) ?? [:]
        return propertyBlock.compactMap { key, value in
            guard let object = value as? JSONObject,
                  let type = parsePropertyKind(string(in: object, key: "type")) else {
                return nil
            }
            return UserProperty(
                key: key,
                label: string(in: object, key: "text") ?? key,
                order: optionalInt(object["order"] ?? object["index"]) ?? 999,
                type: type,
                defaultValue: propertyDefaultValue(from: object, type: type),
                minimum: optionalDouble(object["min"]),
                maximum: optionalDouble(object["max"]),
                step: optionalDouble(object["step"]),
                precision: optionalInt(object["precision"]),
                options: ((object["options"] as? JSONArray) ?? []).compactMap { option in
                    guard let optionObject = option as? JSONObject,
                          let value = string(in: optionObject, key: "value") else {
                        return nil
                    }
                    return UserPropertyOption(
                        value: value,
                        label: string(in: optionObject, key: "label") ?? value
                    )
                }
            )
        }
        .sorted { ($0.order, $0.label, $0.key) < ($1.order, $1.label, $1.key) }
    }

    private func propertyDefaultValue(from object: JSONObject, type: UserPropertyKind) -> DynamicValueDescriptor? {
        let value: SceneValue
        switch type {
        case .slider:
            value = sceneValue(from: object["value"], defaultValue: .float(0))
        case .bool:
            value = sceneValue(from: object["value"], defaultValue: .bool(false))
        case .color:
            value = sceneValue(from: object["value"], defaultValue: .vec3([1, 1, 1]))
        case .combo, .file, .scenetexture, .text, .textinput:
            value = sceneValue(from: object["value"], defaultValue: .string(""))
        case .unknown:
            return nil
        }
        return DynamicValueDescriptor(kind: .static, value: value)
    }

    private func userSetting(from raw: Any?, defaultValue: SceneValue?, runtimeKey: String?, scriptProperty: Bool = false) -> UserSettingDescriptor? {
        if raw == nil {
            guard let defaultValue else { return nil }
            return UserSettingDescriptor(
                value: DynamicValueDescriptor(kind: .static, value: defaultValue),
                propertyName: "",
                condition: nil,
                runtimeKey: runtimeKey
            )
        }

        guard let object = raw as? JSONObject else {
            return UserSettingDescriptor(
                value: DynamicValueDescriptor(kind: .static, value: scriptProperty
                    ? scriptPropertyValue(from: raw) : sceneValue(from: raw, defaultValue: defaultValue)),
                propertyName: "",
                condition: nil,
                runtimeKey: runtimeKey
            )
        }

        let propertyBinding = parsePropertyBinding(object["user"])
        let rawValue = object.keys.contains("value") ? object["value"] : raw
        let baseSceneValue = scriptProperty ? scriptPropertyValue(from: rawValue) : sceneValue(from: rawValue, defaultValue: defaultValue)
        let animation = (object["animation"] as? JSONObject).flatMap(PropertyAnimationDescriptor.parse)
        let baseValue = DynamicValueDescriptor(
            kind: animation == nil ? .static : .animated,
            value: baseSceneValue,
            animation: animation
        )

        let dynamicValue: DynamicValueDescriptor
        if let script = string(in: object, key: "script") {
            let scriptPropertiesObject = object["scriptproperties"] as? JSONObject ?? [:]
            let scriptPropertySettings = scriptPropertiesObject.reduce(into: [String: UserSettingDescriptor]()) { result, entry in
                if entry.value is JSONObject {
                    result[entry.key] = userSetting(from: entry.value, defaultValue: nil, runtimeKey: nil, scriptProperty: true)
                }
            }
            let scriptProperties = scriptPropertiesObject.reduce(into: [String: DynamicValueDescriptor]()) { partialResult, entry in
                partialResult[entry.key] = DynamicValueDescriptor(
                    kind: .static,
                    value: scriptPropertyValue(from: entry.value)
                )
            }
            dynamicValue = DynamicValueDescriptor(
                kind: .scripted,
                value: baseSceneValue,
                scriptSource: script,
                baseValue: baseValue,
                scriptProperties: scriptProperties,
                scriptPropertySettings: scriptPropertySettings
            )
        } else {
            dynamicValue = baseValue
        }

        return UserSettingDescriptor(
            value: dynamicValue,
            propertyName: propertyBinding.name,
            condition: propertyBinding.condition,
            runtimeKey: runtimeKey
        )
    }

    private func parsePropertyBinding(_ raw: Any?) -> (name: String, condition: ConditionDescriptor?) {
        if let name = raw as? String {
            return (name, nil)
        }
        guard let object = raw as? JSONObject,
              let name = string(in: object, key: "name") else {
            return ("", nil)
        }
        let condition = string(in: object, key: "condition").map {
            ConditionDescriptor(name: name, expression: $0)
        }
        return (name, condition)
    }

    private func scriptPropertyValue(from raw: Any?) -> SceneValue {
        if let string = raw as? String {
            // Colors/vectors use the scene format's space-separated encoding.
            // Scalar combo/text values keep their saved JSON type and spacing:
            // notably "0"/"1" are string option IDs, not booleans.
            let components = string.split(whereSeparator: \.isWhitespace)
            if !(2...4).contains(components.count) || !components.allSatisfy({ Double($0) != nil }) {
                return .string(string)
            }
        }
        return sceneValue(from: raw, defaultValue: nil)
    }

    private func sceneValue(from raw: Any?, defaultValue: SceneValue?) -> SceneValue {
        guard let raw else {
            return defaultValue ?? .null
        }

        if raw is NSNull {
            return .null
        }

        if let string = raw as? String {
            return parseStringValue(string, defaultValue: defaultValue)
        }

        if let array = raw as? JSONArray {
            return parseArrayValue(array, defaultValue: defaultValue)
        }

        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            switch defaultValue {
            case .int, .ivec2, .ivec3, .ivec4:
                return .int(number.intValue)
            case .bool:
                return .bool(number.boolValue)
            default:
                if floor(number.doubleValue) == number.doubleValue {
                    return .int(number.intValue)
                }
                return .float(number.doubleValue)
            }
        }

        return defaultValue ?? .null
    }

    private func parseStringValue(_ string: String, defaultValue: SceneValue?) -> SceneValue {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        switch defaultValue {
        case .string:
            return .string(trimmed)
        case .bool:
            return .bool(parseBoolString(trimmed) ?? false)
        case .int:
            return .int(Int(trimmed) ?? 0)
        case .float:
            return .float(Double(trimmed) ?? 0)
        case .vec2(let values):
            return .vec2(adjustedDoubleComponents(trimmed, expected: 2, fallback: values))
        case .vec3(let values):
            return .vec3(adjustedDoubleComponents(trimmed, expected: 3, fallback: values))
        case .vec4(let values):
            return .vec4(adjustedDoubleComponents(trimmed, expected: 4, fallback: values))
        case .ivec2(let values):
            return .ivec2(adjustedIntComponents(trimmed, expected: 2, fallback: values))
        case .ivec3(let values):
            return .ivec3(adjustedIntComponents(trimmed, expected: 3, fallback: values))
        case .ivec4(let values):
            return .ivec4(adjustedIntComponents(trimmed, expected: 4, fallback: values))
        case .null, .none:
            break
        }

        let components = trimmed.split(whereSeparator: \.isWhitespace)
        if components.count >= 2, components.count <= 4,
           components.allSatisfy({ Double($0) != nil }) {
            let values = components.compactMap { Double($0) }
            switch values.count {
            case 2: return .vec2(values)
            case 3: return .vec3(values)
            case 4: return .vec4(values)
            default: break
            }
        }

        if let bool = parseBoolString(trimmed) {
            return .bool(bool)
        }
        if let int = Int(trimmed) {
            return .int(int)
        }
        if let double = Double(trimmed) {
            return .float(double)
        }
        return .string(trimmed)
    }

    private func parseArrayValue(_ array: JSONArray, defaultValue: SceneValue?) -> SceneValue {
        let doubles = array.compactMap { optionalDouble($0) }
        let ints = array.compactMap { optionalInt($0) }

        switch defaultValue {
        case .ivec2(let fallback):
            return .ivec2(adjust(values: ints, expected: 2, fallback: fallback))
        case .ivec3(let fallback):
            return .ivec3(adjust(values: ints, expected: 3, fallback: fallback))
        case .ivec4(let fallback):
            return .ivec4(adjust(values: ints, expected: 4, fallback: fallback))
        case .vec2(let fallback):
            return .vec2(adjust(values: doubles, expected: 2, fallback: fallback))
        case .vec3(let fallback):
            return .vec3(adjust(values: doubles, expected: 3, fallback: fallback))
        case .vec4(let fallback):
            return .vec4(adjust(values: doubles, expected: 4, fallback: fallback))
        default:
            break
        }

        if doubles.count == array.count {
            switch doubles.count {
            case 2: return .vec2(doubles)
            case 3: return .vec3(doubles)
            case 4: return .vec4(doubles)
            default: break
            }
        }

        if ints.count == array.count {
            switch ints.count {
            case 2: return .ivec2(ints)
            case 3: return .ivec3(ints)
            case 4: return .ivec4(ints)
            default: break
            }
        }

        return defaultValue ?? .null
    }

    private func parseProjectType(_ raw: Any?) -> SceneProjectType {
        switch (raw as? String)?.lowercased() {
        case "scene": return .scene
        case "video": return .video
        case "web": return .web
        default: return .unknown
        }
    }

    private func parsePropertyKind(_ raw: String?) -> UserPropertyKind? {
        switch raw?.lowercased() {
        case "slider": return .slider
        case "bool": return .bool
        case "color": return .color
        case "combo": return .combo
        case "text", "usershortcut": return .text
        case "textinput": return .textinput
        case "file": return .file
        case "scenetexture": return .scenetexture
        default: return nil
        }
    }

    private func parseLightType(_ raw: String?) -> Int {
        switch raw?.lowercased() {
        case "lspot": return 1
        case "ltube": return 2
        case "ldirectional", "ldir": return 3
        default: return 0
        }
    }

    private func parseBlendMode(_ raw: String?) -> Int {
        switch raw?.lowercased() {
        case "translucent": return 2
        case "additive": return 3
        default: return 1
        }
    }

    private func parseCullMode(_ raw: String?) -> Int {
        switch raw?.lowercased() {
        case "normal": return 1
        default: return 0
        }
    }

    private func parseDepthMode(_ raw: String?) -> Int {
        switch raw?.lowercased() {
        case "enabled": return 1
        default: return 0
        }
    }

    private func parseEffectCommand(_ raw: String?) -> Int? {
        switch raw?.lowercased() {
        case "copy": return 0
        case "swap": return 1
        default: return nil
        }
    }

    private func nodeKind(for object: JSONObject) -> NodeKind {
        if object["image"] is String || object["model"] is String {
            return .image
        }
        if object["sound"] is JSONArray {
            return .sound
        }
        if object["light"] != nil {
            return .light
        }
        if object["particle"] != nil {
            return .particle
        }
        if object["text"] != nil {
            return .text
        }
        let payloadKeys = ["image", "model", "sound", "light", "particle", "text"]
        if payloadKeys.allSatisfy({ object[$0] == nil }) {
            // Empty transform-only objects act as grouping/anchor nodes.
            return .group
        }
        return .unknown
    }

    private func parseWorkshopID(_ raw: Any?) -> String {
        if let string = raw as? String, !string.isEmpty {
            return string
        }
        if let int = optionalInt(raw) {
            return String(int)
        }
        return "-1"
    }

    func loadJSONObject(path: String, allowAssetsFallback: Bool = true) throws -> JSONObject {
        let content = try loadString(path: path, allowAssetsFallback: allowAssetsFallback)
        let json = try parseRelaxedJSON(content)
        guard let object = json as? JSONObject else {
            throw SceneDescriptionLoaderError.invalidJSON(path)
        }
        return object
    }

    private func loadString(path: String, allowAssetsFallback: Bool = true) throws -> String {
        guard let url = resolveURL(path: path, allowAssetsFallback: allowAssetsFallback) else {
            throw missingAssetError(path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadData(path: String, allowAssetsFallback: Bool = true) throws -> Data {
        guard let url = resolveURL(path: path, allowAssetsFallback: allowAssetsFallback) else {
            throw missingAssetError(path)
        }
        return try Data(contentsOf: url)
    }

    private func missingAssetError(_ path: String) -> SceneDescriptionLoaderError {
        let error = SceneDescriptionLoaderError.fileNotFound(path)
        guard !packageFailures.isEmpty else { return error }
        return .invalidProject(([error.localizedDescription] + packageFailures).joined(separator: "\n"))
    }

    func resolveURL(path: String, allowAssetsFallback: Bool) -> URL? {
        if path.isEmpty {
            return nil
        }

        if let roots = explicitAssetRoots {
            let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)]
                : roots.map { $0.appendingPathComponent(path) }
            return candidates.first { candidate in
                let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                return roots.contains { resolved.path.hasPrefix($0.path + "/") }
                    && fileManager.fileExists(atPath: resolved.path)
            }
        }

        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidates = [wallpaperRoot] + packageRoots + (allowAssetsFallback ? [assetsRoot] : []) + [workingRoot]

        if URL(fileURLWithPath: path).isFileURL,
           fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        for root in candidates {
            let candidate = root.appendingPathComponent(normalized)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func extractMaterialPath(fromModelBinaryAt path: String) -> String? {
        guard let data = try? loadData(path: path) else {
            return nil
        }
        let bytes = [UInt8](data)
        let prefix = Array("materials/".utf8)
        let suffix = Array(".json".utf8)

        guard let start = bytes.firstIndex(where: { _ in true }).flatMap({ _ in
            bytes.indices.first { index in
                index + prefix.count <= bytes.count &&
                Array(bytes[index..<(index + prefix.count)]) == prefix
            }
        }) else {
            return nil
        }

        let searchStart = start + prefix.count
        guard let suffixStart = bytes.indices.first(where: { index in
            index >= searchStart &&
            index + suffix.count <= bytes.count &&
            Array(bytes[index..<(index + suffix.count)]) == suffix
        }) else {
            return nil
        }

        let end = suffixStart + suffix.count
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func parseRelaxedJSON(_ content: String) throws -> Any {
        func parse(_ candidate: String) throws -> Any {
            try JSONSerialization.jsonObject(with: Data(candidate.utf8))
        }
        do {
            return try parse(content)
        } catch {
            let stripped = stripTrailingCommas(in: content)
            if let parsed = try? parse(stripped) {
                return parsed
            }
            let requoted = quoteBareKeys(in: stripped)
            if let parsed = try? parse(requoted) {
                return parsed
            }
            throw error
        }
    }

    private func quoteBareKeys(in content: String) -> String {
        let pattern = #"([\{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return content
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: #"$1"$2"$3"#)
    }

    private func stripTrailingCommas(in content: String) -> String {
        var result = String()
        result.reserveCapacity(content.count)
        var isInString = false
        var isEscaped = false
        for (index, character) in content.enumerated() {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                isInString.toggle()
                result.append(character)
                continue
            }
            if !isInString, character == "," {
                let remainder = content[content.index(content.startIndex, offsetBy: index + 1)...]
                if let next = remainder.first(where: { !$0.isWhitespace }), next == "]" || next == "}" {
                    continue
                }
            }
            result.append(character)
        }
        return result
    }

    private func requiredString(in object: JSONObject, key: String, context: String) -> String {
        string(in: object, key: key) ?? ""
    }

    private func string(in object: JSONObject, key: String) -> String? {
        object[key] as? String
    }

    private func boolValue(_ raw: Any?, default defaultValue: Bool) -> Bool {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number.doubleValue != 0
        }
        if let string = raw as? String {
            return parseBoolString(string) ?? defaultValue
        }
        return defaultValue
    }

    private func parseBoolString(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "enabled": return true
        case "0", "false", "no", "disabled": return false
        default: return nil
        }
    }

    private func intValue(_ raw: Any?, default defaultValue: Int) -> Int {
        optionalInt(raw) ?? defaultValue
    }

    private func optionalInt(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let string = raw as? String {
            return Int(string)
        }
        return nil
    }

    private func doubleValue(_ raw: Any?, default defaultValue: Double) -> Double {
        optionalDouble(raw) ?? defaultValue
    }

    private func optionalDouble(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let string = raw as? String {
            return Double(string)
        }
        return nil
    }

    private func doubleArray(from raw: Any?, default defaultValue: [Double], expectedCount: Int) -> [Double] {
        if let scalar = raw as? NSNumber {
            return Array(repeating: scalar.doubleValue, count: expectedCount)
        }
        if let string = raw as? String {
            let values = string.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if values.count == 1, let scalar = values.first {
                return Array(repeating: scalar, count: expectedCount)
            }
            return adjust(values: values, expected: expectedCount, fallback: defaultValue)
        }
        if let array = raw as? JSONArray {
            return adjust(values: array.compactMap { optionalDouble($0) }, expected: expectedCount, fallback: defaultValue)
        }
        return adjust(values: [], expected: expectedCount, fallback: defaultValue)
    }

    private func intArray(from raw: Any?, default defaultValue: [Int], expectedCount: Int) -> [Int] {
        if let string = raw as? String {
            return adjust(values: string.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }, expected: expectedCount, fallback: defaultValue)
        }
        if let array = raw as? JSONArray {
            return adjust(values: array.compactMap { optionalInt($0) }, expected: expectedCount, fallback: defaultValue)
        }
        return adjust(values: [], expected: expectedCount, fallback: defaultValue)
    }

    private func adjustedDoubleComponents(_ string: String, expected: Int, fallback: [Double]) -> [Double] {
        adjust(values: string.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }, expected: expected, fallback: fallback)
    }

    private func adjustedIntComponents(_ string: String, expected: Int, fallback: [Int]) -> [Int] {
        adjust(values: string.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }, expected: expected, fallback: fallback)
    }

    private func adjust<T>(values: [T], expected: Int, fallback: [T]) -> [T] {
        var result = values
        if result.count > expected {
            result = Array(result.prefix(expected))
        }
        if result.count < expected {
            result.append(contentsOf: fallback.dropFirst(result.count).prefix(expected - result.count))
        }
        if result.isEmpty {
            result = Array(fallback.prefix(expected))
        }
        return result
    }
}

private enum NativeScenePackageParser {
    private struct FileEntry {
        let filename: String
        let offset: Int
        let length: Int
    }

    private struct FileTable {
        let files: [FileEntry]
        let dataOffset: Int
    }

    static func extract(pkgURL: URL, temporaryRoot requestedRoot: URL?) throws -> URL {
        let data = try Data(contentsOf: pkgURL)
        let table = try parseFileTable(data: data)
        // Foundation may ignore TMPDIR on macOS; use the harness's explicit
        // root so even killed/timed-out child processes can be cleaned up.
        let temporaryRoot = requestedRoot ?? ProcessInfo.processInfo.environment["WE_PACKAGE_TEMP_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = temporaryRoot
            .appendingPathComponent("NativeScenePkg-\(pkgURL.lastPathComponent)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }

        for entry in table.files {
            let target = directory.appendingPathComponent(entry.filename).standardizedFileURL
            guard !entry.filename.hasPrefix("/"),
                  target.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
                throw SceneDescriptionLoaderError.invalidProject("Package entry escapes extraction directory: \(entry.filename)")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            let start = table.dataOffset + entry.offset
            let end = start + entry.length
            guard start >= 0, end <= data.count else {
                throw SceneDescriptionLoaderError.invalidProject("Truncated package entry: \(entry.filename)")
            }

            try data[start..<end].write(to: target)
        }

        completed = true
        return directory
    }

    private static func parseFileTable(data: Data) throws -> FileTable {
        var cursor = 0
        let magic = try readSizedString(data: data, cursor: &cursor)
        guard magic.hasPrefix("PKGV") else {
            throw SceneDescriptionLoaderError.invalidProject("Unsupported package header: \(magic)")
        }

        let fileCount = Int(try readUInt32(data: data, cursor: &cursor))
        var files: [FileEntry] = []
        files.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            files.append(
                FileEntry(
                    filename: try readSizedString(data: data, cursor: &cursor),
                    offset: Int(try readUInt32(data: data, cursor: &cursor)),
                    length: Int(try readUInt32(data: data, cursor: &cursor))
                )
            )
        }
        return FileTable(files: files, dataOffset: cursor)
    }

    private static func readUInt32(data: Data, cursor: inout Int) throws -> UInt32 {
        guard cursor + 4 <= data.count else {
            throw SceneDescriptionLoaderError.invalidProject("Unexpected end of package data")
        }
        let slice = data[cursor..<cursor + 4]
        let value = slice.enumerated().reduce(UInt32(0)) { partialResult, element in
            partialResult | (UInt32(element.element) << (UInt32(element.offset) * 8))
        }
        cursor += 4
        return value
    }

    private static func readSizedString(data: Data, cursor: inout Int) throws -> String {
        let length = Int(try readUInt32(data: data, cursor: &cursor))
        guard cursor + length <= data.count else {
            throw SceneDescriptionLoaderError.invalidProject("Unexpected end of package string table")
        }
        let stringData = data[cursor..<cursor + length]
        cursor += length
        guard let value = String(data: stringData, encoding: .utf8) else {
            throw SceneDescriptionLoaderError.invalidProject("Invalid UTF-8 inside package")
        }
        return value
    }
}
