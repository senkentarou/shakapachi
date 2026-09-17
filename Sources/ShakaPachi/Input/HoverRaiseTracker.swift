// HoverRaiseTracker.swift
// Pure hover-to-raise decision logic — no AppKit dependency, fully testable.
//
// One tick in, one decision out: given where the cursor is and what sits under
// it, decide whether a window should be raised. The caller supplies the hit test
// as a closure so this type stays free of CGWindowList (and of the permissions
// it needs), and so tests can count how often the hit test actually runs.
//
// Three properties shape the state kept here:
//
//   * Dwell — a window is raised only after the cursor has stayed over it for
//     `dwell` seconds. Passing over a window on the way somewhere else never
//     raises it.
//   * Re-arming — after a reset the cursor must MOVE before anything is raised.
//     A reset means hover-raise was suppressed, and the most common reason is a
//     Cmd+Tab switch: the cursor is left wherever it was, quite possibly over
//     some other window, and raising that would undo the switch the user just
//     made. Keyboard wins until the pointer is used again.
//   * Frontmost caching — while the cursor sits inside the bounds of a window
//     that is already frontmost, no hit test runs at all. Nothing can be above
//     a frontmost window, so the cached rectangle cannot be wrong. Below the
//     top the rectangle IS unreliable (another window may overlap it), so the
//     dwell countdown re-runs the hit test on every tick — a handful of calls,
//     ending the moment the window comes forward.

import CoreGraphics
import Foundation

/// What the hit test found under the cursor.
struct HoverHit: Equatable {
    let windowID: CGWindowID
    /// Screen bounds in CGWindowList coordinates (top-left origin).
    let bounds: CGRect
    /// True when this window is the frontmost eligible window on screen.
    let isFrontmost: Bool
}

struct HoverRaiseTracker {

    /// Seconds the cursor must stay over the same window before it is raised.
    /// 0.4s is long enough that crossing a window on the way elsewhere does not
    /// disturb it, and short enough to feel like a direct response.
    static let defaultDwell: TimeInterval = 0.4

    private let dwell: TimeInterval

    /// The window the cursor is believed to be over. When `isFrontmost` is true
    /// the bounds are trusted without re-testing (see the file header).
    private var anchor: HoverHit?
    /// When the cursor first arrived over the current non-frontmost anchor.
    private var dwellStart: TimeInterval?
    /// The window raised during the current hover, so an app that ignores the
    /// raise is not asked again every `dwell` seconds while the cursor rests.
    private var raisedWindowID: CGWindowID?
    /// Where the cursor was on the previous tick, used to detect movement.
    private var lastPoint: CGPoint?
    /// True until the cursor moves again after a reset (see the file header).
    private var needsMovement = true

    init(dwell: TimeInterval = HoverRaiseTracker.defaultDwell) {
        self.dwell = dwell
    }

    /// Stand down. Call whenever hover-raise is suppressed (switcher open, drag
    /// in progress, …) so the dwell starts fresh instead of counting time the
    /// user spent doing something else, and so the pointer has to move before it
    /// takes over again.
    ///
    /// `lastPoint` deliberately survives: it is what "the pointer moved" is
    /// measured against, and the cursor does not teleport while suppressed.
    mutating func reset() {
        clearHover()
        needsMovement = true
    }

    /// Drop the current hover without disarming. Used when the cursor is over
    /// nothing raisable — the desktop, an open menu — which is the pointer being
    /// used normally, not a reason to make the user move it again.
    private mutating func clearHover() {
        anchor = nil
        dwellStart = nil
        raisedWindowID = nil
    }

    /// Advance one poll tick and return the window to raise, or nil.
    ///
    /// - Parameters:
    ///   - point: Cursor position in CGWindowList coordinates (top-left origin).
    ///   - now: Monotonic-enough current time in seconds.
    ///   - probe: Hit test for `point`. Returns nil when the topmost visible
    ///     window there is not an eligible target (a menu, the Dock, the
    ///     desktop). Called at most once per tick, and not at all on the
    ///     frontmost-cache path.
    /// - Returns: The window ID to raise, or nil when nothing should happen.
    mutating func step(
        point: CGPoint,
        now: TimeInterval,
        probe: (CGPoint) -> HoverHit?
    ) -> CGWindowID? {
        // Nothing happens until the pointer is the thing that moved. The first
        // tick after a reset only records where the cursor is.
        let moved = lastPoint.map { $0 != point } ?? false
        lastPoint = point
        if needsMovement {
            guard moved else { return nil }
            needsMovement = false
        }

        // Cheap path: still inside a window that is already at the front.
        if let anchor, anchor.isFrontmost, anchor.bounds.contains(point) {
            return nil
        }

        // Cheap path: the pointer is parked somewhere that raised nothing — the
        // desktop, under a menu — with no countdown running. Only moving it can
        // change that, so do not ask the window server on every tick.
        if !moved, anchor == nil, dwellStart == nil {
            return nil
        }

        guard let hit = probe(point) else {
            clearHover()
            return nil
        }

        if hit.isFrontmost {
            // Already where the user wants it; just remember the rectangle so
            // the cheap path takes over while the cursor stays inside it.
            anchor = hit
            dwellStart = nil
            raisedWindowID = nil
            return nil
        }

        // A different window than last tick restarts the countdown, and clears
        // the raise memory with it. A missing countdown restarts it too — that
        // happens when a window moves out from under its own cached rectangle —
        // but the raise memory survives, so a window that ignored one raise is
        // not asked again until the cursor has been somewhere else.
        if anchor?.windowID != hit.windowID {
            dwellStart = now
            raisedWindowID = nil
        } else if dwellStart == nil {
            dwellStart = now
        }
        anchor = hit

        guard let start = dwellStart, now - start >= dwell else { return nil }
        guard raisedWindowID != hit.windowID else { return nil }

        raisedWindowID = hit.windowID
        dwellStart = nil
        // Treat the window as frontmost from here on: the raise has been asked
        // for, and the cheap path should hold until the cursor leaves it.
        anchor = HoverHit(windowID: hit.windowID, bounds: hit.bounds, isFrontmost: true)
        return hit.windowID
    }
}
