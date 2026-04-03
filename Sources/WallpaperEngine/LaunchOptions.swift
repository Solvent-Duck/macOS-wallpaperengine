import Foundation

struct LaunchOptions {
    let wallpaperPath: String?
    let screenshotPath: String?
    let benchmarkPath: String?
    let renderFrames: Int
    let benchmarkDuration: TimeInterval

    var isAutomation: Bool {
        screenshotPath != nil || benchmarkPath != nil
    }

    static func parse(arguments: [String]) -> LaunchOptions {
        var wallpaperPath: String?
        var screenshotPath: String?
        var benchmarkPath: String?
        var renderFrames = 60
        var benchmarkDuration: TimeInterval = 5

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--screenshot":
                if index + 1 < arguments.count {
                    screenshotPath = arguments[index + 1]
                    index += 1
                }
            case "--benchmark":
                if index + 1 < arguments.count {
                    benchmarkPath = arguments[index + 1]
                    index += 1
                }
            case "--frames":
                if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
                    renderFrames = max(value, 1)
                    index += 1
                }
            case "--benchmark-duration":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                    benchmarkDuration = max(value, 0.1)
                    index += 1
                }
            default:
                if !argument.hasPrefix("--") && wallpaperPath == nil {
                    wallpaperPath = argument
                }
            }

            index += 1
        }

        return LaunchOptions(
            wallpaperPath: wallpaperPath,
            screenshotPath: screenshotPath,
            benchmarkPath: benchmarkPath,
            renderFrames: renderFrames,
            benchmarkDuration: benchmarkDuration
        )
    }
}
