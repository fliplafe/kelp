import AppKit

// Holding a key repeats it (j in vim, ← in an agent's prompt) instead of opening the accent picker, as in Terminal.
UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
// Kelp has its own tabs: no "Show Tab Bar" / "Merge All Windows" from AppKit's window tabbing.
NSWindow.allowsAutomaticWindowTabbing = false
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
