import Foundation
import NativeSceneRuntime
import Darwin

private struct FixtureInput: Decodable {
    let scriptSource: String
    let baseValue: FrameValue
    let properties: [String: FrameValue]
}

@main
enum ScriptHostFixtureTool {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: ScriptHostFixtureTool <fixture-directory>\n", stderr)
            Darwin.exit(2)
        }

        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let inputURL = fixtureURL.appendingPathComponent("input.json")
        let inputData = try Data(contentsOf: inputURL)
        let input = try JSONDecoder().decode(FixtureInput.self, from: inputData)
        let result = try ScriptHost.shared.evaluate(
            source: input.scriptSource,
            baseValue: input.baseValue,
            properties: input.properties
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
