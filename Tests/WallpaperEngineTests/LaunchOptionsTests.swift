import Testing
@testable import WallpaperEngine

struct LaunchOptionsTests {
    @Test func screenshotTimeKeepsFrameAndBenchmarkSettingsIndependent() {
        let defaults = LaunchOptions.parse(arguments: ["WallpaperEngine", "/scene", "--screenshot", "/capture.png"])
        #expect(defaults.screenshotTime == 0)
        #expect(defaults.renderFrames == 60)
        let options = LaunchOptions.parse(arguments: ["WallpaperEngine", "--screenshot-time", "7.5", "/scene",
            "--screenshot", "/capture.png", "--frames", "2", "--benchmark", "/benchmark.json", "--benchmark-duration", "0.1"])
        #expect(options.wallpaperPath == "/scene")
        #expect(options.isAutomation)
        #expect(options.screenshotPath == "/capture.png")
        #expect(options.screenshotTime == 7.5)
        #expect(options.renderFrames == 2)
        #expect(options.benchmarkDuration == 0.1)
    }

    @Test(arguments: ["-1", "nan", "inf", "-inf", "invalid"])
    func invalidScreenshotTimeDoesNotCreateAnUnreachableCapture(value: String) {
        let options = LaunchOptions.parse(arguments: ["WallpaperEngine", "--screenshot-time", value, "/scene", "--screenshot", "/capture.png"])
        #expect(options.screenshotTime == 0)
        #expect(options.wallpaperPath == "/scene")
        #expect(options.isAutomation)
    }
}
