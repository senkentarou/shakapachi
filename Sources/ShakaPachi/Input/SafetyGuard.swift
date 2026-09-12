// SafetyGuard.swift
// Pure safety-mechanism logic — no AppKit dependency, fully testable.

import Foundation

// MARK: - Abstract key event (AppKit-free representation)

/// Abstracted key event passed to SafetyGuard.evaluate().
/// This mirrors CGEventType / CGKeyCode but carries no AppKit/CoreGraphics types
/// so unit tests can construct instances without a display connection.
struct KeyEvent: Sendable {
    enum EventType: Sendable {
        case keyDown
        case keyUp
        case flagsChanged
        case tapDisabledByTimeout
        case tapDisabledByUserInput
        case other
    }

    /// CGKeyCode value (e.g. 53 = Escape).
    let keyCode: UInt16
    /// Modifier flags as a raw bitmask matching CGEventFlags.
    /// Use the SafetyGuard.Modifiers constants below.
    let modifierFlags: UInt64
    let eventType: EventType

    init(keyCode: UInt16, modifierFlags: UInt64, eventType: EventType) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.eventType = eventType
    }
}

// MARK: - CGKeyCode constants (no CoreGraphics import needed)

enum KeyCode {
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    // Arrow keys (US ANSI layout, same across all keyboard types).
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    // Grave accent / backtick (`~) — used for same-app jump.
    static let grave: UInt16 = 50

    /// Number-row keycodes for 1...9, in printed order.
    /// Keycodes address a physical key rather than the character it produces,
    /// so this holds on non-US layouts where the digits are unshifted anyway.
    private static let digitRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// The digit 1...9 printed on `keyCode`, or nil when it is not a number-row key.
    static func digit(for keyCode: UInt16) -> Int? {
        digitRow.firstIndex(of: keyCode).map { $0 + 1 }
    }
}

// MARK: - Tap event types (for auto-recovery mapping)

enum TapEvent: Sendable {
    case tapDisabledByTimeout
    case tapDisabledByUserInput
    case other
}

// MARK: - SafetyGuard evaluation result

/// The result returned by SafetyGuard.evaluate().
/// Order of precedence: reenableTap > passthroughSecureInput > proceed.
enum SafetyGuardResult: Equatable, Sendable {
    /// Secure Input is active; pass the event through untouched.
    case passthroughSecureInput
    /// Tap was disabled by timeout or user input; caller must re-enable it.
    case reenableTap
    /// Normal event; proceed with further processing.
    case proceed
}

// MARK: - SafetyGuard

/// Stateless safety evaluator for CGEventTap callbacks.
///
/// Usage in the tap callback:
/// ```swift
/// let result = SafetyGuard.evaluate(event: abstractEvent, isSecureInputEnabled: ...)
/// switch result {
/// case .reenableTap:          CGEvent.tapEnable(tap: tap, enable: true); return nil
/// case .passthroughSecureInput: return Unmanaged.passRetained(event) // pass through
/// case .proceed:              // continue normal processing
/// }
/// ```
enum SafetyGuard {

    // MARK: - Tap auto-recovery

    /// Maps a tap-disabled event type to a .reenableTap result.
    static func tapRecoveryResult(for tapEvent: TapEvent) -> SafetyGuardResult {
        switch tapEvent {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .reenableTap
        case .other:
            return .proceed
        }
    }

    // MARK: - Secure Input passthrough

    /// Returns true when Secure Input is active and events should not be consumed.
    static func isSecureInputPassthrough(isSecureInputEnabled: Bool) -> Bool {
        return isSecureInputEnabled
    }

    // MARK: - Primary evaluation

    /// Evaluate a key event and return the action the caller must take.
    /// Precedence: reenableTap > passthroughSecureInput > proceed.
    static func evaluate(
        event: KeyEvent,
        isSecureInputEnabled: Bool
    ) -> SafetyGuardResult {
        // 1. Tap-disabled events map to reenableTap before the secure-input check.
        switch event.eventType {
        case .tapDisabledByTimeout:
            return tapRecoveryResult(for: .tapDisabledByTimeout)
        case .tapDisabledByUserInput:
            return tapRecoveryResult(for: .tapDisabledByUserInput)
        default:
            break
        }

        // 2. Secure Input: pass everything through untouched.
        if isSecureInputPassthrough(isSecureInputEnabled: isSecureInputEnabled) {
            return .passthroughSecureInput
        }

        return .proceed
    }
}

// MARK: - Deadman switch (DEBUG only)

#if DEBUG

    /// Injectable clock protocol so tests can control time without sleeping.
    protocol Clock: Sendable {
        /// Returns the current time as seconds since some epoch (monotonic).
        func now() -> TimeInterval
    }

    /// Production clock: uses CFAbsoluteTimeGetCurrent for a monotonic wall-clock.
    struct SystemClock: Clock {
        init() {}
        func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }
    }

    /// Deadman switch that fires a handler after N seconds of inactivity.
    ///
    /// The switch is configured via the `SHAKAPACHI_DEADMAN_SEC` environment variable
    /// (default 60 seconds; set to "0" to disable).
    ///
    /// The handler is a closure; the actual tap-disable call is injected at
    /// the call site so this type remains AppKit-free and unit-testable.
    // @unchecked Sendable: all mutable state (timer) is accessed exclusively on `queue`.
    final class DeadmanSwitch: @unchecked Sendable {

        /// Seconds until the deadman fires. Reads SHAKAPACHI_DEADMAN_SEC; defaults to 60.
        static func configuredTimeout() -> TimeInterval {
            if let raw = ProcessInfo.processInfo.environment["SHAKAPACHI_DEADMAN_SEC"],
                let secs = TimeInterval(raw)
            {
                return secs
            }
            return 60
        }

        private let timeoutSeconds: TimeInterval
        private let clock: any Clock
        private let handler: @Sendable () -> Void
        private var timer: DispatchSourceTimer?
        private let queue = DispatchQueue(label: "com.senkentarou.shakapachi.deadman")

        /// - Parameters:
        ///   - timeout: Seconds until the handler fires. Pass 0 to disable.
        ///   - clock: Injectable clock for testing.
        ///   - handler: Called when the deadman fires. Must be fast (no blocking).
        init(
            timeout: TimeInterval = DeadmanSwitch.configuredTimeout(),
            clock: any Clock = SystemClock(),
            handler: @escaping @Sendable () -> Void
        ) {
            self.timeoutSeconds = timeout
            self.clock = clock
            self.handler = handler
        }

        /// Arm the deadman switch. No-op if timeout is 0.
        func arm() {
            guard timeoutSeconds > 0 else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + timeoutSeconds)
            t.setEventHandler { [weak self] in
                self?.handler()
                self?.timer?.cancel()
                self?.timer = nil
            }
            t.resume()
            timer = t
        }

        /// Cancel the deadman switch (e.g. on clean shutdown).
        func disarm() {
            timer?.cancel()
            timer = nil
        }

        deinit { disarm() }
    }

#endif  // DEBUG
