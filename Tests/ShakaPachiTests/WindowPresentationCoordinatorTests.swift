// WindowPresentationCoordinatorTests.swift
// Verifies that the open-window counter revert logic is symmetric and correct.
// Each test drives a real WindowPresentationCoordinator instance via injected
// recording closures so that production logic is exercised, not a local shim.

import XCTest

@testable import ShakaPachi

// Recorded side-effect events emitted by WindowPresentationCoordinator.
private enum PolicyEvent: Equatable {
    case setRegular
    case setAccessory
    case activate
}

/// Simple reference wrapper so injected closures and the test body share one array.
private final class EventBox {
    var events: [PolicyEvent] = []
}

/// Build a coordinator backed by recording stubs and drive it with the given
/// open/close sequence (true = open, false = close). Returns the recorded events.
@MainActor
private func driveCoordinator(events: [Bool]) -> [PolicyEvent] {
    let box = EventBox()
    let coordinator = WindowPresentationCoordinator(
        setPolicy: { policy in
            switch policy {
            case .regular: box.events.append(.setRegular)
            case .accessory: box.events.append(.setAccessory)
            default: break
            }
        },
        activate: { box.events.append(.activate) }
    )
    for opened in events {
        if opened {
            coordinator.windowDidOpen()
        } else {
            coordinator.windowDidClose()
        }
    }
    return box.events
}

@MainActor
final class WindowPresentationCoordinatorTests: XCTestCase {

    // MARK: - Single window open/close

    func testSingleWindowOpenReversesToAccessory() {
        let events = driveCoordinator(events: [true, false])
        XCTAssertEqual(
            events,
            [
                .setRegular,
                .activate,
                .setAccessory,
            ])
    }

    // MARK: - Two windows: closing one must NOT revert policy

    func testSecondWindowClose_doesNotRevertPolicy() {
        // Open two windows, close the first — .accessory must NOT be set yet.
        let events = driveCoordinator(events: [true, true, false])
        // Only one setRegular (on first open), no setAccessory yet.
        XCTAssertFalse(
            events.contains(.setAccessory),
            "closing one window while another is open must not revert policy")
    }

    func testBothWindowsClose_revertsPolicy() {
        // Open two, close both — .accessory is set after the last close.
        let events = driveCoordinator(events: [true, true, false, false])
        let setAccessoryCount = events.filter { $0 == .setAccessory }.count
        XCTAssertEqual(
            setAccessoryCount, 1,
            "policy must revert exactly once after all windows close")
    }

    // MARK: - Asymmetric close order (the bug being fixed)

    func testOnboardingClosedFirst_thenSettings_revertsOnce() {
        // Simulates: both open, onboarding closes first (was the buggy path),
        // then settings closes. Total: 2 opens, 2 closes.
        let events = driveCoordinator(events: [true, true, false, false])
        let setRegularCount = events.filter { $0 == .setRegular }.count
        let setAccessoryCount = events.filter { $0 == .setAccessory }.count
        XCTAssertEqual(setRegularCount, 1, "setRegular fires on first open only")
        XCTAssertEqual(setAccessoryCount, 1, "setAccessory fires only after both windows close")
    }

    // MARK: - Defensive: close without prior open does not trigger setRegular/activate

    func testSpuriousClose_doesNotSetRegularOrActivate() {
        let events = driveCoordinator(events: [false])
        XCTAssertFalse(
            events.contains(.setRegular),
            "spurious close must not trigger setRegular")
        XCTAssertFalse(
            events.contains(.activate),
            "spurious close must not trigger activate")
    }
}
