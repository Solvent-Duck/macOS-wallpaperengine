import AppKit
import Darwin
import NativeSceneCompatibility

/// Application delegate managing the menu bar item and desktop window lifecycle.
///
/// This is a menu bar-only app (no dock icon). User-facing state and actions
/// live in `AppModel`; this delegate owns process lifecycle and automation.
/// Desktop windows are created automatically on launch for each connected display.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let windowManager = DesktopWindowManager()
    private let launchOptions: LaunchOptions
    var initialWallpaperPath: String?
    private var automationController: AutomationController?
    private var model: AppModel?
    private var statusBar: StatusBarController?

    private var didTearDownWindowManager = false
    private var didInitiateProcessTermination = false

    init(launchOptions: LaunchOptions) {
        self.launchOptions = launchOptions
        super.init()
        windowManager.automationMode = launchOptions.isAutomation
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowManager.setupWindows()
        print("[WallpaperEngine] Ready — \(NSScreen.screens.count) display(s) detected")

        if launchOptions.isAutomation {
            guard let path = initialWallpaperPath else {
                print("[Automation] \(AutomationError.missingWallpaperPath.localizedDescription)")
                terminateProcess(exitCode: 1)
                return
            }
            Task {
                // A load failure is already logged; automation then reports
                // the missing renderer and exits non-zero.
                try? await windowManager.loadWallpaper(from: URL(fileURLWithPath: path))
                // The delegate lives for the whole process.
                automationController = AutomationController(options: launchOptions) { exitCode in
                    self.terminateProcess(exitCode: exitCode)
                }
                automationController?.start(with: windowManager)
            }
            return
        }

        let model = AppModel(windowManager: windowManager)
        model.onQuit = { [weak self] in self?.terminateProcess(exitCode: 0) }
        self.model = model
        statusBar = StatusBarController(model: model)
        model.loadInitialWallpaper(path: initialWallpaperPath)
        model.startWorkshopMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        performShutdownTeardownIfNeeded()
    }

    private func terminateProcess(exitCode: Int32) {
        guard !didInitiateProcessTermination else { return }
        didInitiateProcessTermination = true

        performShutdownTeardownIfNeeded()
        statusBar?.remove()
        for window in NSApplication.shared.windows {
            window.close()
        }
        fflush(stdout)
        fflush(stderr)
        exit(exitCode)
    }

    private func performShutdownTeardownIfNeeded() {
        guard !didTearDownWindowManager else { return }
        didTearDownWindowManager = true
        windowManager.teardown()
        MetalShaderCompiler.finalizeCompiler()
    }
}
