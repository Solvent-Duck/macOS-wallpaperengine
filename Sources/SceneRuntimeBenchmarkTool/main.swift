import Darwin
import Foundation
import NativeSceneBridge
import NativeSceneRuntime

private struct RuntimeBenchmarkReport: Codable {
    let wallpaperPath: String
    let sceneTitle: String
    let frames: Int
    let deltaTime: Double
    let nodeCount: Int
    let lightCount: Int
    let materialCount: Int
    let particleSystemCount: Int
    let framePacketAvgMs: Double
    let framePacketP95Ms: Double
    let encodeAvgMs: Double
    let encodeP95Ms: Double
    let packetAvgBytes: Double
    let packetPeakBytes: Int
    let particleDebug: [ParticleDebugSummary]?
}

private struct ParticleDebugSummary: Codable {
    let nodeID: Int
    let liveParticleEstimate: UInt32
    let instanceCount: Int
    let rendererName: String
    let materialReference: String?
    let initializerKinds: [String]
    let operatorKinds: [String]
    let sampleSize: Float?
    let sampleAlpha: Float?
    let samplePosition: [Float]?
}

@main
enum SceneRuntimeBenchmarkTool {
    static func main() throws {
        let configuration = try parseArguments(CommandLine.arguments)
        let description = try SceneDescriptionAdapter.loadSceneDescription(
            wallpaperPath: configuration.wallpaperPath,
            assetsPath: configuration.assetsPath
        )

        let runtime = SceneRuntime(scene: description)
        var packetSamples: [Double] = []
        var encodeSamples: [Double] = []
        var packetSizes: [Int] = []
        let encoder = JSONEncoder()

        var lastPacket = runtime.step(deltaTime: configuration.deltaTime)
        packetSizes.append(try lastPacket.encodedByteSize())

        for _ in 0..<configuration.frames {
            let packetStart = CFAbsoluteTimeGetCurrent()
            let packet = runtime.step(deltaTime: configuration.deltaTime)
            let packetElapsed = (CFAbsoluteTimeGetCurrent() - packetStart) * 1000
            packetSamples.append(packetElapsed)

            let encodeStart = CFAbsoluteTimeGetCurrent()
            let encoded = try encoder.encode(packet)
            let encodeElapsed = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000
            encodeSamples.append(encodeElapsed)
            packetSizes.append(encoded.count)
            lastPacket = packet
        }

        let report = RuntimeBenchmarkReport(
            wallpaperPath: configuration.wallpaperPath,
            sceneTitle: description.metadata.title,
            frames: configuration.frames,
            deltaTime: configuration.deltaTime,
            nodeCount: lastPacket.nodes.count,
            lightCount: lastPacket.lights.count,
            materialCount: lastPacket.materials.count,
            particleSystemCount: lastPacket.particleSystems.count,
            framePacketAvgMs: average(packetSamples),
            framePacketP95Ms: percentile(packetSamples, 0.95),
            encodeAvgMs: average(encodeSamples),
            encodeP95Ms: percentile(encodeSamples, 0.95),
            packetAvgBytes: average(packetSizes.map(Double.init)),
            packetPeakBytes: packetSizes.max() ?? 0,
            particleDebug: configuration.dumpParticles ? lastPacket.particleSystems.map { system in
                let descriptor = description.scene?.nodes.first(where: { $0.id == system.nodeID })?.particle
                return ParticleDebugSummary(
                    nodeID: system.nodeID.rawValue,
                    liveParticleEstimate: system.liveParticleEstimate,
                    instanceCount: system.instances.count,
                    rendererName: system.rendererName,
                    materialReference: system.materialReference,
                    initializerKinds: descriptor?.initializers.map(\.kind) ?? [],
                    operatorKinds: descriptor?.operators.map(\.kind) ?? [],
                    sampleSize: system.instances.first?.size,
                    sampleAlpha: system.instances.first?.color.w,
                    samplePosition: system.instances.first.map { [$0.position.x, $0.position.y, $0.position.z] }
                )
            } : nil
        )

        let output = try JSONEncoder.prettyPrintedSorted.encode(report)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func parseArguments(_ arguments: [String]) throws -> (wallpaperPath: String, assetsPath: String, frames: Int, deltaTime: Double, dumpParticles: Bool) {
        guard arguments.count >= 3 else {
            fputs("usage: SceneRuntimeBenchmarkTool <wallpaper-directory> <assets-path> [--frames N] [--delta-time seconds]\n", stderr)
            Darwin.exit(2)
        }

        let wallpaperPath = arguments[1]
        let assetsPath = arguments[2]
        var frames = 300
        var deltaTime = 1.0 / 60.0
        var dumpParticles = false

        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--frames":
                if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
                    frames = max(value, 1)
                }
                index += 2
            case "--delta-time":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    deltaTime = max(value, 0)
                }
                index += 2
            case "--dump-particles":
                dumpParticles = true
                index += 1
            default:
                index += 1
            }
        }

        return (wallpaperPath, assetsPath, frames, deltaTime, dumpParticles)
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int(ceil(Double(sorted.count) * percentile)) - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}

private extension JSONEncoder {
    static var prettyPrintedSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
