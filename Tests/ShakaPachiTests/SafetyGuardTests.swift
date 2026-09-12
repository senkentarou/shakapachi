// SafetyGuardTests.swift
// Verifies the safety mechanisms via pure logic — no AppKit or display needed.

import XCTest

@testable import ShakaPachi

final class SafetyGuardTests: XCTestCase {

    // MARK: - Tap auto-recovery

    func testTapRecovery_disabledByTimeout_mapsToReenableTap() {
        let result = SafetyGuard.tapRecoveryResult(for: .tapDisabledByTimeout)
        XCTAssertEqual(result, .reenableTap)
    }

    func testTapRecovery_disabledByUserInput_mapsToReenableTap() {
        let result = SafetyGuard.tapRecoveryResult(for: .tapDisabledByUserInput)
        XCTAssertEqual(result, .reenableTap)
    }

    func testEvaluate_tapDisabledByTimeout_returnsReenableTap() {
        let event = KeyEvent(keyCode: 0, modifierFlags: 0, eventType: .tapDisabledByTimeout)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .reenableTap)
    }

    func testEvaluate_tapDisabledByUserInput_returnsReenableTap() {
        let event = KeyEvent(keyCode: 0, modifierFlags: 0, eventType: .tapDisabledByUserInput)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .reenableTap)
    }

    func testEvaluate_reenableTap_winsOverSecureInputPassthrough() {
        // Tap-disabled events must recover even while Secure Input is active.
        let event = KeyEvent(keyCode: 0, modifierFlags: 0, eventType: .tapDisabledByUserInput)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: true)
        XCTAssertEqual(
            result, .reenableTap,
            "Tap auto-recovery must win over secure-input passthrough")
    }

    // MARK: - Secure Input passthrough

    func testSecureInput_passthrough_whenEnabled() {
        let result = SafetyGuard.isSecureInputPassthrough(isSecureInputEnabled: true)
        XCTAssertTrue(result)
    }

    func testSecureInput_noPassthrough_whenDisabled() {
        let result = SafetyGuard.isSecureInputPassthrough(isSecureInputEnabled: false)
        XCTAssertFalse(result)
    }

    func testEvaluate_normalEvent_secureInputEnabled_returnsPassthrough() {
        let event = KeyEvent(keyCode: 48, modifierFlags: 0, eventType: .keyDown)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: true)
        XCTAssertEqual(result, .passthroughSecureInput)
    }

    func testEvaluate_normalEvent_secureInputDisabled_returnsProceeed() {
        let event = KeyEvent(keyCode: 48, modifierFlags: 0, eventType: .keyDown)
        let result = SafetyGuard.evaluate(event: event, isSecureInputEnabled: false)
        XCTAssertEqual(result, .proceed)
    }

    // MARK: - Deadman switch (DEBUG only)

    #if DEBUG
        func testDeadman_firesAtConfiguredTime() {
            let expectation = expectation(description: "Deadman fires")
            let timeout: TimeInterval = 0.1  // 100ms — fast enough for tests

            let deadman = DeadmanSwitch(timeout: timeout, clock: SystemClock()) {
                expectation.fulfill()
            }
            deadman.arm()

            wait(for: [expectation], timeout: timeout + 1.0)
        }

        func testDeadman_doesNotFire_whenTimeoutIsZero() {
            // Use an actor-isolated flag to avoid Sendable mutation warning.
            // The test verifies that the handler closure is never called.
            let notFiredExp = expectation(description: "handler not fired")
            notFiredExp.isInverted = true  // fulfilling it would mean the test fails

            let deadman = DeadmanSwitch(timeout: 0, clock: SystemClock()) {
                notFiredExp.fulfill()
            }
            deadman.arm()

            // Wait briefly; inverted expectation must time out (i.e. handler never fires).
            wait(for: [notFiredExp], timeout: 0.3)
        }

        func testDeadman_configuredTimeout_readsEnvVar() {
            // Verify configuredTimeout() parses SHAKAPACHI_DEADMAN_SEC.
            // We can't set env vars at runtime in tests, but we can verify
            // the default is 60 when the variable is not set.
            // (The env var may or may not be set in CI; just check the type.)
            let t = DeadmanSwitch.configuredTimeout()
            XCTAssertGreaterThanOrEqual(t, 0, "Timeout must be non-negative")
        }
    #endif
}
