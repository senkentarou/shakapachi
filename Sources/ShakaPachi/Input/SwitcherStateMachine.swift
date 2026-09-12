// SwitcherStateMachine.swift
// Pure deterministic state machine for window-switcher input.
// No AppKit or CoreGraphics dependency — fully unit-testable.
//
// Transition diagram:
//   IDLE + modifierDown            → MODIFIER_HELD                (not consumed)
//   MODIFIER_HELD + trigger        → ACTIVE(index=next, count)    (consumed)
//   MODIFIER_HELD + trigger(shift) → ACTIVE(index=current, count) (consumed)
//   MODIFIER_HELD + modifierUp     → IDLE                         (not consumed)
//   ACTIVE + trigger               → advance index                (consumed)
//   ACTIVE + trigger(shift)        → retreat index                (consumed)
//   ACTIVE + arrowForward/Back     → advance/retreat index        (consumed)
//   ACTIVE + escape                → cancel → IDLE                (consumed)
//   ACTIVE + sameAppJump           → jump via resolver            (consumed)
//   ACTIVE + otherKey              → no-op, NOT consumed
//   ACTIVE + modifierUp            → confirmSelection → IDLE      (not consumed)

import Foundation

// MARK: - Switcher input events (abstract, AppKit-free)

/// Abstract input events delivered to SwitcherStateMachine.
/// HotkeyTap translates concrete CGEvent/keycode data into these.
enum SwitcherInput: Equatable {
    /// The trigger modifier key (Option in dev default) went down.
    case modifierDown
    /// The trigger modifier key was released.
    case modifierUp
    /// The trigger key (Tab) was pressed; shift indicates Shift+Tab.
    case trigger(shift: Bool)
    // Arrows carry the physical direction rather than a forward/backward
    // meaning: app-unit mode maps the two axes to different things (horizontal
    // moves within a row, vertical crosses between rows), which a pre-collapsed
    // forward/backward pair cannot express. Flat mode collapses them again below.
    case arrowRight
    case arrowLeft
    case arrowDown
    case arrowUp
    /// A number-row key 1...9, used to jump straight to a visible window pane.
    case digit(Int)
    /// Escape key: cancel and hide the panel.
    case escape
    /// Grave accent (`): jump to the next window of the same app.
    case sameAppJump
    /// Any other key — must NOT be consumed (passed through to the front app).
    case otherKey
}

// MARK: - Switcher actions (caller executes these)

/// Actions that the caller (AppDelegate) must execute in response to
/// a state-machine transition. Equatable so tests can assert on them.
enum SwitcherAction: Equatable {
    /// No action required (and may mean the event was not consumed).
    case none
    /// Show the panel with the given initial selection index.
    case showPanel(initialIndex: Int)
    /// Move the highlight to a new index without rebuilding the list.
    case moveSelection(to: Int)
    /// Confirm the selection (Activator raises the window).
    case confirmSelection(index: Int)
    /// Cancel: hide the panel without activating anything.
    case cancel
}

// MARK: - State machine states

private enum State: Equatable {
    case idle
    case modifierHeld
    case active(index: Int, count: Int)
}

// MARK: - SwitcherStateMachine

/// Deterministic state machine for the window switcher.
///
/// Usage:
/// ```swift
/// let machine = SwitcherStateMachine()
/// let (action, consumed) = machine.handle(.trigger(shift: false), itemCount: items.count)
/// ```
///
/// `itemCount` is only used when transitioning MODIFIER_HELD → ACTIVE (the
/// "show" transition). Pass 0 for all other inputs — it is ignored.
///
/// `sameAppResolver` is injected at construction time and is called (with
/// the current index) when a `sameAppJump` input arrives in the ACTIVE state.
/// It returns the next index for the same app, or nil if there is none.
/// Keeping the resolver injectable makes the machine fully unit-testable.
final class SwitcherStateMachine {

    // MARK: - Init

    /// - Parameter sameAppResolver: Called with the current index; returns the
    ///   next same-app index or nil when no other window of the same app exists.
    init(sameAppResolver: ((Int) -> Int?)? = nil) {
        self.sameAppResolver = sameAppResolver
    }

    // MARK: - State

    private var state: State = .idle

    /// Resolver for `sameAppJump` input. Injected so tests can control it.
    var sameAppResolver: ((Int) -> Int?)?

    /// Overrides where the selection starts when the panel is shown, given the
    /// item count and whether the show was triggered with Shift held (Shift =
    /// start on the current item; no Shift = start on the next one). Injected
    /// by the caller for app-unit mode, where "one tap returns to the previous
    /// thing" means the previous APP rather than the previous window, and that
    /// item is not at flat index 1.
    var initialIndexProvider: ((Int, Bool) -> Int)?

