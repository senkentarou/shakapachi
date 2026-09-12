// HotkeyTap.swift
// CGEventTap lifecycle wired to the safety mechanisms.
// Beginners: you can treat this file as a black box — the rest of the app works without understanding its internals.
// Read the header for *what* it does; skip the *how*.
//
// Callback absolute rules: no blocking work, no unbounded loops, return within
// 1ms. Logging and UI updates are deferred to the main queue; only tapEnable()
// calls happen synchronously inside the callback.
//
// All methods must be called on the main thread. The tap's run-loop source
// is attached to the main run loop, so the callback also runs there.

import AppKit
import Carbon

final class HotkeyTap {

    enum State {
        case active
        case stopped(reason: String)
    }

    /// Notified on enable/disable so the status item can reflect tap state.
    /// Always called on the main queue.
    var onStateChange: ((State) -> Void)?

    /// Called on the main queue when Option+Tab keyDown is captured.
    /// The argument is the CFAbsoluteTime recorded at the very top of the
    /// tap callback — before any other work — so callers can measure N1.
    /// NOTE: kept for backward compatibility but superseded by onSwitcherInput.
    var onTrigger: ((CFAbsoluteTime) -> Void)?

    /// Called on the main queue when the Option modifier is released while
    /// the switcher panel is visible.
    /// NOTE: kept for backward compatibility but superseded by onSwitcherInput.
    var onModifierReleased: (() -> Void)?

    /// Delivers an abstract SwitcherInput to the state machine on the main queue.
    /// The closure returns true if the event should be consumed (nil to system).
    /// t0 is the tap-entry timestamp so callers can measure N1 on the first trigger.
    var onSwitcherInput: ((SwitcherInput, CFAbsoluteTime) -> Bool)?

    // MARK: - Configurable trigger
    //
    // AppDelegate updates these plain stored values from Settings.shared whenever
    // the user changes triggerModifier or triggerKey. Reading them inside the
    // tap callback is safe and fast — no AppKit/Settings calls in the hot path.

    /// The CGEventFlags mask for the configured trigger modifier.
    /// Updated by AppDelegate when Settings.triggerModifier changes.
    var triggerModifierMask: UInt64 = TriggerModifier.option.eventFlagMask

    /// The CGKeyCode for the configured trigger key.
    /// Updated by AppDelegate when Settings.triggerKey changes.
    var triggerKeyCode: UInt16 = TriggerKey.tab.keyCode

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isEnabled = false

    #if DEBUG
        private var deadman: DeadmanSwitch?
    #endif

    // MARK: - Lifecycle

