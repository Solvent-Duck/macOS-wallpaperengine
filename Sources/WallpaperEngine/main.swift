import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu bar only — no dock icon, no main window
app.setActivationPolicy(.accessory)

app.run()
