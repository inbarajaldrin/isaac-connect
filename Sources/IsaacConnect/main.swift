// Entry point. Top-level executable statements must live in main.swift; the app
// itself is assembled by AppDelegate.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