    deinit {
        // Remove the run-loop source before the port is invalidated so the
        // run loop does not hold a dangling reference.
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        // Disable and invalidate the tap so no further events are delivered
        // after this object is deallocated.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    /// Creates (if needed) and enables the tap. Returns false when the tap
    /// cannot be created — typically missing accessibility permission.
    @discardableResult
    func enable() -> Bool {
        if eventTap == nil {
            let mask: CGEventMask =
                (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,  // ahead of the system App Switcher
                    options: .defaultTap,  // must consume, listenOnly is not enough
                    eventsOfInterest: mask,
                    callback: hotkeyTapCallback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                )
            else {
                NSLog("[ShakaPachi] Failed to create event tap — accessibility permission missing?")
                return false
            }
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        isEnabled = true
        armDeadman()
        NSLog(
            "[ShakaPachi] Event tap enabled (triggerModifierMask=0x%llx, triggerKeyCode=%u)",
            triggerModifierMask, triggerKeyCode)
        onStateChange?(.active)
        return true
    }

    /// Disables the tap. The mach port is kept so enable() can re-arm cheaply.
    func disable(reason: String) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        isEnabled = false
        disarmDeadman()
        NSLog("[ShakaPachi] Event tap disabled (%@)", reason)
        onStateChange?(.stopped(reason: reason))
    }

    // MARK: - Deadman switch (DEBUG only)

    private func armDeadman() {
        #if DEBUG
            deadman?.disarm()
            let dm = DeadmanSwitch { [weak self] in
                // Fires on the deadman's private queue; hop to main for AppKit.
                DispatchQueue.main.async {
                    guard let self, self.isEnabled else { return }
                    self.disable(
                        reason: NSLocalizedString("デッドマンスイッチ (自動停止)", comment: "Dead-man switch auto-stop reason"))
                }
            }
            dm.arm()
            deadman = dm
            NSLog("[ShakaPachi] Deadman switch armed (%.0fs)", DeadmanSwitch.configuredTimeout())
        #endif
    }

    private func disarmDeadman() {
        #if DEBUG
            deadman?.disarm()
            deadman = nil
        #endif
    }

    // MARK: - Event handling (called from the tap callback)

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // N1: record entry time before any other work.
        let t0 = CFAbsoluteTimeGetCurrent()

        let eventType: KeyEvent.EventType
        switch type {
        case .keyDown: eventType = .keyDown
        case .keyUp: eventType = .keyUp
        case .flagsChanged: eventType = .flagsChanged
        case .tapDisabledByTimeout: eventType = .tapDisabledByTimeout
        case .tapDisabledByUserInput: eventType = .tapDisabledByUserInput
        default: eventType = .other
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let abstract = KeyEvent(
            keyCode: keyCode,
            modifierFlags: event.flags.rawValue,
            eventType: eventType
        )

        switch SafetyGuard.evaluate(
            event: abstract,
            isSecureInputEnabled: IsSecureEventInputEnabled()
        ) {
        case .reenableTap:
            // Recovers from SYSTEM-initiated disables (timeout, input safety).
            // Intentional disables (deadman, menu) also surface here as
            // tapDisabledByUserInput — isEnabled is already false then, and
            // re-enabling would defeat the kill switches, so recover only
            // while we intend to be running.
            if isEnabled, let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                DispatchQueue.main.async {
                    NSLog(
                        "[ShakaPachi] Tap auto-recovered from tapDisabled event — frequent occurrences indicate a performance problem"
                    )
                }
            }
            return nil

        case .passthroughSecureInput:
            return Unmanaged.passUnretained(event)

        case .proceed:
            break
        }

        // Translate the abstract KeyEvent into a SwitcherInput and forward it
        // to the state machine via onSwitcherInput. The tap callback must return
        // quickly — all panel/UI work is deferred to the main queue inside
        // onSwitcherInput's implementation in AppDelegate.
        //
        // The trigger modifier and key are read from stored plain values
        // (triggerModifierMask, triggerKeyCode) which AppDelegate keeps in sync
        // with Settings. We never call into Settings/AppKit inside this callback.
        let configuredMask = triggerModifierMask
        let configuredKeyCode = triggerKeyCode
        let rawFlags = event.flags.rawValue
        let hasTriggerModifier = (rawFlags & configuredMask) != 0
        let hasShift = event.flags.contains(.maskShift)

        // Build the switcher-relevant input, if any.
        let switcherInput: SwitcherInput?
        switch eventType {
        case .keyDown:
            switch keyCode {
            case configuredKeyCode where hasTriggerModifier:
                switcherInput = .trigger(shift: hasShift)
            // Arrows are reported by direction, not by meaning: the tap has no
            // idea which display mode is active, and the two modes read the
            // vertical axis differently. The state machine decides.
            case KeyCode.rightArrow:
                switcherInput = .arrowRight
            case KeyCode.leftArrow:
                switcherInput = .arrowLeft
            case KeyCode.downArrow:
                switcherInput = .arrowDown
            case KeyCode.upArrow:
                switcherInput = .arrowUp
            case KeyCode.escape:
                switcherInput = .escape
            case KeyCode.grave:
                switcherInput = .sameAppJump
            default:
                // Digits only mean something while the switcher is up; the
                // machine returns them unconsumed otherwise, so the front app
                // still sees its own modifier+digit shortcuts.
                if let digit = KeyCode.digit(for: keyCode) {
                    switcherInput = .digit(digit)
                } else {
                    switcherInput = .otherKey
                }
            }
        case .keyUp:
            // Consume the trigger key's keyUp so an orphan keyUp doesn't reach
            // the front app. Use the CONFIGURED key code, not a hardcoded value.
            if keyCode == configuredKeyCode, hasTriggerModifier {
                return nil
            }
            switcherInput = nil
        case .flagsChanged:
            // Detect configured modifier transitions using the configured mask.
            if hasTriggerModifier {
                switcherInput = .modifierDown
            } else {
                switcherInput = .modifierUp
            }
        default:
            switcherInput = nil
        }

        guard let input = switcherInput else {
            return Unmanaged.passUnretained(event)
        }

        // The machine call itself is pure and cheap (no I/O).
        // Capture what we need before the async hop so we avoid races.
        let capturedT0 = t0
        let capturedInput = input

        // Use a semaphore-free synchronous dispatch: we can call the state
        // machine directly here because AppDelegate installs onSwitcherInput
        // on the main actor AND the tap callback runs on the main run loop
        // (CFRunLoopAddSource to .commonModes in enable()). This avoids an
        // async hop for the consume decision, which must be made before we
        // return from this callback.
        //
        // If onSwitcherInput is not set yet, fall back to legacy handlers
        // so no regression occurs before AppDelegate wires the machine.
        if let handler = onSwitcherInput {
            let consume = handler(capturedInput, capturedT0)
            return consume ? nil : Unmanaged.passUnretained(event)
        }

        // Legacy fallback (pre-Step-9 path): kept so the app doesn't break
        // if onSwitcherInput is not wired (e.g. during tests or early init).
        if case .trigger = capturedInput, case .keyDown = eventType {
            DispatchQueue.main.async { [weak self] in
                self?.onTrigger?(capturedT0)
            }
            return nil
        }
        if case .modifierUp = capturedInput {
            DispatchQueue.main.async { [weak self] in
                self?.onModifierReleased?()
            }
        }
        // Pass non-trigger events through when the handler isn't wired yet.
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - C callback trampoline

// (Skippable: C-callback ↔ Swift bridging via Unmanaged. Not needed to understand the switch flow.)
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handleEvent(type: type, event: event)
}
