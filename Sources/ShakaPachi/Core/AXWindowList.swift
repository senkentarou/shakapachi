// AXWindowList.swift
// Ask an application, over the Accessibility API, which windows it actually has.
// Beginners: you can treat this file as a black box — the rest of the app works without understanding its internals.
// Read the header for *what* it does; skip the *how*.
//
// CGWindowList reports every surface a process owns, and a browser's overlay
// surfaces — media bubbles, picture-in-picture chrome, compositing layers —
// carry the same layer, alpha, size and store type as a real window, so the
// attribute filters in WindowStore cannot tell them apart. The AX window list
// is the app's own answer to "what are my windows", and it is also the list
// Activator matches against: a surface missing from it cannot be raised, only
// app-activated.
//
// Threading: AX calls are synchronous IPC and this runs on the show path, so
// every element messaged here is capped by an explicit messaging timeout and it
// is the caller's job to query as few apps as possible — see
// WindowStore.filterToAXKnownWindows. The timeout is per element, not per
// application: capping the element from AXUIElementCreateApplication does not
// cap the window elements read out of it.

import ApplicationServices
import CoreGraphics

// Private ApplicationServices symbol that maps an AXUIElement to its CGWindowID.
// Declared here as well as in Activator because both need the same AX↔CGWindow
// correlation and neither owns the other. See Activator's header for why the
// private symbol is acceptable.
// (Skippable: private-API plumbing to map a window ID to an AX element.)
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

enum AXWindowList {

    /// Default messaging timeout for one app's window-list read.
    /// Matches Activator's cap: the same unresponsive app blocks either path,
    /// and 50ms is what this codebase already accepts as the worst case.
    static let defaultTimeout: Float = 0.05

    /// The CGWindowIDs `pid` reports over the Accessibility API, or nil when the
    /// app gives no usable answer (AX denied, app unresponsive, no windows
    /// attribute, no element resolved to a window ID).
    ///
    /// nil means "no opinion", never "this app has no windows" — a caller that
    /// treats nil as an empty set would erase every window of an app whose AX
    /// tree it simply failed to read.
    nonisolated static func windowIDs(
        forPID pid: pid_t,
        timeout: Float = defaultTimeout
    ) -> Set<CGWindowID>? {
        let appElement = AXUIElementCreateApplication(pid)

        // Set the messaging timeout BEFORE any attribute read so an
        // unresponsive app cannot stall the switcher's show path.
        AXUIElementSetMessagingTimeout(appElement, timeout)

        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
            let axWindows = rawValue as? [AXUIElement],
            !axWindows.isEmpty
        else {
            return nil
        }

        var ids: Set<CGWindowID> = []
        for axWindow in axWindows {
            // Cap this element too: the timeout on appElement does not reach it,
            // so without this the lookup below waits out the process-wide
            // default instead of `timeout`.
            AXUIElementSetMessagingTimeout(axWindow, timeout)
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &windowID) == .success {
                ids.insert(windowID)
            }
        }
        return ids.isEmpty ? nil : ids
    }
}
