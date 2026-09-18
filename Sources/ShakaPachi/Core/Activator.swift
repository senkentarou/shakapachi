// Activator.swift
// Raise a specific window via the Accessibility API.
// Beginners: you can treat this file as a black box — the rest of the app works without understanding its internals.
// Read the header for *what* it does; skip the *how*.
//
// The CGWindowID↔AXUIElement mapping is inherently ambiguous (no public
// direct-lookup API exists). The matching logic tries title first, then bounds
// within a 2-point tolerance, and falls back to app-only activation when
// neither produces a single confident match.
//
// Threading: AX calls are synchronous IPC and must not block the main thread.
// The event tap's run-loop source is attached to the main run loop and its
// callback invokes onSwitcherInput synchronously to decide whether to consume
// the key, so confirm reaches activate() from inside that callback: anything
// blocking here stalls the whole system's input stream until the tap is
// disabled by timeout. The AX work therefore runs on a private serial queue
// and activate() returns immediately. Only NSRunningApplication.activate()
// stays on the caller's thread — it is AppKit, it is cheap, and it is what
// actually moves focus.
//
// The messaging timeout is per element, not per application: setting it on the
// element returned by AXUIElementCreateApplication bounds only the calls made
// on that element, so every window element read out of it is capped
// individually before it is messaged.

import AppKit
import ApplicationServices

// Private ApplicationServices symbol that maps an AXUIElement directly to its
// CGWindowID — the definitive AX↔CGWindow correlation the public API omits.
// This is the same private API AltTab/Hammerspoon/yabai rely on. It is
// an Apple framework symbol (not a third-party dependency) but is undocumented
// and could change across macOS releases, so title/bounds matching remains as
// a fallback. Using it does not cost App Store eligibility: this app already
// cannot be sandboxed (raising one specific window of another app through the
// AX API below is incompatible with the App Sandbox), so the App Store was
// never viable regardless.
// (Skippable: private-API plumbing to map a window ID to an AX element.)
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

@MainActor
final class Activator {

    /// Messaging timeout applied to every AX element this file talks to.
    /// nonisolated because raise() reads it off the main actor.
    private nonisolated static let messagingTimeout: Float = 0.05

    /// Serial so two confirms in a row cannot interleave their AX work, and so a
    /// slow app delays the next raise rather than the event tap.
    private static let axQueue = DispatchQueue(label: "com.senkentarou.shakapachi.activator")

    // MARK: - Public entry point

    /// Raise `window` to the front using the Accessibility API.
    ///
    /// Returns as soon as the app is activated; the specific-window raise is
    /// handed to a background queue because it is synchronous IPC and this is
    /// called from inside the event-tap callback.
    func activate(_ window: WindowInfo) {
        // Activate the app first so it is at least frontmost even if the
        // specific-window raise below falls back to app-only.
        // Why not activate(from:options:) (the macOS 14 replacement):
        // cooperative activation expects the yielding app to be active, which
        // a non-activating switcher panel never is — keep the legacy call
        // until the new path is verified to transfer focus on macOS 14+.
        NSRunningApplication(processIdentifier: window.pid)?.activate()

        Activator.axQueue.async {
            Activator.raise(window)
        }
    }

    // MARK: - AX raise (off the main thread)

    /// Find `window`'s AX element and raise it. Runs on `axQueue`.
    private nonisolated static func raise(_ window: WindowInfo) {
        let pid = window.pid
        let appElement = AXUIElementCreateApplication(pid)

        // Set the messaging timeout BEFORE any attribute read.
        // This prevents an unresponsive app from stalling the raise queue.
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        // Copy the array of window AX elements.
        var rawValue: CFTypeRef?
        let attrResult = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &rawValue)
        guard attrResult == .success,
            let axWindows = rawValue as? [AXUIElement],
            !axWindows.isEmpty
        else {
            NSLog(
                "[ShakaPachi] Activate: fallback – app activate only " + "(failed to read kAXWindowsAttribute, pid %d)",
                pid)
            return
        }

        // The timeout set on appElement does not carry over to the elements read
        // out of it, so cap each one before it is messaged below. Without this
        // every per-window call falls back to the process-wide default, which is
        // seconds long — an app that answers slowly then blocks this whole path.
        for axWin in axWindows {
            AXUIElementSetMessagingTimeout(axWin, messagingTimeout)
        }

