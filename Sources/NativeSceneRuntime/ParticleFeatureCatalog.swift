import Foundation
import NativeSceneCore

/// Single source of truth for which particle features the native runtime owns.
/// Both the simulation gate in `SceneRuntime` and the renderer support analysis
/// consult this catalog so they can never drift apart.
public enum ParticleFeatureCatalog {
    public static let supportedRenderers: Set<String> = [
        "sprite",
        "spritetrail",
        "rope",
        "ropetrail",
    ]

    public static let supportedEmitters: Set<String> = [
        "boxrandom",
        "sphererandom",
    ]

    public static let supportedInitializers: Set<String> = [
        "lifetimerandom",
        "sizerandom",
        "velocityrandom",
        "colorrandom",
        "rotationrandom",
        "angularvelocityrandom",
        "alpharandom",
        "turbulentvelocityrandom",
        "mapsequencearoundcontrolpoint",
        "remapinitialvalue",
    ]

    public static let supportedOperators: Set<String> = [
        "movement",
        "alphafade",
        "oscillateposition",
        "oscillatealpha",
        "oscillatesize",
        "angularmovement",
        "controlpointattract",
        "sizechange",
        "alphachange",
        "colorchange",
        "turbulence",
        "vortex",
        "boids",
        "collisionquad",
        "collisionplane",
        "remapvalue",
        "capvelocity",
    ]

    public static let supportedChildTypes: Set<String> = [
        "",
        "static",
        "eventfollow",
        "eventspawn",
        "eventdeath",
    ]

    /// Returns the unsupported feature names used by a particle descriptor,
    /// empty when the native simulation fully owns it. Child systems are
    /// checked recursively.
    public static func unsupportedFeatures(in particle: ParticleDescriptor) -> Set<String> {
        var missing: Set<String> = []

        if particle.renderers.isEmpty {
            missing.insert("renderer:none")
        }
        for renderer in particle.renderers where !supportedRenderers.contains(renderer.name.lowercased()) {
            missing.insert("renderer:\(renderer.name.lowercased())")
        }
        for emitter in particle.emitters where !supportedEmitters.contains(emitter.name.lowercased()) {
            missing.insert("emitter:\(emitter.name.lowercased())")
        }
        for initializer in particle.initializers where !supportedInitializers.contains(initializer.kind.lowercased()) {
            missing.insert("initializer:\(initializer.kind.lowercased())")
        }
        for initializer in particle.initializers where initializer.kind.lowercased() == "remapinitialvalue" {
            missing.formUnion(unsupportedRemapFeatures(initializer.parameters, prefix: "initializer:remapinitialvalue"))
        }
        for `operator` in particle.operators where !supportedOperators.contains(`operator`.kind.lowercased()) {
            missing.insert("operator:\(`operator`.kind.lowercased())")
        }
        for `operator` in particle.operators where `operator`.kind.lowercased() == "remapvalue" {
            missing.formUnion(unsupportedRemapFeatures(`operator`.parameters, prefix: "operator:remapvalue"))
        }
        for child in particle.children {
            if !supportedChildTypes.contains(child.type.lowercased()) {
                missing.insert("child:\(child.type.lowercased())")
            }
            for nested in child.particle {
                missing.formUnion(unsupportedFeatures(in: nested))
            }
        }

        return missing
    }

    private static func unsupportedRemapFeatures(_ parameters: [String: UserSettingDescriptor], prefix: String) -> Set<String> {
        var missing: Set<String> = []
        for (key, supported) in [("input", ParticleRemap.inputs), ("output", ParticleRemap.outputs),
                                 ("operation", ParticleRemap.operations), ("transformfunction", ParticleRemap.transforms)] {
            guard let descriptor = parameters[key]?.value,
                  case .string(let name) = descriptor.value else { continue }
            if !supported.contains(name.lowercased()) { missing.insert("\(prefix):\(key):\(name.lowercased())") }
        }
        return missing
    }

    public static func isSupported(_ particle: ParticleDescriptor) -> Bool {
        unsupportedFeatures(in: particle).isEmpty
    }
}