    /// Takes over every movement input while set, mapping an input and the
    /// current flat index to a new flat index (nil = stay put).
    ///
    /// App-unit mode installs one because its cursor moves across two axes,
    /// which the flat ±1 arithmetic below cannot express. Left unset, the
    /// machine keeps its original flat behaviour verbatim.
    var navigator: ((SwitcherInput, Int) -> Int?)?

    /// Inputs the navigator owns when one is installed. Escape, modifier
    /// transitions and pass-through keys keep their meaning in every mode, so
    /// they are deliberately absent.
    private static func isMovement(_ input: SwitcherInput) -> Bool {
        switch input {
        case .trigger, .arrowRight, .arrowLeft, .arrowDown, .arrowUp, .digit, .sameAppJump:
            return true
        case .escape, .modifierDown, .modifierUp, .otherKey:
            return false
        }
    }

    // MARK: - Public API

    /// Process one input event.
    ///
    /// - Parameters:
    ///   - input: The abstract switcher event.
    ///   - itemCount: Number of items available. Only meaningful on the
    ///     `trigger` input that causes MODIFIER_HELD → ACTIVE. Pass 0 otherwise.
    /// - Returns: The action the caller should execute, and whether the
    ///   underlying key event should be consumed (returned nil to the system).
    @discardableResult
    func handle(_ input: SwitcherInput, itemCount: Int = 0) -> (action: SwitcherAction, consumed: Bool) {
        switch state {

        // ── IDLE ──────────────────────────────────────────────────────────
        case .idle:
            switch input {
            case .modifierDown:
                state = .modifierHeld
                // The modifier key itself is never consumed.
                return (.none, false)
            default:
                // All other inputs in IDLE are irrelevant; pass through.
                return (.none, false)
            }

        // ── MODIFIER_HELD ─────────────────────────────────────────────────
        case .modifierHeld:
            switch input {
            case .trigger(let shift):
                // Build the list and show the panel.
                // Shift+Tab starts on the current item (index 0 — "where am I");
                // Tab starts on the next one (index 1 when count ≥ 2, else 0 —
                // there is nowhere else to go with a single window).
                let count = itemCount
                guard count > 0 else {
                    // No windows — stay in MODIFIER_HELD, consume the key.
                    return (.none, true)
                }
                let initialIndex =
                    initialIndexProvider.map { $0(count, shift) } ?? (shift ? 0 : (count >= 2 ? 1 : 0))
                state = .active(index: initialIndex, count: count)
                return (.showPanel(initialIndex: initialIndex), true)

            case .modifierUp:
                state = .idle
                // Releasing the modifier is not consumed.
                return (.none, false)

            default:
                // Any other key in MODIFIER_HELD passes through.
                return (.none, false)
            }

        // ── ACTIVE ────────────────────────────────────────────────────────
        case .active(let index, let count):
            // Movement is delegated wholesale when a navigator is installed:
            // its cursor, not this index, decides where the selection lands.
            // Consumed either way — a defined transition swallows the key even
            // when the cursor cannot move any further.
            if let navigator, Self.isMovement(input) {
                let newIndex = navigator(input, index) ?? index
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)
            }

            switch input {
            case .trigger(let shift):
                let newIndex: Int
                if shift {
                    // Shift+Tab: go backward.
                    newIndex = (index - 1 + count) % count
                } else {
                    // Tab: go forward.
                    newIndex = (index + 1) % count
                }
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .arrowRight, .arrowDown:
                // Flat mode has one axis, so both directions collapse to advance.
                let newIndex = (index + 1) % count
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .arrowLeft, .arrowUp:
                let newIndex = (index - 1 + count) % count
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .digit:
                // Flat mode has nothing to number, so the key belongs to the
                // front app (a held modifier plus a digit is a real shortcut there).
                return (.none, false)

            case .escape:
                state = .idle
                return (.cancel, true)

            case .sameAppJump:
                // Ask the resolver for the next same-app index.
                // If nil (no other window of the same app), stay put.
                // Either way the key is consumed (it's a defined transition).
                let newIndex = sameAppResolver?(index) ?? index
                state = .active(index: newIndex, count: count)
                return (.moveSelection(to: newIndex), true)

            case .otherKey:
                // Undefined keys are NOT consumed — pass them to the front app.
                return (.none, false)

            case .modifierUp:
                // Modifier release: confirm selection, hide panel, → IDLE.
                // Releasing the modifier is not consumed.
                state = .idle
                return (.confirmSelection(index: index), false)

            case .modifierDown:
                // Modifier down while active is unexpected; ignore, pass through.
                return (.none, false)
            }
        }
    }

    /// Reset to idle (e.g. when the tap is disabled externally).
    func reset() {
        state = .idle
    }

    /// Read-only current state description for debugging.
    var isIdle: Bool { state == .idle }
    var isModifierHeld: Bool { state == .modifierHeld }
    var isActive: Bool {
        if case .active = state { return true }
        return false
    }
    /// The current selection index when active, or nil otherwise.
    var activeIndex: Int? {
        if case .active(let idx, _) = state { return idx }
        return nil
    }
}