        // Primary path: match the exact window by CGWindowID via the private
        // _AXUIElementGetWindow. This is definitive and immune to the title
        // heuristics' failure modes (Chrome truncates/badges its window name and
        // maximizes every window to identical bounds).
        var targetWin: AXUIElement?
        var matchStrategy = "windowID"
        for axWin in axWindows {
            var axWinID: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &axWinID) == .success,
                axWinID == window.windowID
            {
                targetWin = axWin
                break
            }
        }

        // Fallback path: if the private API produced no match, fall back to the
        // pure title/bounds matcher. Match against the RAW window name
        // (no "(2)" suffix, no app-name fallback) since AX titles carry neither.
        if targetWin == nil {
            var candidates: [(title: String, bounds: CGRect)] = []
            for axWin in axWindows {
                candidates.append((title: axTitle(of: axWin), bounds: axBounds(of: axWin)))
            }
            let matchTitle = window.rawTitle.isEmpty ? window.title : window.rawTitle
            if let matchedIndex = Activator.matchWindow(
                title: matchTitle,
                bounds: window.bounds,
                candidates: candidates
            ) {
                targetWin = axWindows[matchedIndex]
                matchStrategy = "title/bounds"
            }
        }

        guard let targetWin else {
            // Fallback: app activation already done above; no specific window matched.
            NSLog("[ShakaPachi] Activate: fallback – app activate only " + "(ambiguous or no match, pid %d)", pid)
            return
        }

        AXUIElementPerformAction(targetWin, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            targetWin,
            kAXMainAttribute as CFString,
            kCFBooleanTrue)

        NSLog("[ShakaPachi] Activate: raised window by %@ (pid %d)", matchStrategy, pid)
    }

    // MARK: - Pure decision (testable)

    /// Identify the best candidate index from a list of (title, bounds) pairs.
    ///
    /// Matching priority (extended for real-world AX titles):
    /// 1. Exactly one candidate whose title EXACTLY equals `title`.
    /// 2. Exactly one candidate whose title is prefix-compatible with `title` —
    ///    the AX title starts with the target, or vice versa. This handles apps
    ///    (Chrome, Slack, …) whose AX title extends the CGWindowList name, e.g.
    ///    target "注文履歴" (order history) vs AX "注文履歴 - Google Chrome - Profile".
    /// 3. If a prefix match is still ambiguous, disambiguate those candidates by
    ///    bounds within a 2pt tolerance.
    /// 4. Otherwise fall back to a pure bounds match within 2pt.
    /// 5. If still ambiguous or no match: return nil → fallback to app-only.
    ///
    /// Chrome windows are frequently maximized to identical bounds, so bounds
    /// alone cannot disambiguate them — the prefix step is what resolves them.
    ///
    /// This function is deliberately pure (no AX / AppKit calls) so it can be
    /// exhaustively unit-tested without TCC permissions.
    ///
    /// - Parameters:
    ///   - title: The raw window name to match (no "(2)" suffix; may be empty).
    ///   - bounds: The `CGRect` bounds from `WindowInfo` (CGWindowList coords,
    ///     top-left origin in global screen space).
    ///   - candidates: AX-read attributes marshalled to plain values.
    /// - Returns: The index of the matched candidate, or nil when no confident
    ///   match can be made.
    nonisolated static func matchWindow(
        title: String,
        bounds: CGRect,
        candidates: [(title: String, bounds: CGRect)]
    ) -> Int? {

        let tolerance: CGFloat = 2.0
        func boundsMatches(_ i: Int) -> Bool {
            let c = candidates[i].bounds
            return abs(c.origin.x - bounds.origin.x) <= tolerance && abs(c.origin.y - bounds.origin.y) <= tolerance
                && abs(c.width - bounds.width) <= tolerance && abs(c.height - bounds.height) <= tolerance
        }

        if !title.isEmpty {
            // Exact title match.
            let exact = candidates.indices.filter { candidates[$0].title == title }
            if exact.count == 1 { return exact[0] }

            // Prefix-compatible match (ignoring empty AX titles).
            let prefix = candidates.indices.filter { i in
                let c = candidates[i].title
                return !c.isEmpty && (c.hasPrefix(title) || title.hasPrefix(c))
            }
            if prefix.count == 1 { return prefix[0] }

            // Multiple prefix matches — disambiguate by bounds.
            if prefix.count > 1 {
                let narrowed = prefix.filter(boundsMatches)
                if narrowed.count == 1 { return narrowed[0] }
            }
            // Fall through to pure bounds when title didn't resolve.
        }

        // Pure bounds match within 2pt tolerance.
        // AX kAXPosition reports the top-left corner in global screen coordinates,
        // which matches CGWindowList bounds — both use the same coordinate origin.
        let boundsOnly = candidates.indices.filter(boundsMatches)
        if boundsOnly.count == 1 {
            return boundsOnly[0]
        }

        // Ambiguous or no match — return nil for fallback.
        return nil
    }

    // MARK: - AX attribute marshalling (impure; stays outside the pure matcher)

    /// Read `kAXTitleAttribute` from an AX window element, returning "" on failure.
    private nonisolated static func axTitle(of element: AXUIElement) -> String {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXTitleAttribute as CFString, &raw) == .success,
            let title = raw as? String
        else {
            return ""
        }
        return title
    }

    /// Reconstruct a `CGRect` from `kAXPositionAttribute` + `kAXSizeAttribute`.
    ///
    /// Both attributes carry `AXValue` wrappers around `CGPoint`/`CGSize`.
    /// Returns `.zero` when either attribute is unavailable.
    private nonisolated static func axBounds(of element: AXUIElement) -> CGRect {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &posRaw) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRaw) == .success
        else {
            return .zero
        }

        guard let posValue = posRaw,
            let sizeValue = sizeRaw
        else {
            return .zero
        }

        var point = CGPoint.zero
        var size = CGSize.zero

        // Verify the CF type before casting: a misbehaving app could return a
        // non-AXValue for these attributes. `as?` won't help — the compiler
        // treats any downcast to the CF type AXValue as always-succeeding — so we
        // check the runtime type id explicitly, then the force cast is genuinely
        // safe. On a bad value we fall back to .zero, which just makes this
        // candidate fail the bounds match (title match / app-only fallback still
        // apply).
        guard CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return .zero
        }
        let posAX = posValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        AXValueGetValue(posAX, .cgPoint, &point)
        AXValueGetValue(sizeAX, .cgSize, &size)

        return CGRect(origin: point, size: size)
    }
}
