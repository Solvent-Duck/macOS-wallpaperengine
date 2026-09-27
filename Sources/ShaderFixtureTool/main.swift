import Darwin
import Foundation
import NativeSceneCompatibility

private struct FixtureManifest: Decodable {
    let shaderPath: String
    let combos: [String: Int]?
    let overrideCombos: [String: Int]?
}

@main
enum ShaderFixtureTool {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            fputs("usage: ShaderFixtureTool <fixture-directory>\n", stderr)
            Darwin.exit(2)
        }

        let fixtureURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let manifestURL = fixtureURL.appending(path: "fixture.json", directoryHint: .notDirectory)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: manifestData)

        let compiled = try ShaderPipeline.compile(
            ShaderCompilationRequest(
                shaderPath: manifest.shaderPath,
                assetRoots: [fixtureURL],
                combos: manifest.combos ?? [:],
                overrideCombos: manifest.overrideCombos ?? [:]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(compiled)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
