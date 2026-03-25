import AppKit

// Disable stdout buffering so logs appear immediately when not attached to a tty
setbuf(stdout, nil)
setbuf(stderr, nil)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu bar only — no dock icon, no main window
app.setActivationPolicy(.accessory)

// Support loading a wallpaper from a CLI argument
if CommandLine.arguments.count > 1 {
    let path = CommandLine.arguments[1]
    delegate.initialWallpaperPath = path
}

app.run()
