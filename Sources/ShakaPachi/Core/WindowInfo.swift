import CoreGraphics
import Foundation

// WindowInfo is the pure value model for a single on-screen window.
// All fields are resolved at enumeration time; the UI layer consumes this
// struct directly without touching CGWindowList or NSRunningApplication.
struct WindowInfo: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// Display title with fallback and duplicate-suffix already applied.
    let title: String
    /// The raw kCGWindowName before app-name fallback and duplicate suffixing.
    /// Empty when the window has no name. Used by the Activator to match against
    /// AX window titles, which carry no "(2)" suffix and often extend the raw
    /// name (e.g. Chrome: "Page - Google Chrome - Profile").
    let rawTitle: String
    let bounds: CGRect

    init(
        windowID: CGWindowID,
        pid: pid_t,
        bundleID: String?,
        appName: String,
        title: String,
        rawTitle: String = "",
        bounds: CGRect
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.rawTitle = rawTitle
        self.bounds = bounds
    }
}
