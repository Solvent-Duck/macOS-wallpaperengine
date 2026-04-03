import AppKit

// Disable stdout buffering so logs appear immediately when not attached to a tty
setbuf(stdout, nil)
setbuf(stderr, nil)

let options = LaunchOptions.parse(arguments: CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(launchOptions: options)
app.delegate = delegate

// Menu bar only — no dock icon, no main window
app.setActivationPolicy(.accessory)

if let path = options.wallpaperPath {
    delegate.initialWallpaperPath = path
}

app.run()
