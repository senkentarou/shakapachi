// HoverRaiser.swift
// Raises the window under the cursor while the feature is on (default off).
//
// ── Why a poll timer and not an event tap ─────────────────────────────────
//
// HotkeyTap is the switcher's hot path: its callback must return in about a
// millisecond, and a wedged tap can take the keyboard with it, which is why it
// carries a deadman switch and an auto-recovery path. Mouse movement arrives far
// more often than key events and none of that machinery would be earning its
// keep here, so hover-raise polls instead. A tick that finds the cursor inside
// the frontmost window costs one cursor read and nothing else.
//
// ── What decides the target ────────────────────────────────────────────────
//
// WindowStore.hitTest: the topmost visible window over the cursor, and only when
// that window is one the switcher would list. Everything above it — a menu, the
// Dock, a Mission Control overlay — aborts the tick rather than raising what it
// covers. The raise itself goes through Activator, the same path the switcher
// uses to confirm a selection.
//
// ── What stops it ──────────────────────────────────────────────────────────
//
// See `isSuppressed`. Each condition below is a way for the pointer to be over a
// window without the user asking for that window: mid-switch, mid-drag, during
// authentication, in the moment a Space finishes changing.

import AppKit
import Carbon

@MainActor
final class HoverRaiser {

    // MARK: - Tuning

    /// How often the cursor is sampled. 100ms keeps the response well inside the
    /// dwell window while leaving the idle cost immeasurable.
    static let pollInterval: TimeInterval = 0.1

    /// How long after a Space change hover-raise stays quiet. The cursor lands
    /// wherever it was left, over a window the user has not chosen yet.
    static let spaceChangeLockout: TimeInterval = 1.0

    // MARK: - Dependencies (injected, not owned)

    private let windowStore: WindowStore
    private let activator: Activator
    /// True while the switcher panel is on screen.
    private let isSwitcherVisible: () -> Bool
    /// True while the Accessibility permission is granted (Activator needs it).
    private let isAccessibilityGranted: () -> Bool

    // MARK: - State

    private var tracker = HoverRaiseTracker()
    private var timer: Timer?
    private var spaceObserver: (any NSObjectProtocol)?
    private var lastSpaceChange: TimeInterval = 0

    // MARK: - Init

    init(
        windowStore: WindowStore,
        activator: Activator,
        isSwitcherVisible: @escaping () -> Bool,
        isAccessibilityGranted: @escaping () -> Bool
    ) {
        self.windowStore = windowStore
        self.activator = activator
        self.isSwitcherVisible = isSwitcherVisible
        self.isAccessibilityGranted = isAccessibilityGranted
    }

    deinit {
        timer?.invalidate()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    // MARK: - Lifecycle

    /// Start or stop polling. Safe to call with the same value repeatedly —
    /// AppDelegate calls it on every settings change.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard timer == nil else { return }
        subscribeToSpaceChanges()
        tracker.reset()
        let timer = Timer.scheduledTimer(withTimeInterval: HoverRaiser.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // Let the system coalesce these wakeups with others. Ten wakeups a
        // second cost more in energy than in CPU, and a tick that lands 25ms
        // late is invisible against a 400ms dwell.
        timer.tolerance = HoverRaiser.pollInterval / 4
        self.timer = timer
        NSLog("[ShakaPachi] Hover raise enabled (poll %.0fms)", HoverRaiser.pollInterval * 1000)
    }

    private func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        tracker.reset()
        NSLog("[ShakaPachi] Hover raise disabled")
    }

    /// Note when the active Space changed so the lockout can reference it.
    private func subscribeToSpaceChanges() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastSpaceChange = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    // MARK: - Poll

    private func tick() {
        guard !isSuppressed() else {
            // Whatever the user was doing instead, the dwell should not count
            // the time they spent doing it.
            tracker.reset()
            return
        }
        guard let point = HoverRaiser.cursorLocation() else { return }

        // The tracker decides; the probe result is kept here because raising
        // needs the whole WindowInfo, not just the ID the tracker reports.
        var probed: WindowInfo?
        let raised = tracker.step(point: point, now: CFAbsoluteTimeGetCurrent()) { [windowStore] point in
            guard let result = windowStore.window(at: point) else {
                probed = nil
                return nil
            }
            probed = result.window
            return HoverHit(
                windowID: result.window.windowID,
                bounds: result.window.bounds,
                isFrontmost: result.isFrontmost)
        }

        guard let raised, let target = probed, target.windowID == raised else { return }
        activator.activate(target)
        // Keep MRU in step with what is actually in front, so the next Cmd+Tab
        // opens on the window the user came from rather than one they left
        // behind minutes ago. Deliberately NOT counted in StatsStore: hover
        // raises land continuously, and the switch counter measures the switcher.
        windowStore.recordActivation(target.windowID)
        NSLog(
            "[ShakaPachi] Hover raise: window %u (pid %d, title: %@)",
            target.windowID, target.pid, target.title)
    }

    /// Reasons the cursor can be over a window without the user asking for it.
    private func isSuppressed() -> Bool {
        // Activator needs Accessibility; without it a raise is a no-op anyway.
        if !isAccessibilityGranted() { return true }
        // Mid-switch: the panel is showing a snapshot the user is choosing from.
        if isSwitcherVisible() { return true }
        // The user is in ShakaPachi's own UI (settings, onboarding).
        if NSApp.isActive { return true }
        // Dragging, resizing, or selecting text — the pointer is committed.
        if NSEvent.pressedMouseButtons != 0 { return true }
        // Password prompts and other secure-input sessions: the same rule the
        // event tap follows (SafetyGuard), applied to raising instead of keys.
        if SafetyGuard.isSecureInputPassthrough(isSecureInputEnabled: IsSecureEventInputEnabled()) {
            return true
        }
        // The Space just changed under a stationary cursor.
        if CFAbsoluteTimeGetCurrent() - lastSpaceChange < HoverRaiser.spaceChangeLockout { return true }
        return false
    }

    /// The cursor in CGWindowList coordinates (top-left origin), which is what
    /// WindowInfo.bounds uses. NSEvent.mouseLocation is bottom-left origin and
    /// would need a per-display flip to compare against those bounds.
    private static func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }
}
