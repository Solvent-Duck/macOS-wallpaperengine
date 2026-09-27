import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

func particleScene(
    emitters: [[String: Any]], operators: [[String: Any]] = [],
    initializers: [[String: Any]] = [], count: Int = 2048, startTime: Int = 0,
    controlPoints: [[String: Any]] = [], instanceOverrides: [String: Any] = [:],
    nodeSettings: [String: Any] = [:], properties: [String: Any] = [:],
    childParticle: [String: Any]? = nil, childType: String = "eventspawn",
    grandchildParticle: [String: Any]? = nil, general: [String: Any] = [:],
    additionalNodes: [[String: Any]] = []
) throws -> SceneDescription {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEParticles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var particle: [String: Any] = [
        "maxcount": count, "starttime": startTime, "emitter": emitters, "operator": operators, "controlpoint": controlPoints,
        "initializer": [["name": "lifetimerandom", "min": 100, "max": 100],
                        ["name": "sizerandom", "min": 2, "max": 2]] + initializers,
        "renderer": [["name": "sprite"]]
    ]
    if var childParticle {
        if let grandchildParticle {
            try JSONSerialization.data(withJSONObject: grandchildParticle).write(to: root.appendingPathComponent("grandchild.json"))
            childParticle["children"] = [["name": "grandchild.json", "type": "eventspawn"]]
        }
        try JSONSerialization.data(withJSONObject: childParticle).write(to: root.appendingPathComponent("child.json"))
        particle["children"] = [["name": "child.json", "type": childType]]
    }
    var node = nodeSettings
    node["id"] = 1
    node["particle"] = particle
    if !instanceOverrides.isEmpty { node["instanceoverride"] = instanceOverrides }
    let scene: [String: Any] = ["camera": [:], "general": general, "objects": additionalNodes + [node]]
    try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json", "general": ["properties": properties]]).write(to: root.appendingPathComponent("project.json"))
    try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
    return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
}

func testParticle(position: SIMD3<Float> = .zero, velocity: SIMD3<Float> = .zero, age: Float = 0) -> ParticleInstanceState {
    ParticleInstanceState(position: position, velocity: velocity, rotation: .zero, angularVelocity: .zero,
                          color: SIMD4(repeating: 1), size: 1, lifetime: 10, age: age,
                          initial: ParticleInitialState(color: SIMD4(repeating: 1), size: 1, lifetime: 10))
}
