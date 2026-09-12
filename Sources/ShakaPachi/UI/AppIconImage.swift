// AppIconImage.swift
// The app's own icon, read straight from the bundled AppIcon.icns.
//
// Every in-app surface that shows "us" (onboarding header, About tab) goes
// through here so they all render the icon the app actually ships. Two traps
// this avoids: NSApp.applicationIconImage is served from macOS's IconServices
// cache, which keeps returning a stale icon after the bundled icns changes; and
// hand-drawing a look-alike tile drifts from the shipped artwork as soon as the
// icon is redesigned.

import AppKit

enum AppIconImage {

    /// The shipped app icon. Falls back to the cached/generic icon only when the
    /// bundled resource is missing (e.g. running headless, outside the .app).
    static var bundled: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        // NSApplication.shared (not NSApp, which is nil in unit tests) so this
        // fallback is safe headless as well as in the live app.
        return NSApplication.shared.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }
}
