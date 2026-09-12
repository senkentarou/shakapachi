import AppKit

// Entry point. Top-level code in an SPM executable runs before any actor
// context is established, so we use NSApplicationMain-style setup here.
// AppDelegate.init() is nonisolated (no @MainActor on the class), which
// lets us construct it synchronously. The delegate methods are @MainActor
// and are always dispatched by AppKit on the main thread.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
