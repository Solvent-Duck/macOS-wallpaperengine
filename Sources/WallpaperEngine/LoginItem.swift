import Foundation

/// Starts the app at login with a per-user LaunchAgent.
///
/// `SMAppService` needs an `.app` bundle; this app runs as a plain SwiftPM
/// executable, so launchd is pointed at the running executable instead.
/// Rebuilding in place keeps the path valid; moving the checkout does not.
struct LoginItem {
    static let label = "local.wallpaperengine.login"

    let agentURL: URL
    let executablePath: String

    init(launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
         executablePath: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]) {
        agentURL = launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
        self.executablePath = executablePath
    }

    var isEnabled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    /// The executable the existing agent launches, if any.
    var registeredExecutablePath: String? {
        guard let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if isEnabled { try FileManager.default.removeItem(at: agentURL) }
            return
        }
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }
}
