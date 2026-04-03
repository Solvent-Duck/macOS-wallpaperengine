import AppKit

enum AutomationError: LocalizedError {
    case missingWallpaperPath
    case unsupportedRenderer

    var errorDescription: String? {
        switch self {
        case .missingWallpaperPath:
            return "Automation mode requires a wallpaper path."
        case .unsupportedRenderer:
            return "Automation mode currently supports only scene wallpapers."
        }
    }
}

@MainActor
final class AutomationController {
    private enum Task {
        case screenshot(URL, Int)
        case benchmark(URL, TimeInterval)
    }

    private let tasks: [Task]
    private let completion: (Int32) -> Void
    private weak var windowManager: DesktopWindowManager?
    private var taskIndex = 0

    init(options: LaunchOptions, completion: @escaping (Int32) -> Void) {
        var pendingTasks: [Task] = []
        if let screenshotPath = options.screenshotPath {
            pendingTasks.append(.screenshot(URL(fileURLWithPath: screenshotPath), options.renderFrames))
        }
        if let benchmarkPath = options.benchmarkPath {
            pendingTasks.append(.benchmark(URL(fileURLWithPath: benchmarkPath), options.benchmarkDuration))
        }

        self.tasks = pendingTasks
        self.completion = completion
    }

    func start(with windowManager: DesktopWindowManager) {
        self.windowManager = windowManager
        runNextTask()
    }

    private func runNextTask() {
        guard taskIndex < tasks.count else {
            completion(0)
            return
        }
        guard let windowManager else {
            completion(1)
            return
        }

        let task = tasks[taskIndex]
        taskIndex += 1

        switch task {
        case .screenshot(let outputURL, let frames):
            windowManager.requestScreenshot(outputURL: outputURL, afterFrames: frames) { [weak self] result in
                self?.handle(result)
            }
        case .benchmark(let outputURL, let duration):
            windowManager.requestBenchmark(outputURL: outputURL, duration: duration) { [weak self] result in
                self?.handle(result)
            }
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            runNextTask()
        case .failure(let error):
            print("[Automation] \(error.localizedDescription)")
            completion(1)
        }
    }
}
